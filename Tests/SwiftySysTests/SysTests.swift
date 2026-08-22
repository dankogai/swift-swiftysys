import Testing
import Foundation
@testable import SwiftySys

@Suite struct SysBasics {
    @Test func argvIsNonEmpty() {
        #expect(!Sys.argv.isEmpty)
        #expect(!Sys.argv[0].isEmpty)
    }

    @Test func executableIsARealFile() {
        // the test runner binary itself
        #expect(Sys.executable.resolved().isFile)
    }

    @Test func platformIsKnown() {
        #expect(["darwin", "linux"].contains(Sys.platform))
    }

    @Test func byteOrderMatchesHost() {
        let expected = Int(1).littleEndian == 1 ? "little" : "big"
        #expect(Sys.byteOrder == expected)
    }

    @Test func processIdentity() {
        #expect(Sys.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(Sys.ppid > 0)
        #expect(Sys.pid != Sys.ppid)
    }

    @Test func userIdentity() {
        #expect(!Sys.user.isEmpty)
        #expect(Sys.uid == Sys.euid)   // tests do not run setuid
    }

    @Test func machineFacts() {
        #expect(!Sys.hostname.isEmpty)
        #expect(!Sys.osVersion.isEmpty)
        #expect(Sys.cpuCount >= 1)
    }

    @Test func unameIsConsistent() {
        let u = Sys.uname
        switch Sys.platform {
        case "darwin": #expect(u.sysname == "Darwin")
        case "linux":  #expect(u.sysname == "Linux")
        default:       break
        }
        #expect(!u.release.isEmpty)
        #expect(!u.machine.isEmpty)
    }
}

@Suite struct SysEnv {
    @Test func roundtrip() {
        let name = "SWIFTYSYS_TEST_\(UUID().uuidString.prefix(8))"
        #expect(Sys.env[name] == nil)
        Sys.env[name] = "42"
        #expect(Sys.env[name] == "42")
        // visible to children, as a real env var should be
        #expect((try? qx("printf '%s' \"$\(name)\"")) == "42")
        Sys.env.unset(name)
        #expect(Sys.env[name] == nil)
    }

    @Test func nilAlsoUnsets() {
        let name = "SWIFTYSYS_TEST_\(UUID().uuidString.prefix(8))"
        Sys.env[name] = "temp"
        Sys.env[name] = nil
        #expect(Sys.env[name] == nil)
    }

    @Test func dictionaryAndIteration() {
        #expect(Sys.env["PATH"] != nil)
        #expect(Sys.env.dictionary["PATH"] == Sys.env["PATH"])
        #expect(Sys.env.keys.contains("PATH"))
        #expect(Sys.env.keys == Sys.env.keys.sorted())
        #expect(Sys.env.contains { $0.key == "PATH" })
        #expect(Sys.env.count == Sys.env.dictionary.count)
    }
}
