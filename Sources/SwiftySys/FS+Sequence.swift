//
//  FS+Sequence.swift
//  SwiftySys
//
//  Directories iterate like dictionaries: (name, FS) pairs,
//  sorted by name for determinism. Non-directories (including
//  .error nodes) yield nothing, so iteration never throws.
//
import Foundation

extension FS: Sequence {
    public func makeIterator() -> AnyIterator<(name: String, node: FS)> {
        guard case .directory(let p) = self else {
            return AnyIterator { nil }
        }
        var names = FS.entries(of: p).makeIterator()
        return AnyIterator {
            guard let name = names.next() else { return nil }
            return (name: name, node: FS(p.appending(name)))
        }
    }

    /// Child names, sorted; `[]` for non-directories.
    public var keys: [String] {
        guard case .directory(let p) = self else { return [] }
        return FS.entries(of: p)
    }

    /// Child nodes, sorted by name; `[]` for non-directories.
    public var children: [FS] {
        map { $0.node }
    }

    /// Number of children; `0` for non-directories.
    public var count: Int { keys.count }

    private static func entries(of p: FilePath) -> [String] {
        let all = (try? FileManager.default
            .contentsOfDirectory(atPath: p.string)) ?? []
        return all.sorted()
    }
}
