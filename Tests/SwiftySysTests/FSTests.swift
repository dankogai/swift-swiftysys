import Testing
import Foundation
@testable import SwiftySys

/// Runs `body` with a fresh temporary directory, cleaning up afterward.
private func withTempDir(_ body: (FS) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftySysTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let dir = FS(url.path)
    #expect(dir.isDirectory)
    try body(dir)
}

@Suite struct Construction {
    @Test func classifiesNodes() throws {
        try withTempDir { dir in
            #expect(dir.isDirectory)
            let file = try dir["a.txt"].write("hello")
            #expect(file.isFile)
            let link = try dir["l"].symlink(to: FilePath("a.txt"))
            #expect(link.isSymlink)
        }
    }

    @Test func nonexistentIsError() {
        let node = FS("/nonexistent-\(UUID().uuidString)")
        #expect(node.error == .noSuchFileOrDirectory)
        #expect(!node.exists)
        #expect(node.data == nil)
        #expect(node.size == nil)
    }

    @Test func wellKnownLocations() {
        #expect(FS.cwd.isDirectory)
        #expect(FS.home.isDirectory)
        #expect(FS.temp.isDirectory)
    }
}

@Suite struct Operators {
    @Test func assignmentWrites() throws {
        try withTempDir { dir in
            dir["hello.txt"] = "hello, world\n"
            #expect(dir["hello.txt"].string == "hello, world\n")
            // truncates on reassignment
            dir["hello.txt"] = "goodbye\n"
            #expect(dir["hello.txt"].string == "goodbye\n")
        }
    }

    @Test func assignmentWritesData() throws {
        try withTempDir { dir in
            let blob = Data([0x00, 0xFF, 0x7F])
            dir["blob.bin"] = blob
            #expect(dir["blob.bin"].data == blob)
        }
    }

    @Test func plusEqualsAppends() throws {
        try withTempDir { dir in
            dir["log.txt"] += "one\n"     // creates
            dir["log.txt"] += "two\n"     // appends
            #expect(dir["log.txt"].string == "one\ntwo\n")
        }
    }

    @Test func plusEqualsOnVar() throws {
        try withTempDir { dir in
            var log = dir["direct.log"]
            log += "line\n"
            #expect(log.isFile)           // refreshed after the append
            #expect(log.string == "line\n")
        }
    }

    @Test func assignmentCopiesNodes() throws {
        try withTempDir { dir in
            try dir["src.txt"].write("source content\n")
            dir["dst.txt"] = dir["src.txt"]
            #expect(dir["dst.txt"].string == "source content\n")
        }
    }

    @Test func nilAssignmentIsNoOp() throws {
        try withTempDir { dir in
            dir["kept.txt"] = "still here"
            // deleting deserves an explicit remove(), not `= nil`
            dir["kept.txt"] = nil as String?
            #expect(dir["kept.txt"].string == "still here")
            try dir["kept.txt"].remove()
            #expect(!dir["kept.txt"].exists)
        }
    }

    @Test func typedGetterReads() throws {
        try withTempDir { dir in
            dir["f.txt"] = "typed\n"
            let s: String? = dir["f.txt"]
            #expect(s == "typed\n")
            let d: Data? = dir["f.txt"]
            #expect(d == Data("typed\n".utf8))
            let missing: String? = dir["nope.txt"]
            #expect(missing == nil)
        }
    }

    @Test func worksOnRvalues() throws {
        try withTempDir { dir in
            // no var needed anywhere — the disk mutates, not the enum
            FS(dir.pathString)["rvalue.txt"] = "works\n"
            FS(dir.pathString)["rvalue.txt"] += "twice\n"
            #expect(dir["rvalue.txt"].string == "works\ntwice\n")
        }
    }

