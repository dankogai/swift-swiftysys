//
//  FS+IO.swift
//  SwiftySys
//
//  Reading, writing, creating and removing nodes.
//
//  Terminal accessors come in pairs, SwiftyJSON style:
//  `data` / `string` return Optionals (nil on error),
//  `dataValue` / `stringValue` return empty values on error,
//  and `read()` / `readString()` throw the underlying Errno.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension FS {
    // MARK: - Reading

    /// The whole contents. Throws the carried errno on `.error` nodes.
    /// Opens with `open(2)`, so reading a `.symlink` follows the link.
    public func read() throws -> Data {
        if case .error(let e, _) = self { throw e }
        let fd = try FileDescriptor.open(path, .readOnly)
        defer { try? fd.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = try buf.withUnsafeMutableBytes { try fd.read(into: $0) }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    /// The whole contents decoded as UTF-8.
    public func readString() throws -> String {
        let data = try read()
        guard let s = String(data: data, encoding: .utf8) else {
            throw Errno.invalidArgument
        }
        return s
    }

    /// The whole contents, or `nil` on failure.
    public var data: Data? { try? read() }

    /// The whole contents, or empty `Data` on failure.
    public var dataValue: Data { data ?? Data() }

    /// The whole contents as UTF-8, or `nil` on failure.
    public var string: String? { try? readString() }

    /// The whole contents as UTF-8, or `""` on failure.
    public var stringValue: String { string ?? "" }

    // MARK: - Writing

    /// Writes (creates or truncates) the file and returns the fresh node.
    ///
    /// Works on `.file` and on `.error(.noSuchFileOrDirectory, _)` —
    /// the latter is what a subscript chain into an existing directory
    /// yields for a not-yet-existing file, so this just works:
    ///
    /// ```swift
    /// try FS("/tmp")["hello.txt"].write("hello, world\n")
    /// ```
    @discardableResult
    public func write(_ data: Data) throws -> FS {
        if case .error(let e, _) = self, e != .noSuchFileOrDirectory { throw e }
        let fd = try FileDescriptor.open(
            path, .writeOnly,
            options: [.create, .truncate],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? fd.close() }
        try fd.writeAll(data)
        return refreshed()
    }

    @discardableResult
    public func write(_ string: String) throws -> FS {
        try write(Data(string.utf8))
    }

    /// Appends to the file (creating it if absent) and returns the fresh node.
    @discardableResult
    public func append(_ data: Data) throws -> FS {
        if case .error(let e, _) = self, e != .noSuchFileOrDirectory { throw e }
        let fd = try FileDescriptor.open(
            path, .writeOnly,
            options: [.create, .append],
            permissions: [.ownerReadWrite, .groupRead, .otherRead]
        )
        defer { try? fd.close() }
        try fd.writeAll(data)
        return refreshed()
    }

    @discardableResult
    public func append(_ string: String) throws -> FS {
        try append(Data(string.utf8))
    }

    // MARK: - Directories

    /// Creates a directory at this node's path and returns the fresh node.
    /// A no-op if the node already is a directory.
    @discardableResult
    public func mkdir(withIntermediates: Bool = false) throws -> FS {
        switch self {
        case .directory:
            return self
        case .error(.noSuchFileOrDirectory, let p):
            if withIntermediates {
                var prefix = FilePath("")
                prefix.root = p.root
                for component in p.components {
                    prefix.append(component)
                    try FS.mkdirOne(prefix, allowExisting: true)
                }
            } else {
                try FS.mkdirOne(p, allowExisting: false)
            }
            return refreshed()
        case .error(let e, _):
            throw e
        default:
            throw Errno.fileExists
        }
    }

    private static func mkdirOne(_ p: FilePath, allowExisting: Bool) throws {
        let rc = p.withPlatformString {
            #if canImport(Darwin)
            Darwin.mkdir($0, 0o755)
            #else
            Glibc.mkdir($0, 0o755)
            #endif
        }
        guard rc != 0 else { return }
        let e = Errno(rawValue: errno)
        // resolved() so a symlink to a directory (e.g. /var -> /private/var)
        // counts as an existing directory
        if allowExisting, e == .fileExists, FS(p).resolved().isDirectory { return }
        throw e
    }

    // MARK: - Removal

    /// Removes this node and returns the fresh (now nonexistent) node.
    /// Directories must be empty unless `recursively` is `true`.
    @discardableResult
    public func remove(recursively: Bool = false) throws -> FS {
        switch self {
        case .error(let e, _):
            throw e
        case .directory(let p):
            if recursively {
                for (_, child) in self {
                    try child.remove(recursively: true)
                }
            }
            let rc = p.withPlatformString { rmdir($0) }
            guard rc == 0 else { throw Errno(rawValue: errno) }
        default:
            let rc = path.withPlatformString { unlink($0) }
            guard rc == 0 else { throw Errno(rawValue: errno) }
        }
        return refreshed()
    }

    // MARK: - Symlinks

    /// What a `.symlink` points to (the raw link text), `nil` otherwise.
    public var linkTarget: FilePath? {
        guard case .symlink(let p) = self else { return nil }
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = p.withPlatformString { readlink($0, &buf, buf.count - 1) }
        guard n >= 0 else { return nil }
        let bytes = buf[0..<n].map { UInt8(bitPattern: $0) }
        return FilePath(String(decoding: bytes, as: UTF8.self))
    }

    /// Creates a symlink at this node's path pointing to `target`,
    /// and returns the fresh node.
    @discardableResult
    public func symlink(to target: FilePath) throws -> FS {
        if case .error(let e, _) = self, e != .noSuchFileOrDirectory { throw e }
        if exists { throw Errno.fileExists }
        let rc = target.withPlatformString { t in
            path.withPlatformString { p in
                #if canImport(Darwin)
                Darwin.symlink(t, p)
                #else
                Glibc.symlink(t, p)
                #endif
            }
        }
        guard rc == 0 else { throw Errno(rawValue: errno) }
        return refreshed()
    }

    /// Resolves symlinks (and `.`/`..`) via `realpath(3)` and returns
    /// the node for the canonical path.
    public func resolved() -> FS {
        if case .error = self { return self }
        guard let rp = path.withPlatformString({ realpath($0, nil) }) else {
            return .error(Errno(rawValue: errno), path)
        }
        defer { free(rp) }
        return FS(String(cString: rp))
    }
}
