import Testing
import Foundation
@testable import SwiftySys

private func withTempDir(_ body: (FS) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftySysRedirTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(FS(url.path))
}

@Suite struct NoclobberWrite {
    @Test func writesToNewTarget() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("payload\n")
            let node = try src > dir.pathString + "/dst.txt"
            #expect(node.isFile)
            #expect(node.string == "payload\n")
        }
    }

    @Test func refusesExistingTarget() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("new")
            try dir["dst.txt"].write("precious")
            #expect(throws: Errno.fileExists) {
                try src > dir.pathString + "/dst.txt"
            }
            #expect(dir["dst.txt"].string == "precious")   // untouched
        }
    }

    @Test func bangClobbers() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("new content")
            try dir["dst.txt"].write("old content")
            try src >! dir.pathString + "/dst.txt"
            #expect(dir["dst.txt"].string == "new content")
        }
    }

    @Test func mirrorsAreSynonyms() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("x")
            let dst1 = dir.pathString + "/one.txt"
            try src < dst1
            #expect(FS(dst1).string == "x")
            #expect(throws: Errno.fileExists) {
                try src < dst1                             // noclobber too
            }
            try dir["dst2"].write("old")
            try src !< dir.pathString + "/dst2"
            #expect(dir["dst2"].string == "x")
        }
    }

    @Test func missingSourceThrows() throws {
        try withTempDir { dir in
            #expect(throws: Errno.noSuchFileOrDirectory) {
                try FS(dir.pathString + "/nope.txt") > dir.pathString + "/dst.txt"
            }
            #expect(!dir["dst.txt"].exists)
        }
    }
}

@Suite struct AppendRedirect {
    @Test func appendsToExisting() throws {
        try withTempDir { dir in
            try dir["log.txt"].write("one\n")
            let more = try dir["more.txt"].write("two\n")
            // note: >> binds tighter than +, so the path goes in a let
            let log = dir.pathString + "/log.txt"
            try more >> log
            #expect(dir["log.txt"].string == "one\ntwo\n")
            try more << log
            #expect(dir["log.txt"].string == "one\ntwo\ntwo\n")
        }
    }

    @Test func plainAppendRequiresTarget() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("x")
            let missing = dir.pathString + "/missing.log"
            #expect(throws: Errno.noSuchFileOrDirectory) { try src >> missing }
            #expect(throws: Errno.noSuchFileOrDirectory) { try src << missing }
        }
    }

    @Test func bangAppendCreates() throws {
        try withTempDir { dir in
            let src = try dir["src.txt"].write("first\n")
            let log = dir.pathString + "/fresh.log"
            try src >>! log
            #expect(FS(log).string == "first\n")
            try src !<< log                                // mirror
            #expect(FS(log).string == "first\nfirst\n")
        }
    }
}

@Suite struct RedirectSources {
    @Test func ioStreamAsSource() throws {
        try withTempDir { dir in
            // a pipe drains straight into a file
            let echo = try IO.readPipe(from: ["echo", "streamed"])
            try echo >! dir.pathString + "/out.txt"
            #expect(dir["out.txt"].string == "streamed\n")
            try echo.close()
        }
    }

    @Test func chainsThroughReturnValue() throws {
        try withTempDir { dir in
            let a = try dir["a.txt"].write("chained\n")
            // the returned FS node is itself a RedirectionSource
            let b = try a > dir.pathString + "/b.txt"
            try b > dir.pathString + "/c.txt"
            #expect(dir["c.txt"].string == "chained\n")
        }
    }

    @Test func stringsStayStrings() {
        // String is deliberately NOT a RedirectionSource:
        // these are plain Swift comparisons, exactly as before
        #expect("b" > "a")
        #expect("a" < "b")
        let comparison = "draft.txt" > "final.txt"   // Bool, not a redirect
        #expect(comparison == false)                 // "d" sorts before "f"
        #expect(["c", "a", "b"].sorted(by: <) == ["a", "b", "c"])
    }
}
