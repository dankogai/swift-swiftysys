//
//  FS+Posix.swift
//  SwiftySys
//
//  The classic manipulation calls — chmod, chown, rename, link,
//  utime, truncate, mkfifo — in the house style: throwing Errno,
//  @discardableResult, returning the fresh node. The process-global
//  pair (chdir, umask) lives on Sys, where process state belongs.
//
//      try FS("script.sh").chmod(0o755)
//      try FS("data.log").chown(user: "dankogai")
//      try FS("draft.txt").rename(to: "final.txt")
//      try FS.temp["stamp"].touch()
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The methods shadow the C names, so the syscalls get a namespace.
private enum C {
    static func chmod(_ p: UnsafePointer<CChar>, _ m: CInterop.Mode) -> Int32 {
        #if canImport(Darwin)
        Darwin.chmod(p, m)
        #else
        Glibc.chmod(p, m)
        #endif
    }
    static func chown(_ p: UnsafePointer<CChar>, _ u: uid_t, _ g: gid_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.chown(p, u, g)
        #else
        Glibc.chown(p, u, g)
        #endif
    }
    static func rename(_ old: UnsafePointer<CChar>, _ new: UnsafePointer<CChar>) -> Int32 {
        #if canImport(Darwin)
        Darwin.rename(old, new)
        #else
        Glibc.rename(old, new)
        #endif
    }
    static func link(_ old: UnsafePointer<CChar>, _ new: UnsafePointer<CChar>) -> Int32 {
        #if canImport(Darwin)
        Darwin.link(old, new)
        #else
        Glibc.link(old, new)
        #endif
    }
    static func truncate(_ p: UnsafePointer<CChar>, _ size: off_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.truncate(p, size)
        #else
        Glibc.truncate(p, size)
        #endif
    }
    static func mkfifo(_ p: UnsafePointer<CChar>, _ m: CInterop.Mode) -> Int32 {
        #if canImport(Darwin)
        Darwin.mkfifo(p, m)
        #else
        Glibc.mkfifo(p, m)
        #endif
    }
    static func utimes(_ p: UnsafePointer<CChar>, _ t: UnsafePointer<timeval>?) -> Int32 {
        #if canImport(Darwin)
        Darwin.utimes(p, t)
        #else
        Glibc.utimes(p, t)
        #endif
    }
    static func chdir(_ p: UnsafePointer<CChar>) -> Int32 {
        #if canImport(Darwin)
        Darwin.chdir(p)
        #else
        Glibc.chdir(p)
        #endif
    }
    static func umask(_ m: CInterop.Mode) -> CInterop.Mode {
        #if canImport(Darwin)
        Darwin.umask(m)
        #else
        Glibc.umask(m)
        #endif
    }
}

extension FS {
    private func withExistingPath<T>(_ body: (FilePath) throws -> T) throws -> T {
        if case .error(let e, _) = self { throw e }
        return try body(path)
    }

    private func syscall(_ body: (FilePath) -> Int32) throws -> FS {
        try withExistingPath { p in
            guard body(p) == 0 else { throw Errno(rawValue: errno) }
            return FS(p)
        }
    }

    // MARK: - chmod

    /// Changes the permission bits — `chmod(2)` (follows symlinks).
    /// `FS.Permissions` speaks ugo and takes integer literals, so the
    /// typed and octal spellings are one overload:
    ///
    /// ```swift
    /// try FS("script.sh").chmod(0o755)
    /// try FS("f").chmod([.userAll, .groupRead, .otherRead])
    /// ```
    @discardableResult
    public func chmod(_ permissions: Permissions) throws -> FS {
        try syscall { p in p.withPlatformString { C.chmod($0, permissions.rawValue) } }
    }

