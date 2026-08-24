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
            try file.chmod(0o755)      // octal literal — same overload
            #expect(file.permissions == 0o755)
            #expect(file.permissions == [.userAll, .groupRead, .groupExecute,
                                         .otherRead, .otherExecute])
            try file.chmod([.userRead, .userWrite])
            #expect(file.permissions == 0o600)
            #expect(file.permissions?.description == "0o600")
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

@Suite struct PermissionBits {
    @Test func gettersReadTheMatrix() throws {
        try withTempDir { dir in
            let file = try dir["f.txt"].write("x")
            try file.chmod(0o644)
            #expect(file.readable && file.writable && !file.executable)
            #expect(file.userReadable && file.userWritable && !file.userExecutable)
            #expect(file.groupReadable && !file.groupWritable && !file.groupExecutable)
            #expect(file.otherReadable && !file.otherWritable && !file.otherExecutable)
        }
    }

    @Test func settersChmodOneBit() throws {
        try withTempDir { dir in
            let file = try dir["script.sh"].write("#!/bin/sh\n")
            try file.chmod(0o644)
            file.userExecutable = true             // prefixed = exactly one bit
            #expect(file.mode.map { $0 & 0o7777 } == 0o744)
            file.groupWritable = true
            #expect(file.mode.map { $0 & 0o7777 } == 0o764)
            file.otherReadable = false
            #expect(file.mode.map { $0 & 0o7777 } == 0o760)
            file.userExecutable = false
            #expect(file.mode.map { $0 & 0o7777 } == 0o660)
            file.userExecutable = false            // already off — no-op
            #expect(file.mode.map { $0 & 0o7777 } == 0o660)
        }
    }

    @Test func bareGettersAreUser() throws {
        try withTempDir { dir in
            let file = try dir["f"].write("x")
            try file.chmod(0o044)                  // group/other read, user nothing
            #expect(!file.readable)                // bare getters speak for user
            #expect(file.groupReadable)
        }
    }

    @Test func errorNodesAreFalseAndSilent() throws {
        try withTempDir { dir in
            let ghost = dir["nope.txt"]
            #expect(!ghost.readable)
            ghost.readable = true                  // best-effort: silent no-op
            #expect(!dir["nope.txt"].exists)
        }
    }

    @Test func symlinksFollowTheTarget() throws {
        try withTempDir { dir in
            let target = try dir["target.txt"].write("x")
            try target.chmod(0o644)
            let link = try dir["link"].symlink(to: "target.txt")
            #expect(link.writable)                 // the target's bit, not the link's
            link.executable = true                 // chmods the target
            #expect(target.userExecutable)
            try target.chmod(0o444)
            #expect(!link.writable)
        }
    }
}

@Suite struct PermissionOperators {
    @Test func plusMinusOnFiles() throws {
        try withTempDir { dir in
            let file = try dir["f.sh"].write("#!/bin/sh\n")
            try file.chmod(0o644)
            file.permissions += .x                 // .r/.w/.x default to user
            #expect(file.permissions == 0o744)
            file.permissions -= .w
            #expect(file.permissions == 0o544)
            file.permissions += .groupWrite
            #expect(file.permissions == 0o564)
            file.permissions -= [.groupRead, .groupWrite]
            #expect(file.permissions == 0o504)
        }
    }

    @Test func tupleForms() throws {
        try withTempDir { dir in
            let file = try dir["f"].write("x")
            try file.chmod(0o600)
            file.permissions += (user: .x, group: .rx, other: .rx)
            #expect(file.permissions == 0o755)
            file.permissions -= (user: [], group: .x, other: .x)
            #expect(file.permissions == 0o744)
            // assignment builds from the triads via the initializer
            file.permissions = FS.Permissions(user: .rw, group: .r, other: .r)
            #expect(file.permissions == 0o644)
        }
    }

    @Test func triadAccessors() {
        var p: FS.Permissions = 0o754
        #expect(p.user == .rwx)
        #expect(p.group == .rx)
        #expect(p.other == .r)
        p.group = .rw
        #expect(p == 0o764)
        p += .x
        #expect(p == 0o764)                            // u+x was already set
        p -= .r
        #expect(p == 0o364)
    }

    @Test func pureValueAlgebra() {
        var p: FS.Permissions = 0o600
        p += .x
        #expect(p == 0o700)
        p -= .w
        #expect(p == 0o500)
        p += (user: [], group: .rwx, other: [])
        #expect(p == 0o570)
        #expect(FS.Permissions(user: .rwx, group: .rx, other: .rx) == 0o755)
    }

