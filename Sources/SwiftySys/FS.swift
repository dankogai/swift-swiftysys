//
//  FS.swift
//  SwiftySys
//
//  File System Operation made Swifty.
//
//  `FS` is to the filesystem what SwiftyJSON's `JSON` is to JSON:
//  a single enum whose case is decided by one lstat(2) at construction,
//  with an `.error` case that absorbs and propagates failures so that
//  subscript chains never need force-unwrapping.
//
@_exported import SystemPackage

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A filesystem node: file, directory, symlink, … or an error.
///
/// The case is decided by a single `lstat(2)` when the value is created.
/// If the node changes on disk afterward, the value is stale; use
/// ``refreshed()`` to re-examine the disk.
public enum FS: Sendable, Equatable, Hashable {
    case file(FilePath)
    case directory(FilePath)
    case symlink(FilePath)
    case fifo(FilePath)
    case socket(FilePath)
    case blockDevice(FilePath)
    case characterDevice(FilePath)
    /// A failure, carrying the errno and the path where it occurred.
    case error(Errno, FilePath)

    /// Examines `path` with `lstat(2)` and picks the matching case.
    /// Does not follow symlinks: a symlink reports as `.symlink`.
    public init(_ path: FilePath) {
        switch FS.lstat(path) {
        case .success(let st):
            self = FS(mode: st.st_mode, path: path)
        case .failure(let errno):
            self = .error(errno, path)
        }
    }

    public init(_ path: String) {
        self.init(FilePath(path))
    }

    private init(mode: CInterop.Mode, path: FilePath) {
        switch mode & S_IFMT {
        case S_IFREG:  self = .file(path)
        case S_IFDIR:  self = .directory(path)
        case S_IFLNK:  self = .symlink(path)
        case S_IFIFO:  self = .fifo(path)
        case S_IFSOCK: self = .socket(path)
        case S_IFBLK:  self = .blockDevice(path)
        case S_IFCHR:  self = .characterDevice(path)
        default:       self = .error(Errno(rawValue: EFTYPE_COMPAT), path)
        }
    }

    /// The path this node refers to. Every case carries one,
    /// including `.error` (the path where the failure occurred).
    public var path: FilePath {
        switch self {
        case .file(let p), .directory(let p), .symlink(let p),
             .fifo(let p), .socket(let p),
             .blockDevice(let p), .characterDevice(let p),
             .error(_, let p):
            return p
        }
    }

    /// The path as a `String`.
    public var pathString: String { path.string }

    /// The last path component ("basename").
    public var name: String { path.lastComponent?.string ?? path.string }

    /// The parent node.
    public var parent: FS { FS(path.removingLastComponent()) }

    /// The errno if this node is `.error`; `nil` otherwise.
    public var error: Errno? {
        if case .error(let e, _) = self { return e }
        return nil
    }

    /// `true` unless this node is `.error`.
    public var exists: Bool { error == nil }

    public var isFile: Bool { if case .file = self { return true }; return false }
    public var isDirectory: Bool { if case .directory = self { return true }; return false }
    public var isSymlink: Bool { if case .symlink = self { return true }; return false }
    public var isFifo: Bool { if case .fifo = self { return true }; return false }

    /// Descends into a directory. Chainable without unwrapping:
    ///
    /// ```swift
    /// FS("/tmp")["a"]["b.txt"]
    /// ```
    ///
    /// - On a `.directory`, returns the child node (which may itself
    ///   be `.error(.noSuchFileOrDirectory, _)` if absent).
    /// - On `.error(.noSuchFileOrDirectory, _)`, extends the path and
    ///   re-examines it, so the error carries the full intended path
    ///   and `write(_:)`/`mkdir()` at the end of a chain know where
    ///   to create.
    /// - On any other `.error`, propagates unchanged, so the error
    ///   still reports the path where the failure originated.
    /// - On a non-directory node, returns `.error(.notDirectory, path)`.
    ///
    /// The *setter* copies: `dir["copy.txt"] = FS("/etc/hosts")` writes
    /// the source node's contents into the child. (For literal content,
    /// see the `FSContent` subscript: `dir["f.txt"] = "hello"`.)
    /// Like all assignment sugar it is best-effort — failures are
    /// silent; inspect the node's `error` afterward, or use the
    /// throwing `write(_:)` instead.
    public subscript(_ name: String) -> FS {
        get {
            switch self {
            case .directory(let p):
                return FS(p.appending(name))
            case .error(.noSuchFileOrDirectory, let p):
                return FS(p.appending(name))
            case .error:
                return self
            case .file(let p), .symlink(let p), .fifo(let p), .socket(let p),
                 .blockDevice(let p), .characterDevice(let p):
                return .error(.notDirectory, p)
            }
        }
        nonmutating set {
            let target: FS = self[name]
            // writeback from `dir["log"] += ...` arrives here as a
            // self-assignment; the append already happened
            guard target.path != newValue.path else { return }
            guard let data = newValue.data else { return }
            try? target.write(data)
        }
    }

    /// Same as the subscript: `FS("/tmp") / "a" / "b.txt"`.
    public static func / (lhs: FS, rhs: String) -> FS {
        lhs[rhs]
    }

    /// Re-examines the disk and returns a fresh node for the same path.
    public func refreshed() -> FS { FS(path) }

    // MARK: - Well-known locations

    /// The current working directory.
    public static var cwd: FS {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard getcwd(&buf, buf.count) != nil else {
            return .error(Errno(rawValue: errno), ".")
        }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return FS(String(decoding: bytes, as: UTF8.self))
    }

    /// The current user's home directory.
    public static var home: FS {
        if let home = getenv("HOME") { return FS(String(cString: home)) }
        return .error(.noSuchFileOrDirectory, "~")
    }

    /// A directory for temporary files.
    public static var temp: FS {
        if let tmp = getenv("TMPDIR") { return FS(String(cString: tmp)) }
        return FS("/tmp")
    }

    // MARK: - lstat plumbing

    #if canImport(Darwin)
    internal typealias CStat = Darwin.stat
    #else
    internal typealias CStat = Glibc.stat
    #endif

    internal static func lstat(_ path: FilePath) -> Result<CStat, Errno> {
        var st = CStat()
        let rc = path.withPlatformString {
            #if canImport(Darwin)
            Darwin.lstat($0, &st)
            #else
            Glibc.lstat($0, &st)
            #endif
        }
        return rc == 0 ? .success(st) : .failure(Errno(rawValue: errno))
    }

    /// Fresh lstat of this node's path; `nil` for `.error` nodes
    /// or if the node has vanished.
    internal var stat: CStat? {
        if case .error = self { return nil }
        return try? FS.lstat(path).get()
    }
}

// EFTYPE does not exist on Linux; fall back to EINVAL there.
#if canImport(Darwin)
private let EFTYPE_COMPAT = EFTYPE
#else
private let EFTYPE_COMPAT = EINVAL
#endif

extension FS: CustomStringConvertible {
    public var description: String {
        switch self {
        case .file(let p):            return "FS.file(\(p))"
        case .directory(let p):       return "FS.directory(\(p))"
        case .symlink(let p):         return "FS.symlink(\(p))"
        case .fifo(let p):            return "FS.fifo(\(p))"
        case .socket(let p):          return "FS.socket(\(p))"
        case .blockDevice(let p):     return "FS.blockDevice(\(p))"
        case .characterDevice(let p): return "FS.characterDevice(\(p))"
        case .error(let e, let p):    return "FS.error(\(e), \(p))"
        }
    }
}
