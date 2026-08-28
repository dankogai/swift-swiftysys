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

    @Test func modesCompose() throws {
        try withTempDir { dir in
            let path = dir.path.appending("rw.txt")
            try IO.open(path, .write).write("0123456789")
            // [.read, .write] opens without truncating...
            let rw = try IO.open(path, [.read, .write])
            #expect(try rw.read(4) == Data("0123".utf8))
            try rw.close()
            #expect(FS(path).size == 10)
            // ...while .write alone truncates
            try IO.open(path, .write).close()
            #expect(FS(path).size == 0)
            // [.read, .append]: writes land at the end, reads work
            try IO.open(path, .write).write("head-")
            let ra = try IO.open(path, [.read, .append])
            try ra.write("tail")
            try ra.close()
            #expect(FS(path).string == "head-tail")
        }
    }

    @Test func modeAlgebra() {
        #expect(IO.Mode.readWrite == [.read, .write])
        #expect(IO.Mode.readWrite.contains(.read))
        #expect(!IO.Mode.append.contains(.write))   // append implies write in effect, not in bits
    }

    @Test func emptyModeThrows() throws {
        try withTempDir { dir in
            #expect(throws: Errno.invalidArgument) {
                try IO.open(dir.path.appending("x.txt"), [])
            }
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

@Suite struct LineIteration {
    @Test func linesFromFile() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("one\ntwo\nthree\n")
            #expect(Array(try file.open().lines) == ["one", "two", "three"])
        }
    }

    @Test func lastLineWithoutNewline() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("a\nb")   // no trailing newline
            #expect(Array(try file.open().lines) == ["a", "b"])
        }
    }

    @Test func blankLinesSurvive() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("a\n\nb\n")
            #expect(Array(try file.open().lines) == ["a", "", "b"])
        }
    }

    @Test func crlfChomps() throws {
        try withTempDir { dir in
            let file = try dir["dos.txt"].write("a\r\nb\r\n")
            #expect(Array(try file.open().lines) == ["a", "b"])
        }
    }

    @Test func readLineStripsOrKeeps() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("one\ntwo")
            let io = try file.open()
            #expect(try io.readLine() == "one")
            #expect(try io.readLine(strippingNewline: false) == "two")
            #expect(try io.readLine() == nil)               // EOF
            #expect(try io.readLine() == nil)               // stays EOF
            try io.close()
            let raw = try file.open()
            #expect(try raw.readLine(strippingNewline: false) == "one\n")
            try raw.close()
        }
    }

    @Test func linesFromPipe() throws {
        let io = try IO.open("printf 'a\\nb\\nc' |")
        #expect(Array(io.lines) == ["a", "b", "c"])
        #expect(try io.close() == 0)
    }

    @Test func mixesWithByteReads() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("head\nbody:0123456789\ntail\n")
            let io = try file.open()
            #expect(try io.readLine() == "head")            // buffers ahead
            #expect(try io.read(5) == Data("body:".utf8))   // drains buffer
            #expect(try io.readLine() == "0123456789")
            #expect(try io.readAll() == Data("tail\n".utf8))
            try io.close()
        }
    }

    @Test func longLinesCrossChunks() throws {
        try withTempDir { dir in
            let long = String(repeating: "x", count: 200_000)   // > 64KB chunk
            let file = try dir["long.txt"].write("\(long)\nshort\n")
            let got = Array(try file.open().lines)
            #expect(got.count == 2)
            #expect(got[0] == long)
            #expect(got[1] == "short")
        }
    }

    @Test func emptyFileYieldsNothing() throws {
        try withTempDir { dir in
            let file = try dir["empty.txt"].write("")
            #expect(Array(try file.open().lines).isEmpty)
        }
    }

    @Test func fsSugar() throws {
        try withTempDir { dir in
            try dir["f.txt"].write("x\ny\n")
            #expect(Array(dir["f.txt"].lines) == ["x", "y"])
            // error nodes iterate as empty, SwiftyJSON style
            #expect(Array(dir["ghost.txt"].lines).isEmpty)
            // so do directories
            #expect(Array(dir.lines).isEmpty)
        }
    }

    @Test func singlePass() throws {
        try withTempDir { dir in
            let io = try dir["f.txt"].write("a\nb\n").open()
            var it = io.lines.makeIterator()
            #expect(it.next() == "a")
            #expect(Array(io.lines) == ["b"])   // same stream, where it left off
        }
    }

    @Test func closedThrows() throws {
        try withTempDir { dir in
            let io = try dir["f.txt"].write("x\n").open()
            try io.close()
            #expect(throws: Errno.badFileDescriptor) { try io.readLine() }
            #expect(Array(io.lines).isEmpty)    // sugar stays quiet
        }
    }

    @Test func invalidUTF8() throws {
        try withTempDir { dir in
            let bad = Data([0x61, 0xFF, 0xFE, 0x0A, 0x62, 0x0A])   // "a??\nb\n"
            let file = try dir["bin.dat"].write(bad)
            // the primitive raises...
            #expect(throws: Errno.invalidArgument) { try file.open().readLine() }
            // ...the sugar repairs and carries on
            let got = Array(try file.open().lines)
            #expect(got.count == 2)
            #expect(got[1] == "b")
        }
    }
}

