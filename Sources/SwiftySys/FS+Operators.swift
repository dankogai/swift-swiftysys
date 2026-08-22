//
//  FS+Operators.swift
//  SwiftySys
//
//  Assignment sugar — the Perl-tie dream, decided deliberately:
//
//      FS("/tmp")["hello.txt"] = "hello, world\n"   // write
//      FS("/tmp")["hello.txt"] += "goodbye\n"        // append
//      FS("/tmp")["copy.txt"]  = FS("/etc/hosts")    // copy
//      FS("/tmp")["hello.txt"] = nil as String?      // remove
//
//  Swift cannot overload plain `=`, but a subscript with a
//  `nonmutating set` gets the exact same syntax — and works on
//  immutable values and rvalues alike, since the disk, not the
//  enum, is what mutates.
//
//  All of it is best-effort, SwiftyJSON style: setters cannot throw,
//  so failures are silent — inspect the node's `error` afterward, or
//  use the throwing `write(_:)` / `append(_:)` when you care.
//
import Foundation

/// Content that the assignment sugar can write to and read from a
/// filesystem node. `String` (UTF-8) and `Data` conform.
public protocol FSContent {
    var fsContentData: Data { get }
    init?(fsContentData: Data)
}

extension Data: FSContent {
    public var fsContentData: Data { self }
    public init?(fsContentData: Data) { self = fsContentData }
}

extension String: FSContent {
    public var fsContentData: Data { Data(utf8) }
    public init?(fsContentData: Data) {
        self.init(data: fsContentData, encoding: .utf8)
    }
}

extension FS {
    /// A child's *contents* as plain assignment:
    ///
    /// ```swift
    /// FS("/tmp")["f.txt"] = "hello"        // write (create/truncate)
    /// FS("/tmp")["f.txt"] = someData       // works for Data too
    /// let s: String? = FS("/tmp")["f.txt"] // and reads back
    /// FS("/tmp")["f.txt"] = nil as String? // remove
    /// ```
    ///
    /// The plain getter `dir["f.txt"]` still returns an `FS` node —
    /// this typed one only kicks in where the context asks for
    /// `String?` or `Data?`.
    public subscript<Content: FSContent>(_ name: String) -> Content? {
        get {
            self[name].data.flatMap(Content.init(fsContentData:))
        }
        nonmutating set {
            let target: FS = self[name]
            if let newValue {
                try? target.write(newValue.fsContentData)
            } else {
                try? target.remove()
            }
        }
    }

    /// Appends, creating the file if absent:
    ///
    /// ```swift
    /// FS.temp["app.log"] += "started\n"
    /// ```
    ///
    /// Best-effort like the assignment sugar; `lhs` is refreshed
    /// afterward, so its `error` tells you if anything went wrong.
    public static func += (lhs: inout FS, rhs: some FSContent) {
        lhs = (try? lhs.append(rhs.fsContentData)) ?? lhs.refreshed()
    }
}
