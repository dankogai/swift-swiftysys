//
//  IO.swift
//  SwiftySys
//
//  Streams, the sibling of FS. Where FS is the namespace view of the
//  system (nodes, value semantics, one lstat), IO is the byte-moving
//  view: an open file descriptor with reference semantics — files,
//  pipes to processes, and (eventually) sockets.
//
//  Ruby's split, Perl's soul: `IO.open("| sort")` and `IO.open("ls |")`
//  work like Perl's 2-arg open, but the magic is sugar over explicit
//  primitives (`IO.open(path, .write)`, `IO.popen(cmd, .read)`) —
//  use those when any part of the spec is not a literal.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class IO {
    public enum Mode: Sendable {
        case read, write, append, readWrite
    }

    internal let fd: FileDescriptor
    private let ownsFD: Bool
    private var process: Process?
    private var handle: FileHandle?     // keeps a pipe's fd alive
    public private(set) var isClosed = false
    /// Exit status of the piped process — or, for URL streams, the
    /// HTTP status — available after `close()`.
    public internal(set) var terminationStatus: Int32?
    /// Runs during `close()`, before the descriptor closes; its result
    /// becomes `terminationStatus`. Used by URL-backed streams to
    /// upload on close.
    internal var finisher: (() throws -> Int32?)?

    internal init(fd: FileDescriptor, ownsFD: Bool,
                 process: Process? = nil, handle: FileHandle? = nil) {
        self.fd = fd
        self.ownsFD = ownsFD
        self.process = process
        self.handle = handle
    }

    deinit {
        try? close()
    }

    // MARK: - Opening files

    /// Opens a file. `.write` creates/truncates, `.append` creates/appends.
    public static func open(_ path: FilePath, _ mode: Mode = .read) throws -> IO {
        let perms: FilePermissions = [.ownerReadWrite, .groupRead, .otherRead]
        let fd: FileDescriptor
        switch mode {
        case .read:
            fd = try .open(path, .readOnly)
        case .write:
            fd = try .open(path, .writeOnly,
                           options: [.create, .truncate], permissions: perms)
        case .append:
            fd = try .open(path, .writeOnly,
                           options: [.create, .append], permissions: perms)
        case .readWrite:
            fd = try .open(path, .readWrite,
                           options: [.create], permissions: perms)
        }
        return IO(fd: fd, ownsFD: true)
    }

    /// Perl-style 2-arg open. The spec decides what happens:
    ///
    /// ```swift
    /// try IO.open("< in.txt")      // read (the "<" is optional)
    /// try IO.open("> out.txt")     // create/truncate
    /// try IO.open(">> log.txt")    // create/append
    /// try IO.open("| sort -u")     // pipe: write to command's stdin
    /// try IO.open("ls -la |")      // pipe: read command's stdout
    /// try IO.open("https://example.com")     // GET — read the body
    /// try IO.open("| https://api.example")   // POST on close()
    /// ```
    ///
    /// Sugar for literals only — interpolating untrusted strings into
    /// a spec is the same injection Perl's 2-arg open is famous for.
    /// Use `IO.open(path, mode)` / `IO.popen(command, mode)` for those.
    public static func open(_ spec: String) throws -> IO {
        let s = spec.trimmingCharacters(in: .whitespaces)
        func rest(_ n: Int) -> String {
            String(s.dropFirst(n)).trimmingCharacters(in: .whitespaces)
        }
        func asURL(_ s: String) -> URL? {
            guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
            return URL(string: s)
        }
        if let url = asURL(s) { return try open(url) }
        if s.hasPrefix("|") {
            let target = rest(1)
            if let url = asURL(target) { return try open(url, .write) }
            return try popen(target, .write)
        }
        if s.hasSuffix("|") {
            let cmd = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
            return try popen(cmd, .read)
        }
        if s.hasPrefix(">>") { return try open(FilePath(rest(2)), .append) }
        if s.hasPrefix(">")  { return try open(FilePath(rest(1)), .write) }
        if s.hasPrefix("<")  { return try open(FilePath(rest(1)), .read) }
        return try open(FilePath(s), .read)
    }

    // MARK: - Opening processes

    /// Runs `command` via `/bin/sh -c` and returns a stream connected
    /// to its stdout (`.read`) or stdin (`.write`).
    /// `close()` waits for the process and records `terminationStatus`.
    public static func popen(_ command: String, _ mode: Mode = .read) throws -> IO {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return try popen(process: process, mode)
    }

    /// Reads a command's stdout — `"cmd -opts |"` — but as an argv
    /// list run directly, with no shell in between: Perl's safer
    /// list-form `open($fh, "-|", @cmd)`. Arguments are passed
    /// verbatim, so there is nothing to inject:
    ///
    /// ```swift
    /// let io = try IO.readPipe(from: ["ls", "-la", userSuppliedPath])
    /// ```
    ///
    /// `argv[0]` is resolved against `PATH` unless it contains a `/`.
    public static func readPipe(from argv: [String]) throws -> IO {
        try popen(argv: argv, .read)
    }

    /// Writes to a command's stdin — `"| cmd -opts"` — as an argv
    /// list run directly, no shell: Perl's `open($fh, "|-", @cmd)`.
    public static func writePipe(to argv: [String]) throws -> IO {
        try popen(argv: argv, .write)
    }

    private static func popen(argv: [String], _ mode: Mode) throws -> IO {
        guard let cmd = argv.first else { throw Errno.invalidArgument }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try which(cmd))
        process.arguments = Array(argv.dropFirst())
        return try popen(process: process, mode)
    }

    private static func popen(process: Process, _ mode: Mode) throws -> IO {
        let pipe = Pipe()
        let handle: FileHandle
        switch mode {
        case .read:
            process.standardOutput = pipe
            handle = pipe.fileHandleForReading
        case .write:
            process.standardInput = pipe
            handle = pipe.fileHandleForWriting
        case .append, .readWrite:
            throw Errno.invalidArgument
        }
        try process.run()
        return IO(fd: FileDescriptor(rawValue: handle.fileDescriptor),
                  ownsFD: false, process: process, handle: handle)
    }

    /// execvp(3)-style PATH resolution. A name containing `/` is used
    /// as-is; otherwise each PATH entry is tried for an executable.
    internal static func which(_ cmd: String) throws -> String {
        if cmd.contains("/") { return cmd }
        let path = getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
        for dir in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = (dir.isEmpty ? "." : String(dir)) + "/" + cmd
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw Errno.noSuchFileOrDirectory
    }

    // MARK: - Standard streams

    /// A fresh wrapper each access; closing it does not close the fd.
    public static var stdin: IO { IO(fd: .standardInput, ownsFD: false) }
    public static var stdout: IO { IO(fd: .standardOutput, ownsFD: false) }
    public static var stderr: IO { IO(fd: .standardError, ownsFD: false) }

    // MARK: - Reading

    /// Reads up to `count` bytes; empty `Data` means EOF.
    public func read(_ count: Int) throws -> Data {
        if isClosed { throw Errno.badFileDescriptor }
        var buf = [UInt8](repeating: 0, count: count)
        let n = try buf.withUnsafeMutableBytes { try fd.read(into: $0) }
        return Data(buf[0..<n])
    }

    /// Reads to EOF — the slurp.
    public func readAll() throws -> Data {
        if isClosed { throw Errno.badFileDescriptor }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = try buf.withUnsafeMutableBytes { try fd.read(into: $0) }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    /// Reads to EOF and decodes as UTF-8.
    public func readString() throws -> String {
        let data = try readAll()
        guard let s = String(data: data, encoding: .utf8) else {
            throw Errno.invalidArgument
        }
        return s
    }

    // MARK: - Writing

    public func write(_ data: Data) throws {
        if isClosed { throw Errno.badFileDescriptor }
        try fd.writeAll(data)
    }

    public func write(_ string: String) throws {
        try write(Data(string.utf8))
    }

    // MARK: - Closing

    /// Closes the stream. For pipes, waits for the process and returns
    /// its exit status (also kept in `terminationStatus`), like Perl's
    /// `close` setting `$?`. Idempotent.
    @discardableResult
    public func close() throws -> Int32? {
        guard !isClosed else { return terminationStatus }
        isClosed = true
        // the finisher needs the descriptor, so it runs first;
        // its error is held so the fd still gets closed
        var pendingError: Error?
        if let finisher {
            self.finisher = nil
            do { terminationStatus = try finisher() }
            catch { pendingError = error }
        }
        if let handle {
            try handle.close()
        } else if ownsFD {
            try fd.close()
        }
        handle = nil
        if let process {
            process.waitUntilExit()
            terminationStatus = process.terminationStatus
            self.process = nil
        }
        if let pendingError { throw pendingError }
        return terminationStatus
    }
}

// MARK: - qx()

extension IO {
    /// Perl's `qx()` / backticks: runs `command` through the shell and
    /// returns its stdout. The exit status is not checked, just like
    /// Perl; use `IO.popen` + `close()` if you need it.
    public static func qx(_ command: String) throws -> String {
        let io = try popen(command, .read)
        let out = try io.readString()
        try io.close()
        return out
    }
}

// MARK: - FS ↔ IO bridge

extension FS {
    /// Opens this node as a stream. Works on `.file` and — for modes
    /// that create — on `.error(.noSuchFileOrDirectory, _)`, so a
    /// subscript chain flows straight into an open:
    ///
    /// ```swift
    /// let out = try FS.temp["build.log"].open(.append)
    /// ```
    public func open(_ mode: IO.Mode = .read) throws -> IO {
        if case .error(let e, _) = self, e != .noSuchFileOrDirectory { throw e }
        return try IO.open(path, mode)
    }
}
