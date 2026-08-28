//
//  Pipeline.swift
//  SwiftySys
//
//  The shell's pipe as an operator. The left-hand side — an FS node
//  or an IO stream — feeds a command's stdin; the result is an IO
//  reading the command's stdout, so pipes chain:
//
//      try FS("words.txt") | "sort -u" | "wc -l"       // shell, for literals
//      try FS("access.log") | ["grep", userInput]      // argv, NO shell
//
//  Swift gives `|` addition-level precedence, looser than `>` at
//  comparison level — so redirection composes exactly like the shell,
//  no parentheses:
//
//      try FS("words.txt") | "sort -u" >! "sorted.txt"
//
//  (`>>`/`>>!` sit at shift precedence, tighter than `|` — those
//  need parens: `try (node | "sort") >>! "log"`.)
//
//  Plumbing is kernel-level where possible: a file or an unbuffered
//  stream hands its descriptor straight to the child, so a 10GB
//  pipeline never passes through this process. Only read-ahead from
//  `readLine()` needs a pump thread, which splices and gets out of
//  the way. `close()` on the tail waits and cascades upstream; its
//  status is the tail command's — the shell's `$?`.
//
//  String deliberately does not stand on the LEFT of `|`: wrap it —
//  FS(...) to mean a file. The right-hand side is always the command.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Pipe into a shell command — sugar for literals, like `IO.popen`.
public func | (source: IO, command: String) throws -> IO {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    return try pipeline(source, into: process)
}

/// Pipe into an argv run directly, no shell — like `readPipe(from:)`,
/// nothing to inject.
public func | (source: IO, argv: [String]) throws -> IO {
    guard let cmd = argv.first else { throw Errno.invalidArgument }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: try IO.which(cmd))
    process.arguments = Array(argv.dropFirst())
    return try pipeline(source, into: process)
}

/// Pipe a file's contents into a shell command.
public func | (source: FS, command: String) throws -> IO {
    try source.open() | command
}

/// Pipe a file's contents into an argv, no shell.
public func | (source: FS, argv: [String]) throws -> IO {
    try source.open() | argv
}

private func pipeline(_ source: IO, into process: Process) throws -> IO {
    if source.isClosed { throw Errno.badFileDescriptor }
    let out = Pipe()
    process.standardOutput = out
    if source.readBuffer.isEmpty {
        // nothing buffered: the child inherits the descriptor itself —
        // bytes flow kernel-side, never through this process
        process.standardInput = FileHandle(fileDescriptor: source.fd.rawValue,
                                           closeOnDealloc: false)
        try process.run()
    } else {
        // readLine() read ahead: pump the buffered bytes, then splice
        // the rest, on a thread that closes the write end at EOF
        let feed = Pipe()
        process.standardInput = feed
        try process.run()
        let buffered = Data(source.readBuffer)
        source.readBuffer = Data()
        let srcFD = source.fd.rawValue
        let sinkFD = feed.fileHandleForWriting.fileDescriptor
        ignoreSIGPIPE(on: sinkFD)
        Thread.detachNewThread { [feed] in
            pump(buffered, then: srcFD, into: sinkFD)
            try? feed.fileHandleForWriting.close()
        }
    }
    let io = IO(fd: FileDescriptor(rawValue: out.fileHandleForReading.fileDescriptor),
                ownsFD: false, process: process, handle: out.fileHandleForReading)
    io.upstream = source
    return io
}

/// Writes `buffered`, then copies `srcFD` to EOF, into `sinkFD`.
/// Best-effort: a broken pipe (the child exited early) just stops.
private func pump(_ buffered: Data, then srcFD: Int32, into sinkFD: Int32) {
    func writeAll(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var p = bytes.baseAddress!
        var left = bytes.count
        while left > 0 {
            let n = write(sinkFD, p, left)
            if n <= 0 {
                if errno == EINTR { continue }
                return false
            }
            p += n
            left -= n
        }
        return true
    }
    let ok = buffered.withUnsafeBytes { writeAll($0) }
    guard ok else { return }
    var buf = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = buf.withUnsafeMutableBytes { read(srcFD, $0.baseAddress, $0.count) }
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return }
        let done = buf.withUnsafeBytes {
            writeAll(UnsafeRawBufferPointer(rebasing: $0[0..<n]))
        }
        guard done else { return }
    }
}

/// The pump must survive the child exiting mid-stream: EPIPE from
/// write(2), not a process-killing SIGPIPE.
private func ignoreSIGPIPE(on fd: Int32) {
    #if canImport(Darwin)
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    #else
    // no F_SETNOSIGPIPE on Linux; ignore the signal process-wide,
    // which is what every scripting runtime does
    signal(SIGPIPE, SIG_IGN)
    #endif
}
