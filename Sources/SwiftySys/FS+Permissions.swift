//
//  FS+Permissions.swift
//  SwiftySys
//
//  Permission bits in the ugo vocabulary — u for user, g for group,
//  o for OTHER, never "owner". Consistent with chmod(1), the symbolic
//  modes, and the readable/groupWritable Bool properties.
//
//  Also ExpressibleByIntegerLiteral, so the octal classics read as
//  they always have:
//
//      try FS("f").chmod(0o755)
//      try FS("f").chmod([.userAll, .groupRead, .otherRead])
//      FS("f").permissions == 0o644
//      Sys.umask(0o022)
//
import Foundation

extension FS {
    public struct Permissions: OptionSet, Sendable,
                               ExpressibleByIntegerLiteral,
                               CustomStringConvertible {
        public let rawValue: CInterop.Mode

        public init(rawValue: CInterop.Mode) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: CInterop.Mode) {
            self.init(rawValue: value)
        }

        public static let userRead     = Permissions(rawValue: 0o400)
        public static let userWrite    = Permissions(rawValue: 0o200)
        public static let userExecute  = Permissions(rawValue: 0o100)
        public static let groupRead    = Permissions(rawValue: 0o040)
        public static let groupWrite   = Permissions(rawValue: 0o020)
        public static let groupExecute = Permissions(rawValue: 0o010)
        public static let otherRead    = Permissions(rawValue: 0o004)
        public static let otherWrite   = Permissions(rawValue: 0o002)
        public static let otherExecute = Permissions(rawValue: 0o001)

        public static let setuid = Permissions(rawValue: 0o4000)
        public static let setgid = Permissions(rawValue: 0o2000)
        public static let sticky = Permissions(rawValue: 0o1000)

        public static let userAll: Permissions  = [.userRead, .userWrite, .userExecute]
        public static let groupAll: Permissions = [.groupRead, .groupWrite, .groupExecute]
        public static let otherAll: Permissions = [.otherRead, .otherWrite, .otherExecute]
        public static let all: Permissions      = [.userAll, .groupAll, .otherAll]

        public var description: String {
            "0o" + String(rawValue, radix: 8)
        }

        // MARK: - The ugo triad view

        /// One class's worth of bits — the element type of the
        /// `(user:group:other)` forms. `.r`, `.w`, `.x` and the
        /// combos `.rw`, `.rx`, `.wx`, `.rwx`.
        public struct RWX: OptionSet, Sendable {
            public let rawValue: CInterop.Mode
            public init(rawValue: CInterop.Mode) {
                self.rawValue = rawValue & 0o7
            }
            public static let r = RWX(rawValue: 0o4)
            public static let w = RWX(rawValue: 0o2)
            public static let x = RWX(rawValue: 0o1)
            public static let rw: RWX  = [.r, .w]
            public static let rx: RWX  = [.r, .x]
            public static let wx: RWX  = [.w, .x]
            public static let rwx: RWX = [.r, .w, .x]
        }

        /// Builds from per-class triads:
        /// `FS.Permissions(user: .rwx, group: .rx, other: .rx)` — 0o755.
        public init(user: RWX = [], group: RWX = [], other: RWX = []) {
            self.init(rawValue: user.rawValue << 6
                              | group.rawValue << 3
                              | other.rawValue)
        }

        public var user: RWX {
            get { RWX(rawValue: (rawValue >> 6) & 0o7) }
            set { self = Self(rawValue: (rawValue & ~0o700) | (newValue.rawValue << 6)) }
        }
        public var group: RWX {
            get { RWX(rawValue: (rawValue >> 3) & 0o7) }
            set { self = Self(rawValue: (rawValue & ~0o070) | (newValue.rawValue << 3)) }
        }
        public var other: RWX {
            get { RWX(rawValue: rawValue & 0o7) }
            set { self = Self(rawValue: (rawValue & ~0o007) | newValue.rawValue) }
        }

        /// `.r`/`.w`/`.x` on Permissions itself mean the *user* bits —
        /// same default as the bare `readable`/`writable`/`executable`.
        public static let r = Permissions(rawValue: 0o400)
        public static let w = Permissions(rawValue: 0o200)
        public static let x = Permissions(rawValue: 0o100)
    }
}

// MARK: - += / -= — on values, optionals, and (user:group:other) tuples

public func += (lhs: inout FS.Permissions, rhs: FS.Permissions) {
    lhs.formUnion(rhs)
}

public func -= (lhs: inout FS.Permissions, rhs: FS.Permissions) {
    lhs.subtract(rhs)
}

/// The optional forms let `FS("f").permissions += .x` write back
/// through the settable accessor; on error nodes (`nil`) they are
/// silent no-ops, like all the assignment sugar.
public func += (lhs: inout FS.Permissions?, rhs: FS.Permissions) {
    lhs = lhs.map { $0.union(rhs) }
}

public func -= (lhs: inout FS.Permissions?, rhs: FS.Permissions) {
    lhs = lhs.map { $0.subtracting(rhs) }
}

public func += (lhs: inout FS.Permissions,
                rhs: (user: FS.Permissions.RWX, group: FS.Permissions.RWX, other: FS.Permissions.RWX)) {
    lhs += FS.Permissions(user: rhs.user, group: rhs.group, other: rhs.other)
}

public func -= (lhs: inout FS.Permissions,
                rhs: (user: FS.Permissions.RWX, group: FS.Permissions.RWX, other: FS.Permissions.RWX)) {
    lhs -= FS.Permissions(user: rhs.user, group: rhs.group, other: rhs.other)
}

public func += (lhs: inout FS.Permissions?,
                rhs: (user: FS.Permissions.RWX, group: FS.Permissions.RWX, other: FS.Permissions.RWX)) {
    lhs += FS.Permissions(user: rhs.user, group: rhs.group, other: rhs.other)
}

public func -= (lhs: inout FS.Permissions?,
                rhs: (user: FS.Permissions.RWX, group: FS.Permissions.RWX, other: FS.Permissions.RWX)) {
    lhs -= FS.Permissions(user: rhs.user, group: rhs.group, other: rhs.other)
}