    @Test func failuresAreSilentButVisible() throws {
        try withTempDir { dir in
            let file = try dir["plain.txt"].write("x")
            file["child.txt"] = "nope"          // ENOTDIR — silently no-op
            #expect(file["child.txt"].error == .notDirectory)
            #expect(dir.keys == ["plain.txt"])  // nothing was created
            // copying from an unreadable source is a no-op too
            dir["copy.txt"] = FS("/nonexistent-\(UUID().uuidString)")
            #expect(!dir["copy.txt"].exists)
        }
    }
}

@Suite struct Chaining {
    @Test func chainsWithoutUnwrapping() throws {
        try withTempDir { dir in
            try dir["a"].mkdir()
            try dir["a"]["b.txt"].write("deep")
            #expect(dir["a"]["b.txt"].string == "deep")
        }
    }

    @Test func enoentExtendsPath() throws {
        try withTempDir { dir in
            let node = dir["no"]["such"]["path"]
            #expect(node.error == .noSuchFileOrDirectory)
            // the error carries the full intended path,
            // so mkdir(withIntermediates:) knows where to create
            #expect(node.path == dir.path.appending("no").appending("such").appending("path"))
        }
    }

    @Test func notDirectoryReportsOrigin() throws {
        try withTempDir { dir in
            let file = try dir["plain.txt"].write("x")
            let node = file["a"]["b"]["c"]
            #expect(node.error == .notDirectory)
            // ...but ENOTDIR freezes at the origin of the failure
            #expect(node.path == file.path)
        }
    }

    @Test func slashOperator() throws {
        try withTempDir { dir in
            try (dir / "x.txt").write("via slash")
            #expect((dir / "x.txt").string == "via slash")
        }
    }
}

@Suite struct ReadWrite {
    @Test func roundtrip() throws {
        try withTempDir { dir in
            let content = "hello, world\n"
            let file = try dir["hello.txt"].write(content)
            #expect(file.string == content)
            #expect(file.stringValue == content)
            #expect(file.data == Data(content.utf8))
            #expect(try file.readString() == content)
        }
    }

    @Test func binaryRoundtrip() throws {
        try withTempDir { dir in
            let blob = Data((0..<100_000).map { UInt8($0 % 251) })
            let file = try dir["blob.bin"].write(blob)
            #expect(file.data == blob)
            #expect(file.size == Int64(blob.count))
        }
    }

    @Test func append() throws {
        try withTempDir { dir in
            try dir["log.txt"].write("one\n")
            try dir["log.txt"].append("two\n")
            #expect(dir["log.txt"].string == "one\ntwo\n")
        }
    }

    @Test func valueAccessorsOnError() {
        let node = FS("/nonexistent-\(UUID().uuidString)")
        #expect(node.dataValue == Data())
        #expect(node.stringValue == "")
        #expect(throws: Errno.noSuchFileOrDirectory) { try node.read() }
    }

    @Test func writeRefusesFrozenErrors() throws {
        try withTempDir { dir in
            let file = try dir["plain.txt"].write("x")
            // ENOTDIR error node must not silently write elsewhere
            #expect(throws: Errno.notDirectory) {
                try file["child.txt"].write("nope")
            }
        }
    }
}

@Suite struct Stat {
    @Test func sizeAndTimes() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("12345")
            #expect(file.size == 5)
            #expect(file.sizeValue == 5)
            let mtime = try #require(file.mtime)
            #expect(abs(mtime.timeIntervalSinceNow) < 60)
            #expect(file.uid != nil)
            #expect(file.nlink == 1)
            #expect(file.inode != nil)
        }
    }

    @Test func permissions() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            let perms = try #require(file.permissions)
            #expect(perms.contains([.userRead, .userWrite]))
            #expect(!perms.contains(.userExecute))
        }
    }

    @Test func statTracksDisk() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("12345")
            try dir["f.txt"].write("123456789")
            // stale enum value, but stat accessors re-lstat
            #expect(file.size == 9)
        }
    }
}

