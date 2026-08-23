import Testing
import Foundation
@testable import SwiftySys

/// Runs `body` with a fresh temporary directory, cleaning up afterward.
private func withTempDir(_ body: (FS) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftySysIOTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(FS(url.path))
}

@Suite struct FileStreams {
    @Test func writeThenRead() throws {
        try withTempDir { dir in
            let path = dir.path.appending("f.txt")
            let out = try IO.open(path, .write)
            try out.write("hello, ")
            try out.write("world\n")
            try out.close()
            let input = try IO.open(path)
            #expect(try input.readString() == "hello, world\n")
            try input.close()
        }
    }

    @Test func appendMode() throws {
        try withTempDir { dir in
            let path = dir.path.appending("log.txt")
            try IO.open(path, .write).write("one\n")
            let out = try IO.open(path, .append)
            try out.write("two\n")
            try out.close()
            #expect(FS(path).string == "one\ntwo\n")
        }
    }

    @Test func partialRead() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("0123456789")
            let io = try file.open()
            #expect(try io.read(4) == Data("0123".utf8))
            #expect(try io.read(100) == Data("456789".utf8))
            #expect(try io.read(100).isEmpty)  // EOF
            try io.close()
        }
    }

    @Test func closeIsIdempotent() throws {
        try withTempDir { dir in
            let io = try dir["f.txt"].open(.write)
            try io.close()
            #expect(try io.close() == nil)
            #expect(throws: Errno.badFileDescriptor) { try io.write("x") }
        }
    }
}

@Suite struct MagicOpen {
    @Test func fileSpecs() throws {
        try withTempDir { dir in
            let path = dir.pathString
            try IO.open("> \(path)/a.txt").write("first\n")
            try IO.open(">> \(path)/a.txt").write("second\n")
            #expect(try IO.open("< \(path)/a.txt").readString() == "first\nsecond\n")
            // bare path reads too
            #expect(try IO.open("\(path)/a.txt").readString() == "first\nsecond\n")
        }
    }

    @Test func readFromCommand() throws {
        let io = try IO.open("echo hello |")
        #expect(try io.readString() == "hello\n")
        #expect(try io.close() == 0)
    }

    @Test func writeToCommand() throws {
        try withTempDir { dir in
            let path = dir.path.appending("out.txt")
            let io = try IO.open("| sort > '\(path)'")
            try io.write("banana\napple\ncherry\n")
            try io.close()
            #expect(FS(path).string == "apple\nbanana\ncherry\n")
        }
    }
}

@Suite struct Popen {
    @Test func explicitPopen() throws {
        let io = try IO.popen("printf 'a\\nb\\nc' | wc -l | tr -d ' '", .read)
        #expect(try io.readString() == "2\n")
        try io.close()
    }

    @Test func terminationStatus() throws {
        let io = try IO.popen("exit 3", .read)
        #expect(try io.readAll().isEmpty)
        #expect(try io.close() == 3)
        #expect(io.terminationStatus == 3)
    }

    @Test func popenRejectsBadModes() {
        #expect(throws: Errno.invalidArgument) { try IO.popen("true", .append) }
    }
}

@Suite struct ListPipes {
    @Test func readPipe() throws {
        let io = try IO.readPipe(from: ["echo", "hello"])
        #expect(try io.readString() == "hello\n")
        #expect(try io.close() == 0)
    }

    @Test func noShellInterpretation() throws {
        // shell metacharacters arrive verbatim — nothing to inject
        let evil = "$(whoami); rm -rf /tmp/x | `date` > out"
        let io = try IO.readPipe(from: ["printf", "%s", evil])
        #expect(try io.readString() == evil)
        try io.close()
    }

    @Test func writePipe() throws {
        try withTempDir { dir in
            let path = dir.path.appending("sorted.txt")
            // sort -o writes to a file, so no shell redirection is needed
            let io = try IO.writePipe(to: ["sort", "-o", path.string])
            try io.write("banana\napple\ncherry\n")
            #expect(try io.close() == 0)
            #expect(FS(path).string == "apple\nbanana\ncherry\n")
        }
    }

    @Test func pathResolution() throws {
        // "echo" above proved PATH lookup; a slash skips it
        let io = try IO.readPipe(from: ["/bin/echo", "direct"])
        #expect(try io.readString() == "direct\n")
        try io.close()
    }