    @Test func errorNodesStaySilent() throws {
        try withTempDir { dir in
            let ghost = dir["nope"]
            ghost.permissions += .x                // nil — silent no-op
            ghost.permissions = 0o777              // setter on error node — no-op
            #expect(!dir["nope"].exists)
        }
    }
}

@Suite struct SymbolicChmod {
    // the pure parser, with umask and directory-ness explicit
    private func mode(_ spec: String, on current: CInterop.Mode,
                      dir: Bool = false, umask: CInterop.Mode = 0) throws -> CInterop.Mode {
        try FS.symbolicMode(spec, applyingTo: current, isDirectory: dir, umask: umask)
    }

    @Test func plusAndMinus() throws {
        #expect(try mode("u+x", on: 0o644) == 0o744)
        #expect(try mode("go-w", on: 0o666) == 0o644)
        #expect(try mode("u+x-w", on: 0o644) == 0o544)   // ops chain in a clause
        #expect(try mode("a+w", on: 0o444) == 0o666)
    }

    @Test func equalsSetsExactly() throws {
        #expect(try mode("u=rwx,go=rx", on: 0o000) == 0o755)
        #expect(try mode("u=", on: 0o755) == 0o055)      // empty = clears
        #expect(try mode("a=r", on: 0o777) == 0o444)
        #expect(try mode("u=rwx", on: 0o4644) == 0o744)  // = clears setuid too
    }

    @Test func capitalXIsConditional() throws {
        #expect(try mode("a+X", on: 0o644) == 0o644)          // plain file: no
        #expect(try mode("a+X", on: 0o644, dir: true) == 0o755)  // dir: yes
        #expect(try mode("a+X", on: 0o744) == 0o755)          // already-x: yes
    }

    @Test func permcopy() throws {
        #expect(try mode("g=u", on: 0o750) == 0o770)
        #expect(try mode("go=u", on: 0o700) == 0o777)
    }

    @Test func setuidSetgidSticky() throws {
        #expect(try mode("u+s", on: 0o755) == 0o4755)
        #expect(try mode("g+s", on: 0o755) == 0o2755)
        #expect(try mode("+t", on: 0o777) == 0o1777)
        #expect(try mode("u-s", on: 0o4755) == 0o755)
    }

    @Test func omittedWhoHonorsUmask() throws {
        #expect(try mode("+w", on: 0o444, umask: 0o022) == 0o644)
        #expect(try mode("=rwx", on: 0o400, umask: 0o022) == 0o755)
        // explicit who ignores the umask
        #expect(try mode("a+w", on: 0o444, umask: 0o022) == 0o666)
    }

    @Test func malformedSpecsThrow() {
        for bad in ["z+x", "u~x", "ux", "", "u+q", "u+x,,g+x"] {
            #expect(throws: Errno.invalidArgument, "\(bad)") {
                try FS.symbolicMode(bad, applyingTo: 0o644,
                                    isDirectory: false, umask: 0)
            }
        }
    }

    @Test func appliesToRealFiles() throws {
        try withTempDir { dir in
            let file = try dir["f.sh"].write("#!/bin/sh\n")
            try file.chmod(0o644)
            try file.chmod("u+x")
            #expect(file.mode.map { $0 & 0o7777 } == 0o744)
            try file.chmod("a=rwX")       // has u+x, so X applies
            #expect(file.mode.map { $0 & 0o7777 } == 0o777)
            try file.chmod("u=rw,go=r")
            #expect(file.mode.map { $0 & 0o7777 } == 0o644)
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

    @Test func bareSettersAreUmaskedAll() throws {
        // bare setters are the shell's chmod +x / -x: all classes,
        // honoring the umask — hence this umask-controlled suite
        let saved = Sys.umask(0o022)
        defer { Sys.umask(saved) }
        try withTempDir { dir in
            let file = try dir["f"].write("x")
            try file.chmod(0o600)
            file.executable = true                 // chmod +x under umask 022
            #expect(file.permissions == 0o711)
            file.executable = false                // chmod -x
            #expect(file.permissions == 0o600)
            Sys.umask(0o027)
            file.readable = true                   // +r & ~0o027 → user, group
            #expect(file.permissions == 0o640)
            file.writable = false                  // -w & ~0o027 → user only
            #expect(file.permissions == 0o440)
        }
    }

    @Test func umaskRoundtrips() {
        let original = Sys.umask([.groupWrite, .otherWrite])  // 0o022
        defer { Sys.umask(original) }
        let now = Sys.umask(original)                          // read + restore
        #expect(now == [.groupWrite, .otherWrite])
    }
}
