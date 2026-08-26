//
//  IO+Lines.swift
//  SwiftySys
//
//  Buffered line iteration — Perl's diamond operator, spelled for-in:
//
//      for line in try IO.open("access.log |").lines { ... }
//      while let line = try io.readLine() { ... }
//      for line in FS("/etc/hosts").lines { ... }
//
//  The usual pair: `readLine()` is the throwing primitive (strict
//  UTF-8, errors raised); `lines` is the forgiving sugar — it never
//  throws (iteration just ends) and decodes lossily, so a stray
//  binary byte yields U+FFFD instead of stopping the loop.
//
import Foundation

extension IO {
    /// Reads one line; `nil` at EOF. The trailing newline (`\n` or
    /// `\r\n`) is stripped by default, like Swift's global `readLine`;
    /// pass `strippingNewline: false` for Perl's, and chomp yourself.
    ///
    /// Buffered — reads ahead in 64KB chunks. Mixing with `read(_:)` /
    /// `readAll()` is safe; they drain the read-ahead first.
    public func readLine(strippingNewline: Bool = true) throws -> String? {
        guard let raw = try readLineData() else { return nil }
        let data = strippingNewline ? IO.chomp(raw) : raw
        guard let s = String(data: data, encoding: .utf8) else {
            throw Errno.invalidArgument
        }
        return s
    }

    /// One raw line including its newline (the last may lack one);
    /// `nil` at EOF.
    internal func readLineData() throws -> Data? {
        if isClosed { throw Errno.badFileDescriptor }
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let after = readBuffer.index(after: nl)
                let line = Data(readBuffer[readBuffer.startIndex..<after])
                readBuffer = readBuffer[after...]
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let n = try chunk.withUnsafeMutableBytes { try fd.read(into: $0) }
            if n == 0 {
                guard !readBuffer.isEmpty else { return nil }
                let line = Data(readBuffer)
                readBuffer = Data()
                return line
            }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Strips one trailing `\n` or `\r\n`.
    private static func chomp(_ data: Data) -> Data {
        var d = data[...]
        if d.last == 0x0A { d = d.dropLast() }
        if d.last == 0x0D { d = d.dropLast() }
        return Data(d)
    }

    /// The remaining lines, lazily, newlines stripped:
    ///
    /// ```swift
    /// for line in try IO.open("git log --oneline |").lines { ... }
    /// ```
    ///
    /// Consumes the stream as it goes — single-pass, like the
    /// descriptor underneath. Never throws: a read error ends the
    /// iteration quietly; use `readLine()` to see it raised.
    public var lines: Lines { Lines(io: self) }

    /// A single-pass line sequence over an `IO` (or over nothing —
    /// `FS.lines` on an unreadable node iterates as empty).
    public struct Lines: Sequence, IteratorProtocol {
        internal let io: IO?
        public func next() -> String? {
            guard let io, let raw = try? io.readLineData() else { return nil }
            return String(decoding: IO.chomp(raw), as: UTF8.self)
        }
    }
}

extension FS {
    /// The file's lines, newlines stripped — the streaming sibling of
    /// `string`, and best-effort like it: nodes that cannot be opened
    /// and read (`.error`, directories) iterate as empty.
    ///
    /// ```swift
    /// for line in FS("/etc/hosts").lines where !line.hasPrefix("#") { ... }
    /// ```
    public var lines: IO.Lines {
        IO.Lines(io: try? open())
    }
}