    @Test func exitStatus() throws {
        let io = try IO.readPipe(from: ["false"])
        #expect(try io.readAll().isEmpty)
        #expect(try io.close() == 1)
    }

    @Test func missingCommandThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            try IO.readPipe(from: ["no-such-command-xyzzy-\(UUID().uuidString)"])
        }
    }

    @Test func emptyArgvThrows() {
        #expect(throws: Errno.invalidArgument) { try IO.readPipe(from: []) }
        #expect(throws: Errno.invalidArgument) { try IO.writePipe(to: []) }
    }
}

@Suite struct Open3Tests {
    @Test func separatesTheStreams() throws {
        let p = try IO.open3("echo out; echo err >&2")
        #expect(try p.stdout.readString() == "out\n")
        #expect(try p.stderr.readString() == "err\n")
        #expect(p.close() == 0)
        #expect(p.terminationStatus == 0)
    }

    @Test func argvFormNoShell() throws {
        let evil = "$(whoami); echo pwned >&2"
        let p = try IO.open3(["echo", evil])
        #expect(try p.stdout.readString() == evil + "\n")
        #expect(try p.stderr.readString() == "")
        #expect(p.close() == 0)
    }

    @Test func stdinFlows() throws {
        let p = try IO.open3(["tr", "a-z", "A-Z"])
        try p.stdin.write("hello, open3\n")
        try p.stdin.close()
        #expect(try p.stdout.readString() == "HELLO, OPEN3\n")
        #expect(p.close() == 0)
    }

    @Test func captureBasics() throws {
        let r = try IO.open3("echo out; echo err >&2; exit 7").capture()
        #expect(r.stdoutString == "out\n")
        #expect(r.stderrString == "err\n")
        #expect(r.status == 7)
    }

    @Test func captureFeedsStdin() throws {
        let r = try IO.open3(["tr", "a-z", "A-Z"]).capture(stdin: "mixed Case\n")
        #expect(r.stdoutString == "MIXED CASE\n")
        #expect(r.stderr.isEmpty)
        #expect(r.status == 0)
    }

    @Test func captureBigStderrDoesNotDeadlock() throws {
        // way past the 64KB pipe buffer, all on the "wrong" stream
        let r = try IO.open3("head -c 300000 /dev/zero >&2").capture()
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.count == 300_000)
        #expect(r.status == 0)
    }

    @Test func captureBigRoundTrip() throws {
        // stdin and stdout both far beyond the pipe buffer
        let blob = Data((0..<300_000).map { UInt8($0 % 251) })
        let r = try IO.open3(["cat"]).capture(stdin: blob)
        #expect(r.stdout == blob)
        #expect(r.status == 0)
    }

    @Test func closeIsIdempotent() throws {
        let p = try IO.open3(["true"])
        #expect(p.close() == 0)
        #expect(p.close() == 0)
    }

    @Test func emptyArgvThrows() {
        #expect(throws: Errno.invalidArgument) { try IO.open3([]) }
    }
}

@Suite struct Qx {
    @Test func capturesOutput() throws {
        #expect(try IO.qx("echo hello") == "hello\n")
        #expect(try IO.qx("printf '%s' 'no newline'") == "no newline")
    }

    @Test func shellFeaturesWork() throws {
        // pipes and env, like Perl's backticks
        #expect(try IO.qx("echo FOO | tr A-Z a-z") == "foo\n")
    }
}

@Suite struct Bridge {
    @Test func fsToIO() throws {
        try withTempDir { dir in
            // ENOENT node + creating mode = just works
            let out = try dir["new.txt"].open(.write)
            try out.write("via bridge\n")
            try out.close()
            #expect(dir["new.txt"].string == "via bridge\n")
        }
    }

    @Test func frozenErrorsRefuse() throws {
        try withTempDir { dir in
            let file = try dir["plain.txt"].write("x")
            #expect(throws: Errno.notDirectory) {
                try file["child.txt"].open(.write)
            }
        }
    }

    @Test func readNonexistentThrows() throws {
        try withTempDir { dir in
            #expect(throws: Errno.noSuchFileOrDirectory) {
                try dir["nope.txt"].open()
            }
        }
    }
}
