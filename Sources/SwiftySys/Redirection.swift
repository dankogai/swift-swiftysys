//
//  Redirection.swift
//  SwiftySys
//
//  Shell redirection as operators, with csh/zsh noclobber manners.
//  The right-hand side is always the target file name; the left-hand
//  side — an FS node or an IO stream — pours its contents in:
//
//      try FS("draft.txt") >  "final.txt"  // write; throws if target exists
//      try FS("draft.txt") >! "final.txt"  // write; clobbers (csh's >!)
//      try node   >> "app.log"             // append; throws unless target exists
//      try stream >>! "app.log"            // append; creates if absent
//
//  Each `>` form has a mirror-image `<` synonym for those who read
//  the other way — `<`, `!<`, `<<`, `!<<` — identical semantics,
//  with the bang mirroring to the left:
//
//      try FS("draft.txt") !< "final.txt"  // same as >! — clobbers
//
//  All return the fresh FS node of the target (discardable).
//
//  String deliberately does NOT conform to RedirectionSource:
//  `"a" > "b"` is a plain Swift string comparison and must stay one.
//  Wrap the source in FS(...) to say you mean a file.
//
import Foundation

/// Anything that can stand on the left of a redirection:
/// `FS` (the node's contents) or `IO` (the rest of the stream).
/// `String` deliberately does not conform — `"a" > "b"` must remain
/// a plain string comparison.
public protocol RedirectionSource {
    func redirectionData() throws -> Data
}

extension FS: RedirectionSource {
    public func redirectionData() throws -> Data { try read() }
}

extension IO: RedirectionSource {
    public func redirectionData() throws -> Data { try readAll() }
}

// The four semantics, shared by both spelling directions.
private func redirectWrite(_ source: some RedirectionSource,
                           to name: String, clobber: Bool) throws -> FS {
    let target = FS(name)
    if !clobber && target.exists { throw Errno.fileExists }
    return try target.write(source.redirectionData())
}

private func redirectAppend(_ source: some RedirectionSource,
                            to name: String, create: Bool) throws -> FS {
    let target = FS(name)
    if !create && !target.exists { throw Errno.noSuchFileOrDirectory }
    return try target.append(source.redirectionData())
}

// MARK: - The operators

infix operator >! : ComparisonPrecedence
infix operator !< : ComparisonPrecedence
infix operator >>! : BitwiseShiftPrecedence
infix operator !<< : BitwiseShiftPrecedence

/// Write; throws `EEXIST` if the target exists (noclobber).
@discardableResult
public func > (source: some RedirectionSource, target: String) throws -> FS {
    try redirectWrite(source, to: target, clobber: false)
}

/// Mirror of `>`.
@discardableResult
public func < (source: some RedirectionSource, target: String) throws -> FS {
    try redirectWrite(source, to: target, clobber: false)
}

/// Write; clobbers an existing target (csh's `>!`).
@discardableResult
public func >! (source: some RedirectionSource, target: String) throws -> FS {
    try redirectWrite(source, to: target, clobber: true)
}

/// Mirror of `>!`.
@discardableResult
public func !< (source: some RedirectionSource, target: String) throws -> FS {
    try redirectWrite(source, to: target, clobber: true)
}

/// Append; throws `ENOENT` unless the target already exists.
@discardableResult
public func >> (source: some RedirectionSource, target: String) throws -> FS {
    try redirectAppend(source, to: target, create: false)
}

/// Mirror of `>>`.
@discardableResult
public func << (source: some RedirectionSource, target: String) throws -> FS {
    try redirectAppend(source, to: target, create: false)
}

/// Append; creates the target if absent.
@discardableResult
public func >>! (source: some RedirectionSource, target: String) throws -> FS {
    try redirectAppend(source, to: target, create: true)
}

/// Mirror of `>>!`.
@discardableResult
public func !<< (source: some RedirectionSource, target: String) throws -> FS {
    try redirectAppend(source, to: target, create: true)
}
