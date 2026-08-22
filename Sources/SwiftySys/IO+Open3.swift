//
//  IO+Open3.swift
//  SwiftySys
//
//  Perl's IPC::Open3: run a child process with stdin, stdout and
//  stderr each connected to its own stream.
//
//      let p = try IO.open3(["make", "-j8"])   // argv — no shell
//      let p = try IO.open3("make 2>&1 | tee") // or via /bin/sh -c
//      try p.stdin.write("...")
//      try p.stdin.close()
//      let out = try p.stdout.readString()
//      let err = try p.stderr.readString()
//      p.close()                               // waits; exit status
//
//  Reading one pipe to EOF while the other fills its buffer is
//  open3's classic deadlock (Perl's docs warn about it too). When
//  you just want everything, use capture(stdin:) — it multiplexes
//  all three descriptors with poll(2) on a single thread, so no
//  amount of output on either stream can wedge the child.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO {
    /// Runs `command` via `/bin/sh -c` with all three standard
    /// streams piped.
    public static func open3(_ command: String) throws -> Open3 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        return try Open3(process: process)
    }

    /// Runs the argv directly — no shell, PATH-resolved `argv[0]` —
    /// with all three standard streams piped.
    public static func open3(_ argv: [String]) throws -> Open3 {
        guard let cmd = argv.first else { throw Errno.invalidArgument }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try which(cmd))
        process.arguments = Array(argv.dropFirst())
        return try Open3(process: process)
    }

    /// A child process with `stdin`, `stdout` and `stderr` streams.
    public final class Open3 {
        public let stdin: IO
        public let stdout: IO
        public let stderr: IO
        private let process: Process
        /// Exit status, available after `close()` (or `capture`).
        public private(set) var terminationStatus: Int32?

        internal init(process: Process) throws {
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            self.process = process
            self.stdin = IO(
                fd: FileDescriptor(rawValue: inPipe.fileHandleForWriting.fileDescriptor),
                ownsFD: false, handle: inPipe.fileHandleForWriting)
            self.stdout = IO(
                fd: FileDescriptor(rawValue: outPipe.fileHandleForReading.fileDescriptor),
                ownsFD: false, handle: outPipe.fileHandleForReading)
            self.stderr = IO(
                fd: FileDescriptor(rawValue: errPipe.fileHandleForReading.fileDescriptor),
                ownsFD: false, handle: errPipe.fileHandleForReading)
        }

        deinit {
            close()
        }

        /// Closes all three streams, waits for the child, and returns
        /// its exit status. Idempotent.
        @discardableResult
        public func close() -> Int32 {
            if let status = terminationStatus { return status }
            try? stdin.close()
            try? stdout.close()
            try? stderr.close()
            process.waitUntilExit()
            let status = process.terminationStatus
            terminationStatus = status
            return status
        }

        /// What `capture` collected.
        public struct Captured: Sendable {
            public let stdout: Data
            public let stderr: Data
            public let status: Int32
            public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
            public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
        }

        /// Feeds `input` to the child's stdin, slurps stdout and
        /// stderr to EOF, waits, and returns all three results.
        ///
        /// All three descriptors are multiplexed with `poll(2)` on
        /// the calling thread, so arbitrarily large input and output
        /// cannot deadlock. Consumes the streams: the Open3 is fully
        /// closed afterward.
        public func capture(stdin input: Data = Data()) -> Captured {
            var outData = Data()
            var errData = Data()
            var pending = input[...]

            let inFD = self.stdin.fd.rawValue
            let outFD = self.stdout.fd.rawValue
            let errFD = self.stderr.fd.rawValue
            // POLLOUT does not promise room for a whole chunk, and a
            // blocking write(2) larger than the free pipe space stalls
            // until it ALL fits — while the child blocks writing output
            // we are not draining: deadlock. Non-blocking writes take
            // what fits and return; EAGAIN just means "poll again".
            _ = fcntl(inFD, F_SETFL, fcntl(inFD, F_GETFL, 0) | O_NONBLOCK)
            var stdinOpen = true
            var stdoutOpen = true
            var stderrOpen = true
            if pending.isEmpty {
                try? self.stdin.close()
                stdinOpen = false
            }
            let badBits = Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)
            var buf = [UInt8](repeating: 0, count: 1 << 16)

            while stdinOpen || stdoutOpen || stderrOpen {
                var pfds: [pollfd] = []
                if stdinOpen { pfds.append(pollfd(fd: inFD, events: Int16(POLLOUT), revents: 0)) }
                if stdoutOpen { pfds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0)) }
                if stderrOpen { pfds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)) }
                guard poll(&pfds, nfds_t(pfds.count), -1) >= 0 else {
                    if Errno(rawValue: errno) == .interrupted { continue }
                    break
                }
                for pfd in pfds where pfd.revents != 0 {
                    switch pfd.fd {
                    case inFD:
                        // check for a dead reader before writing:
                        // that is what keeps SIGPIPE (mostly) away
                        if pfd.revents & badBits != 0 {
                            try? self.stdin.close()
                            stdinOpen = false
                            continue
                        }
                        let n = pending.prefix(1 << 16).withUnsafeBytes {
                            posixWrite(inFD, $0.baseAddress, $0.count)
                        }
                        if n > 0 {
                            pending = pending.dropFirst(n)
                            if pending.isEmpty {
                                try? self.stdin.close()
                                stdinOpen = false
                            }
                        } else if n < 0 {
                            let e = Errno(rawValue: errno)
                            if e != .resourceTemporarilyUnavailable && e != .interrupted {
                                try? self.stdin.close()   // EPIPE etc.
                                stdinOpen = false
                            }
                        }
                    case outFD, errFD:
                        // read even on POLLHUP — the buffer may still
                        // hold data; EOF is when read returns 0
                        let n = posixRead(pfd.fd, &buf, buf.count)
                        if n > 0 {
                            if pfd.fd == outFD {
                                outData.append(contentsOf: buf[0..<n])
                            } else {
                                errData.append(contentsOf: buf[0..<n])
                            }
                        } else {
                            if pfd.fd == outFD {
                                try? self.stdout.close()
                                stdoutOpen = false
                            } else {
                                try? self.stderr.close()
                                stderrOpen = false
                            }
                        }
                    default:
                        break
                    }
                }
            }
            return Captured(stdout: outData, stderr: errData, status: close())
        }

        public func capture(stdin input: String) -> Captured {
            capture(stdin: Data(input.utf8))
        }
    }
}

private func posixRead(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buf, count)
    #else
    Glibc.read(fd, buf, count)
    #endif
}

private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer?, _ count: Int) -> Int {
    guard let buf, count > 0 else { return 0 }
    #if canImport(Darwin)
    return Darwin.write(fd, buf, count)
    #else
    return Glibc.write(fd, buf, count)
    #endif
}