    /// chmod(1)'s symbolic modes, BSD-style:
    ///
    /// ```swift
    /// try FS("script.sh").chmod("u+x")
    /// try FS("shared").chmod("a=rwX")       // X: only dirs & already-x
    /// try FS("f").chmod("u=rwx,go=rx")      // clauses compose
    /// try FS("f").chmod("g=u")              // copy u's bits to g
    /// ```
    ///
    /// The full grammar: who `u`/`g`/`o`/`a` (omitted = `a`, honoring
    /// the umask), ops `+`/`-`/`=`, perms `r`/`w`/`x`/`X`/`s`/`t` or a
    /// single `u`/`g`/`o` to copy. Malformed specs throw `EINVAL`.
    @discardableResult
    public func chmod(_ symbolic: String) throws -> FS {
        // followed mode: chmod(1) is about the target, symlinks and all
        guard let current = followedMode else {
            if case .error(let e, _) = self { throw e }
            throw Errno.noSuchFileOrDirectory
        }
        // read the umask without changing it (set-and-restore)
        let mask = C.umask(0)
        _ = C.umask(mask)
        let newMode = try FS.symbolicMode(
            symbolic,
            applyingTo: current,
            isDirectory: resolved().isDirectory,
            umask: mask
        )
        return try chmod(Permissions(rawValue: newMode))
    }

    /// The pure heart of symbolic chmod — split out so it is testable
    /// with an explicit umask and directory-ness.
    internal static func symbolicMode(
        _ spec: String,
        applyingTo current: CInterop.Mode,
        isDirectory: Bool,
        umask: CInterop.Mode
    ) throws -> CInterop.Mode {
        func position(_ who: Character) -> CInterop.Mode {
            switch who {
            case "u": 6
            case "g": 3
            default: 0
            }
        }
        var mode = current & 0o7777
        for clause in spec.split(separator: ",", omittingEmptySubsequences: false) {
            let chars = Array(clause)
            var i = 0
            var whos: Set<Character> = []
            while i < chars.count, "ugoa".contains(chars[i]) {
                if chars[i] == "a" { whos.formUnion("ugo") } else { whos.insert(chars[i]) }
                i += 1
            }
            let whoOmitted = whos.isEmpty
            if whoOmitted { whos = ["u", "g", "o"] }
            guard i < chars.count else { throw Errno.invalidArgument }
            while i < chars.count {
                let op = chars[i]
                guard "+-=".contains(op) else { throw Errno.invalidArgument }
                i += 1
                var perms: [Character] = []
                while i < chars.count, !"+-=".contains(chars[i]) {
                    perms.append(chars[i])
                    i += 1
                }
                var bits: CInterop.Mode = 0
                if perms.count == 1, "ugo".contains(perms[0]) {
                    // permcopy: replicate the source's rwx to the whos
                    let source = (mode >> position(perms[0])) & 0o7
                    for who in whos { bits |= source << position(who) }
                } else {
                    for perm in perms {
                        switch perm {
                        case "r": for who in whos { bits |= 0o4 << position(who) }
                        case "w": for who in whos { bits |= 0o2 << position(who) }
                        case "x": for who in whos { bits |= 0o1 << position(who) }
                        case "X":
                            if isDirectory || (mode & 0o111) != 0 {
                                for who in whos { bits |= 0o1 << position(who) }
                            }
                        case "s":
                            if whos.contains("u") { bits |= 0o4000 }
                            if whos.contains("g") { bits |= 0o2000 }
                        case "t":
                            bits |= 0o1000
                        default:
                            throw Errno.invalidArgument
                        }
                    }
                }
                if whoOmitted { bits &= ~umask }
                switch op {
                case "+":
                    mode |= bits
                case "-":
                    mode &= ~bits
                default:  // "="
                    var cleared: CInterop.Mode = 0
                    for who in whos {
                        switch who {
                        case "u": cleared |= 0o4700
                        case "g": cleared |= 0o2070
                        default:  cleared |= 0o1007
                        }
                    }
                    mode = (mode & ~cleared) | bits
                }
            }
        }
        return mode
    }

    // MARK: - Permission bits as properties

    /// The mode with symlinks followed — these properties are about
    /// what the node *is*, so a link reports (and chmods) its target.
    /// (realpath + lstat ≡ stat, without fighting Darwin's stat
    /// struct/function name collision.)
    private var followedMode: CInterop.Mode? {
        let target = resolved()
        if case .error = target { return nil }
        return (try? FS.lstat(target.path).get()).map { $0.st_mode & 0o7777 }
    }

    private func hasBit(_ bit: CInterop.Mode) -> Bool {
        followedMode.map { $0 & bit != 0 } ?? false
    }

