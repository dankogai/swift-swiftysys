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

@Suite struct Qx {
    @Test func capturesOutput() throws {
        #expect(try qx("echo hello") == "hello\n")
        #expect(try qx("printf '%s' 'no newline'") == "no newline")
    }

    @Test func shellFeaturesWork() throws {
        // pipes and env, like Perl's backticks
        #expect(try qx("echo FOO | tr A-Z a-z") == "foo\n")
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