@Suite struct Pipelines {
    @Test func fsThroughCommand() throws {
        try withTempDir { dir in
            let file = try dir["words.txt"].write("banana\napple\ncherry\napple\n")
            #expect(try (file | "sort -u").readString() == "apple\nbanana\ncherry\n")
        }
    }

    @Test func pipesChain() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("b\na\nc\n")
            let io = try file | "sort" | "tr a-z A-Z"
            #expect(try io.readString() == "A\nB\nC\n")
            #expect(try io.close() == 0)
        }
    }

    @Test func argvFormNoShell() throws {
        try withTempDir { dir in
            let evil = "$(whoami) | `date` > x\n"
            let file = try dir["f.txt"].write(evil)
            // metacharacters flow through as data, not shell
            #expect(try (file | ["cat"]).readString() == evil)
            #expect(try (file | ["tr", "a-z", "A-Z"] | ["cat"]).readString()
                    == "$(WHOAMI) | `DATE` > X\n")
        }
    }

    @Test func ioSourceDonatesItsDescriptor() throws {
        let io = try IO.open("printf 'b\\na\\n' |") | "sort"
        #expect(try io.readString() == "a\nb\n")
        #expect(try io.close() == 0)
    }

    @Test func readAheadIsPumped() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("one\ntwo\nthree\n")
            let io = try file.open()
            #expect(try io.readLine() == "one")     // buffers ahead
            // the pipeline must carry the buffered remainder, not lose it
            #expect(try (io | "cat").readString() == "two\nthree\n")
        }
    }

    @Test func redirectionComposesLikeTheShell() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("b\na\n")
            // | binds tighter than >! — no parentheses, just like sh
            try file | "sort" >! dir.path.appending("sorted.txt").string
            #expect(dir["sorted.txt"].string == "a\nb\n")
        }
    }

    @Test func linesCompose() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("b\na\nc\n")
            #expect(Array(try (file | "sort").lines) == ["a", "b", "c"])
        }
    }

    @Test func exitStatusIsTheTails() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x\n")
            let io = try file | "grep nope"
            #expect(try io.readAll().isEmpty)
            #expect(try io.close() == 1)            // the shell's $?
        }
    }

    @Test func bigDataFlowsWithoutDeadlock() throws {
        try withTempDir { dir in
            // far beyond the 64KB pipe buffer, through two stages
            let blob = Data((0..<300_000).map { UInt8($0 % 251) })
            let file = try dir["big.dat"].write(blob)
            #expect(try (file | ["cat"] | ["cat"]).readAll() == blob)
        }
    }

    @Test func errorNodesThrow() throws {
        try withTempDir { dir in
            #expect(throws: Errno.noSuchFileOrDirectory) {
                try dir["ghost.txt"] | "cat"
            }
        }
    }

    @Test func closedSourceThrows() throws {
        try withTempDir { dir in
            let io = try dir["f.txt"].write("x\n").open()
            try io.close()
            #expect(throws: Errno.badFileDescriptor) { try io | "cat" }
        }
    }

    @Test func emptyArgvThrows() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x\n")
            #expect(throws: Errno.invalidArgument) { try file | [] }
        }
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