    private func setBit(_ bit: CInterop.Mode, to on: Bool) {
        guard let mode = followedMode else { return }
        let target = on ? mode | bit : mode & ~bit
        if target != mode { try? chmod(Permissions(rawValue: target)) }
    }

    /// The permission bits, one Bool at a time — readable and settable:
    ///
    /// ```swift
    /// FS("script.sh").executable = true     // chmod u+x
    /// FS("secret").otherReadable = false    // chmod o-r
    /// if FS("f").groupWritable { ... }
    /// ```
    ///
    /// The bare `readable`/`writable`/`executable` mean the *user*
    /// (owner) bit; `user`/`group`/`other`-prefixed forms disambiguate.
    /// Getters are `false` on error nodes; setters are best-effort
    /// sugar (silent on failure) — use `chmod` when you want errors.
    public var userReadable: Bool {
        get { hasBit(0o400) }
        nonmutating set { setBit(0o400, to: newValue) }
    }
    public var userWritable: Bool {
        get { hasBit(0o200) }
        nonmutating set { setBit(0o200, to: newValue) }
    }
    public var userExecutable: Bool {
        get { hasBit(0o100) }
        nonmutating set { setBit(0o100, to: newValue) }
    }
    public var groupReadable: Bool {
        get { hasBit(0o040) }
        nonmutating set { setBit(0o040, to: newValue) }
    }
    public var groupWritable: Bool {
        get { hasBit(0o020) }
        nonmutating set { setBit(0o020, to: newValue) }
    }
    public var groupExecutable: Bool {
        get { hasBit(0o010) }
        nonmutating set { setBit(0o010, to: newValue) }
    }
    public var otherReadable: Bool {
        get { hasBit(0o004) }
        nonmutating set { setBit(0o004, to: newValue) }
    }
    public var otherWritable: Bool {
        get { hasBit(0o002) }
        nonmutating set { setBit(0o002, to: newValue) }
    }
    public var otherExecutable: Bool {
        get { hasBit(0o001) }
        nonmutating set { setBit(0o001, to: newValue) }
    }

    /// The bare forms are asymmetric on purpose, both halves matching
    /// habit: *reading* asks about the user (owner) bit — Perl's `-x`;
    /// *setting* is the shell's `chmod +x` / `-x` — all classes,
    /// honoring the umask. Use the `user`/`group`/`other`-prefixed
    /// properties for exact single-bit control.
    public var readable: Bool {
        get { userReadable }
        nonmutating set { try? chmod(newValue ? "+r" : "-r") }
    }
    /// Getter: the user bit. Setter: `chmod +w` / `-w` (umasked all).
    public var writable: Bool {
        get { userWritable }
        nonmutating set { try? chmod(newValue ? "+w" : "-w") }
    }
    /// Getter: the user bit. Setter: `chmod +x` / `-x` (umasked all).
    public var executable: Bool {
        get { userExecutable }
        nonmutating set { try? chmod(newValue ? "+x" : "-x") }
    }

    // MARK: - chown

    /// Changes owner and/or group by id — `chown(2)` (follows
    /// symlinks). `nil` leaves that half unchanged.
    @discardableResult
    public func chown(uid: uid_t? = nil, gid: gid_t? = nil) throws -> FS {
        try syscall { p in
            p.withPlatformString { C.chown($0, uid ?? .max, gid ?? .max) }
        }
    }

    /// Changes owner and/or group by name, Perl-style.
    @discardableResult
    public func chown(user: String? = nil, group: String? = nil) throws -> FS {
        var uid: uid_t?
        var gid: gid_t?
        if let user {
            guard let pw = getpwnam(user) else { throw Errno.invalidArgument }
            uid = pw.pointee.pw_uid
        }
        if let group {
            guard let gr = getgrnam(group) else { throw Errno.invalidArgument }
            gid = gr.pointee.gr_gid
        }
        return try chown(uid: uid, gid: gid)
    }

    // MARK: - rename & link

    /// Moves the node — `rename(2)`. Returns the node at its new home.
    @discardableResult
    public func rename(to newPath: FilePath) throws -> FS {
        try withExistingPath { p in
            let rc = p.withPlatformString { old in
                newPath.withPlatformString { new in C.rename(old, new) }
            }
            guard rc == 0 else { throw Errno(rawValue: errno) }
            return FS(newPath)
        }
    }

