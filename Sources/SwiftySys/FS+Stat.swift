//
//  FS+Stat.swift
//  SwiftySys
//
//  stat(2)-derived attributes. All are computed from a fresh lstat(2)
//  at each access, so they track the disk even if the enum case is
//  stale. They do not follow symlinks; use resolved() first if you
//  want the target's attributes.
//
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension FS {
    /// Size in bytes, or `nil` for `.error` nodes.
    public var size: Int64? { stat.map { Int64($0.st_size) } }

    /// Size in bytes; `0` on error.
    public var sizeValue: Int64 { size ?? 0 }

    /// The full `st_mode` including the file-type bits.
    public var mode: CInterop.Mode? { stat?.st_mode }

    /// The permission bits only (rwxrwxrwx + sticky/setuid/setgid).
    public var permissions: FilePermissions? {
        stat.map { FilePermissions(rawValue: $0.st_mode & ~S_IFMT) }
    }

    /// Last modification time.
    public var mtime: Date? { stat.map { Date(timespec: $0.mtimespec) } }

    /// Last access time.
    public var atime: Date? { stat.map { Date(timespec: $0.atimespec) } }

    /// Last status (inode) change time.
    public var ctime: Date? { stat.map { Date(timespec: $0.ctimespec) } }

    /// Owner user id.
    public var uid: CInterop.UserID? { stat?.st_uid }

    /// Owner group id.
    public var gid: CInterop.GroupID? { stat?.st_gid }

    /// Number of hard links.
    public var nlink: Int? { stat.map { Int($0.st_nlink) } }

    /// Inode number.
    public var inode: UInt64? { stat.map { UInt64($0.st_ino) } }

    /// Device id of the filesystem containing this node.
    public var device: Int? { stat.map { Int($0.st_dev) } }
}

extension FS.CStat {
    fileprivate var mtimespec: timespec {
        #if canImport(Darwin)
        st_mtimespec
        #else
        st_mtim
        #endif
    }
    fileprivate var atimespec: timespec {
        #if canImport(Darwin)
        st_atimespec
        #else
        st_atim
        #endif
    }
    fileprivate var ctimespec: timespec {
        #if canImport(Darwin)
        st_ctimespec
        #else
        st_ctim
        #endif
    }
}

extension Date {
    fileprivate init(timespec ts: timespec) {
        self.init(timeIntervalSince1970:
            Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
    }
}
