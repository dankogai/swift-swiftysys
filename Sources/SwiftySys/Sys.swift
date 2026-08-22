//
//  Sys.swift
//  SwiftySys
//
//  The third pillar, and the one the module is named for. Where FS is
//  the namespace view and IO is the stream view, Sys is the *process*
//  view: Python's `sys` plus the Perl core variables every script
//  reaches for — @ARGV, %ENV, $$, $0, $<.
//
//  Sys is a caseless enum: a pure namespace, nothing to instantiate.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum Sys {
    // MARK: - Arguments & executable

    /// Command-line arguments, `argv[0]` included — Python's `sys.argv`,
    /// Perl's `$0` + `@ARGV`.
    public static var argv: [String] { CommandLine.arguments }

    /// The running executable as an FS node — Python's `sys.executable`.
    public static var executable: FS {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return FS(argv.first ?? "")
        }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return FS(String(decoding: bytes, as: UTF8.self))
        #else
        return FS("/proc/self/exe").resolved()
        #endif
    }

    // MARK: - Environment

    /// The environment, dictionary-style — Python's `os.environ`,
    /// Perl's `%ENV`:
    ///
    /// ```swift
    /// Sys.env["HOME"]              // String?
    /// Sys.env["DEBUG"] = "1"       // setenv
    /// Sys.env.unset("DEBUG")       // unsetenv (assigning nil works too)
    /// for (key, value) in Sys.env { ... }
    /// ```
    public static var env: Env { Env() }

    public struct Env: Sendable, Sequence {
        public subscript(_ name: String) -> String? {
            get { getenv(name).map { String(cString: $0) } }
            nonmutating set {
                if let newValue {
                    setenv(name, newValue, 1)
                } else {
                    unsetenv(name)
                }
            }
        }

        /// Removes the variable. Unlike a file, an env var costs
        /// nothing to unset, so `env["X"] = nil` also works.
        public func unset(_ name: String) {
            unsetenv(name)
        }

        /// A snapshot as a plain dictionary.
        public var dictionary: [String: String] {
            ProcessInfo.processInfo.environment
        }

        /// Variable names, sorted.
        public var keys: [String] { dictionary.keys.sorted() }

        public var count: Int { dictionary.count }

        public func makeIterator() -> AnyIterator<(key: String, value: String)> {
            var inner = dictionary.sorted { $0.key < $1.key }.makeIterator()
            return AnyIterator { inner.next() }
        }
    }

    // MARK: - Process & user identity

    /// Process id — Perl's `$$`.
    public static var pid: Int32 { getpid() }

    /// Parent process id.
    public static var ppid: Int32 { getppid() }

    /// Real and effective user/group ids — Perl's `$<`, `$>`, `$(`, `$)`.
    public static var uid: uid_t { getuid() }
    public static var euid: uid_t { geteuid() }
    public static var gid: gid_t { getgid() }
    public static var egid: gid_t { getegid() }

    /// The effective user's login name.
    public static var user: String {
        if let pw = getpwuid(geteuid()), let name = pw.pointee.pw_name {
            return String(cString: name)
        }
        return env["USER"] ?? env["LOGNAME"] ?? ""
    }

    // MARK: - The machine

    /// "darwin" or "linux" — Python's `sys.platform`.
    public static var platform: String {
        #if os(macOS)
        "darwin"
        #elseif os(Linux)
        "linux"
        #else
        "unknown"
        #endif
    }

    /// "little" or "big" — Python's `sys.byteorder`.
    public static var byteOrder: String {
        withUnsafeBytes(of: UInt16(0x0102)) { $0[0] == 0x02 ? "little" : "big" }
    }

    /// The hostname.
    public static var hostname: String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count - 1) == 0 else { return "" }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A human-readable OS version, e.g. "Version 15.6 (Build 24G84)".
    public static var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// Number of active CPU cores.
    public static var cpuCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// uname(2), decoded.
    public struct UTSName: Sendable {
        public let sysname: String
        public let nodename: String
        public let release: String
        public let version: String
        public let machine: String
    }

    /// `uname -a`, structured — sysname/nodename/release/version/machine.
    public static var uname: UTSName {
        var u = utsname()
        #if canImport(Darwin)
        _ = Darwin.uname(&u)
        #else
        _ = Glibc.uname(&u)
        #endif
        func str<T>(_ field: T) -> String {
            withUnsafePointer(to: field) {
                $0.withMemoryRebound(to: CChar.self,
                                     capacity: MemoryLayout<T>.size) {
                    String(cString: $0)
                }
            }
        }
        return UTSName(sysname: str(u.sysname), nodename: str(u.nodename),
                       release: str(u.release), version: str(u.version),
                       machine: str(u.machine))
    }

    // MARK: - Standard streams & exit

    /// `sys.stdin` / `sys.stdout` / `sys.stderr` — the same streams
    /// as `IO.stdin` etc., here for the homage.
    public static var stdin: IO { IO.stdin }
    public static var stdout: IO { IO.stdout }
    public static var stderr: IO { IO.stderr }

    /// Terminates the process — Python's `sys.exit`.
    public static func exit(_ status: Int32 = 0) -> Never {
        #if canImport(Darwin)
        Darwin.exit(status)
        #else
        Glibc.exit(status)
        #endif
    }
}