    @discardableResult
    public func rename(to newPath: String) throws -> FS {
        try rename(to: FilePath(newPath))
    }

    /// Creates a hard link at `newPath` to this node — `link(2)`.
    /// Returns the new link's node.
    @discardableResult
    public func link(to newPath: FilePath) throws -> FS {
        try withExistingPath { p in
            let rc = p.withPlatformString { old in
                newPath.withPlatformString { new in C.link(old, new) }
            }
            guard rc == 0 else { throw Errno(rawValue: errno) }
            return FS(newPath)
        }
    }

    @discardableResult
    public func link(to newPath: String) throws -> FS {
        try link(to: FilePath(newPath))
    }

    // MARK: - times & size

    /// Sets access/modification times — `utimes(2)`. With both `nil`
    /// (the default), sets both to now; with one `nil`, the other
    /// keeps its current value.
    @discardableResult
    public func utime(atime: Date? = nil, mtime: Date? = nil) throws -> FS {
        try withExistingPath { p in
            let rc: Int32
            if atime == nil && mtime == nil {
                rc = p.withPlatformString { C.utimes($0, nil) }
            } else {
                let newAtime = atime ?? self.atime ?? Date()
                let newMtime = mtime ?? self.mtime ?? Date()
                let times = [timeval(newAtime), timeval(newMtime)]
                rc = p.withPlatformString { s in
                    times.withUnsafeBufferPointer { C.utimes(s, $0.baseAddress) }
                }
            }
            guard rc == 0 else { throw Errno(rawValue: errno) }
            return FS(p)
        }
    }

    /// The shell's `touch`: creates an empty file if absent,
    /// updates both times to now if present.
    @discardableResult
    public func touch() throws -> FS {
        if case .error(let e, _) = self {
            guard e == .noSuchFileOrDirectory else { throw e }
            let fd = try FileDescriptor.open(
                path, .writeOnly, options: [.create],
                permissions: [.ownerReadWrite, .groupRead, .otherRead])
            try fd.close()
            return refreshed()
        }
        return try utime()
    }

    /// Cuts (or zero-extends) the file to `size` bytes — `truncate(2)`.
    @discardableResult
    public func truncate(to size: Int64 = 0) throws -> FS {
        try syscall { p in p.withPlatformString { C.truncate($0, off_t(size)) } }
    }

    // MARK: - mkfifo

    /// Creates a named pipe at this node's path — `mkfifo(2)`.
    /// A no-op if the node already is a `.fifo`.
    @discardableResult
    public func mkfifo(permissions: Permissions = [.userRead, .userWrite]) throws -> FS {
        switch self {
        case .fifo:
            return self
        case .error(.noSuchFileOrDirectory, let p):
            let rc = p.withPlatformString { C.mkfifo($0, permissions.rawValue) }
            guard rc == 0 else { throw Errno(rawValue: errno) }
            return refreshed()
        case .error(let e, _):
            throw e
        default:
            throw Errno.fileExists
        }
    }
}

extension Sys {
    /// Changes the working directory — `chdir(2)`. Process-global,
    /// which is why it lives on Sys, not FS.
    public static func chdir(_ path: FilePath) throws {
        let rc = path.withPlatformString { C.chdir($0) }
        guard rc == 0 else { throw Errno(rawValue: errno) }
    }

    public static func chdir(_ path: String) throws {
        try chdir(FilePath(path))
    }

    public static func chdir(_ node: FS) throws {
        if case .error(let e, _) = node { throw e }
        try chdir(node.path)
    }

    /// Sets the file-creation mask — `umask(2)` — and returns the
    /// previous one. Process-global. Takes octal literals too:
    /// `Sys.umask(0o022)`.
    @discardableResult
    public static func umask(_ mask: FS.Permissions) -> FS.Permissions {
        FS.Permissions(rawValue: C.umask(mask.rawValue))
    }
}

extension timeval {
    fileprivate init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        let sec = interval.rounded(.down)
        self.init(tv_sec: time_t(sec),
                  tv_usec: suseconds_t((interval - sec) * 1_000_000))
    }
}
