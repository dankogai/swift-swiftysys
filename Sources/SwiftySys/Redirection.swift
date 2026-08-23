//
//  Redirection.swift
//  SwiftySys
//
//  Shell redirection as operators, with csh/zsh noclobber manners.
//  The right-hand side is always the target file name; the left-hand
//  side — an FS node, an IO stream, or a source file name in String —
//  pours its contents in:
//
//      try "draft.txt" >  "final.txt"    // write; throws if target exists
//      try "draft.txt" >! "final.txt"    // write; clobbers (csh's >!)
//      try node        >> "app.log"      // append; throws unless target exists
//      try stream      >>! "app.log"     // append; creates if absent
//
//  Each `>` form has a mirror-image `<` synonym for those who read
//  the other way — `<`, `!<`, `<<`, `!<<` — identical semantics,
//  with the bang mirroring to the left:
//
//      try "draft.txt" !< "final.txt"    // same as >! — clobbers
//
//  All return the fresh FS node of the target (discardable).
//
import Foundation

/// Anything that can stand on the left of a redirection:
/// `FS` (the node's contents), `IO` (the rest of the stream),
/// `String` (a source file name).
public protocol RedirectionSource {
    func redirectionData() throws -> Data
}

extension FS: RedirectionSource {
    public func redirectionData() throws -> Data { try read() }
}

extension IO: RedirectionSource {
    public func redirectionData() throws -> Data { try readAll() }
}

extension String: RedirectionSource {
    public func redirectionData() throws -> Data { try FS(self).read() }
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

/// Mirror of `>` for a String source. Without this concrete overload,
/// `String.<` (Comparable) is a concrete witness that outranks the
/// generic — `try "src" < "dst"` would silently COMPARE the two
/// strings and redirect nothing. With it, that spelling is a
/// compile-time ambiguity instead: write `try FS("src") < "dst"`,
/// or use the `>` spelling, which resolves fine.
@discardableResult
public func < (source: String, target: String) throws -> FS {
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
