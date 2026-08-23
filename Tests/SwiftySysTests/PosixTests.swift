import Testing
import Foundation
@testable import SwiftySys

private func withTempDir(_ body: (FS) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftySysPosixTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try body(FS(url.path))
}

@Suite struct ChmodChown {
    @Test func chmodOctalAndTyped() throws {
        try withTempDir { dir in
            let file = try dir["f.sh"].write("#!/bin/sh\n")
            try file.chmod(0o755)
            #expect(file.permissions == [.ownerReadWriteExecute,
                                         .groupReadExecute, .otherReadExecute])
            try file.chmod([.ownerReadWrite])
            #expect(file.permissions == [.ownerReadWrite])
        }
    }

    @Test func chmodOnErrorNodeThrows() throws {
        try withTempDir { dir in
            #expect(throws: Errno.noSuchFileOrDirectory) {
                try dir["nope"].chmod(0o644)
            }
        }
    }

    @Test func chownToSelfSucceeds() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            // chowning to our own uid/gid is always permitted
            try file.chown(uid: Sys.uid, gid: Sys.gid)
            try file.chown(gid: Sys.gid)         // uid half untouched
            try file.chown(user: Sys.user)       // by name, Perl-style
            #expect(file.uid == Sys.uid)
        }
    }

    @Test func chownUnknownNameThrows() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            #expect(throws: Errno.invalidArgument) {
                try file.chown(user: "no-such-user-xyzzy")
            }
        }
    }
}

@Suite struct RenameLink {
    @Test func renameMoves() throws {
        try withTempDir { dir in
            let old = try dir["draft.txt"].write("content\n")
            let new = try old.rename(to: dir.pathString + "/final.txt")
            #expect(new.isFile)
            #expect(new.string == "content\n")
            #expect(!dir["draft.txt"].exists)
            #expect(new.name == "final.txt")
        }
    }

    @Test func renameOntoExistingReplaces() throws {
        try withTempDir { dir in
            try dir["victim.txt"].write("old")
            let src = try dir["src.txt"].write("new")
            let moved = try src.rename(to: dir.pathString + "/victim.txt")
            #expect(moved.string == "new")       // rename(2) replaces
        }
    }

    @Test func hardLinksShareTheInode() throws {
        try withTempDir { dir in
            let original = try dir["original.txt"].write("shared\n")
            let mirror = try original.link(to: dir.pathString + "/mirror.txt")
            #expect(mirror.inode == original.inode)
            #expect(original.nlink == 2)
            try original.remove()
            #expect(mirror.string == "shared\n") // survives the unlink
        }
    }
}

@Suite struct TimesAndSize {
    @Test func utimeSetsTimes() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            let past = Date(timeIntervalSince1970: 978_307_200)  // 2001-01-01
            try file.utime(atime: past, mtime: past)
            #expect(file.mtime == past)
            #expect(file.atime == past)
            // one-sided: mtime moves, atime stays
            let later = Date(timeIntervalSince1970: 1_000_000_000)
            try file.utime(mtime: later)
            #expect(file.mtime == later)
            #expect(file.atime == past)
        }
    }

    @Test func touchCreatesAndFreshens() throws {
        try withTempDir { dir in
            let stamp = try dir["stamp"].touch()     // creates
            #expect(stamp.isFile)
            #expect(stamp.size == 0)
            let past = Date(timeIntervalSince1970: 978_307_200)
            try stamp.utime(mtime: past)
            try dir["stamp"].touch()                 // freshens
            let mtime = try #require(dir["stamp"].mtime)
            #expect(abs(mtime.timeIntervalSinceNow) < 60)
        }
    }

    @Test func truncateCutsAndDefaults() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("0123456789")
            try file.truncate(to: 4)
            #expect(file.string == "0123")
            try file.truncate()                      // to zero
            #expect(file.size == 0)
        }
    }
}

@Suite struct Fifo {
    @Test func mkfifoCreates() throws {
        try withTempDir { dir in
            let pipe = try dir["pipe"].mkfifo()
            #expect(pipe.isFifo)
            // no-op on an existing fifo
            #expect(try dir["pipe"].mkfifo().exists)
            // refuses a non-fifo
            try dir["file"].write("x")
            #expect(throws: Errno.fileExists) { try dir["file"].mkfifo() }
        }
    }
}

@Suite(.serialized) struct ProcessGlobals {
    @Test func chdirMovesTheProcess() throws {
        let original = FS.cwd
        defer { try? Sys.chdir(original) }
        try withTempDir { dir in
            try Sys.chdir(dir)
            #expect(FS.cwd.resolved().path == dir.resolved().path)
        }
        try Sys.chdir(original)
        #expect(FS.cwd.path == original.path)
    }

    @Test func chdirToErrorNodeThrows() {
        #expect(throws: Errno.noSuchFileOrDirectory) {
            try Sys.chdir(FS("/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func umaskRoundtrips() {
        let original = Sys.umask([.groupWrite, .otherWrite])  // 0o022
        defer { Sys.umask(original) }
        let now = Sys.umask(original)                          // read + restore
        #expect(now == [.groupWrite, .otherWrite])
    }
}