@Suite struct DirectoryIteration {
    @Test func iteratesSorted() throws {
        try withTempDir { dir in
            try dir["b.txt"].write("b")
            try dir["a.txt"].write("a")
            try dir["c"].mkdir()
            #expect(dir.keys == ["a.txt", "b.txt", "c"])
            #expect(dir.count == 3)
            let pairs = Array(dir)
            #expect(pairs.map(\.name) == ["a.txt", "b.txt", "c"])
            #expect(pairs[0].node.isFile)
            #expect(pairs[2].node.isDirectory)
        }
    }

    @Test func filterMapWork() throws {
        try withTempDir { dir in
            try dir["small.txt"].write("x")
            try dir["big.txt"].write(String(repeating: "x", count: 1000))
            let big = dir.filter { $0.node.sizeValue > 100 }.map(\.name)
            #expect(big == ["big.txt"])
        }
    }

    @Test func nonDirectoriesYieldNothing() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            #expect(Array(file).isEmpty)
            #expect(file.keys.isEmpty)
            #expect(Array(FS("/nonexistent-\(UUID().uuidString)")).isEmpty)
        }
    }
}

@Suite struct MkdirRemove {
    @Test func mkdirAndRemove() throws {
        try withTempDir { dir in
            let sub = try dir["sub"].mkdir()
            #expect(sub.isDirectory)
            // idempotent on an existing directory
            #expect(try dir["sub"].mkdir().isDirectory)
            let gone = try sub.remove()
            #expect(gone.error == .noSuchFileOrDirectory)
        }
    }

    @Test func mkdirWithIntermediates() throws {
        try withTempDir { dir in
            let deep = try dir["a"]["b"]["c"].mkdir(withIntermediates: true)
            #expect(deep.isDirectory)
            #expect(dir["a"]["b"].isDirectory)
        }
    }

    @Test func mkdirOverFileThrows() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            #expect(throws: Errno.fileExists) { try file.mkdir() }
        }
    }

    @Test func removeRecursively() throws {
        try withTempDir { dir in
            try dir["a"]["b"].mkdir(withIntermediates: true)
            try dir["a"]["b"]["f.txt"].write("x")
            try dir["a"]["g.txt"].write("y")
            #expect(throws: (any Error).self) { try dir["a"].remove() }
            let gone = try dir["a"].remove(recursively: true)
            #expect(!gone.exists)
        }
    }
}

@Suite struct Symlinks {
    @Test func createReadResolve() throws {
        try withTempDir { dir in
            let target = try dir["target.txt"].write("pointed at")
            let link = try dir["link"].symlink(to: FilePath("target.txt"))
            #expect(link.isSymlink)
            #expect(link.linkTarget == FilePath("target.txt"))
            // reading follows the link
            #expect(link.string == "pointed at")
            // resolved() canonicalizes
            #expect(link.resolved().path == target.resolved().path)
        }
    }

    @Test func lstatSemantics() throws {
        try withTempDir { dir in
            try dir["target.txt"].write("0123456789")
            let link = try dir["link"].symlink(to: FilePath("target.txt"))
            // size is the link's own, not the target's
            #expect(link.size == Int64("target.txt".utf8.count))
            #expect(link.resolved().size == 10)
        }
    }

    @Test func danglingLink() throws {
        try withTempDir { dir in
            let link = try dir["dangle"].symlink(to: FilePath("nowhere"))
            #expect(link.isSymlink)
            #expect(link.data == nil)
            #expect(link.resolved().error != nil)
        }
    }
}

@Suite struct Navigation {
    @Test func parentAndName() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            #expect(file.name == "f.txt")
            #expect(file.parent.path == dir.path)
            #expect(file.parent.isDirectory)
        }
    }

    @Test func descriptionIsInformative() {
        let node = FS("/nonexistent-xyzzy")
        #expect(node.description.contains("error"))
        #expect(node.description.contains("/nonexistent-xyzzy"))
    }
}
