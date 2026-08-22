//
//  IO+URL.swift
//  SwiftySys
//
//  Ruby's open-uri, for IO: open a URL like a file.
//
//      let page = try IO.open("https://example.com")   // GET
//      try page.readString()
//
//      let post = try IO.open("| https://api.example") // POST on close
//      try post.write("payload")
//      try post.close()          // uploads; returns the HTTP status
//
//  Reading fetches the whole body at open() and serves it through a
//  real (unlinked temp-file) descriptor, so read()/readString()/read(_:)
//  behave exactly like any other IO. Writing buffers into a descriptor
//  and uploads at close(), whose return value — like a pipe's exit
//  status — is the HTTP status code. Non-2xx responses throw
//  IO.HTTPError. Synchronous by design: this is a scripting kit.
//
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension IO {
    /// A non-2xx HTTP response.
    public struct HTTPError: Error, Sendable {
        public let status: Int
        public let body: Data
        public var bodyString: String { String(decoding: body, as: UTF8.self) }
    }

    /// Opens a URL as a stream.
    ///
    /// - `.read` performs the request now (`GET` unless `method` says
    ///   otherwise) and returns a stream over the response body;
    ///   `terminationStatus` already holds the HTTP status.
    /// - `.write` returns a stream that buffers what you write and
    ///   uploads it when you `close()` (`POST` unless `method` says
    ///   otherwise); `close()` returns the HTTP status.
    ///
    /// Works for `file://` URLs too (reading only).
    public static func open(_ url: URL, _ mode: Mode = .read,
                            method: String? = nil,
                            timeout: TimeInterval? = nil) throws -> IO {
        switch mode {
        case .read:
            var request = URLRequest(url: url)
            request.httpMethod = method ?? "GET"
            if let timeout { request.timeoutInterval = timeout }
            let (data, http) = try fetchSync(request)
            if let http, !(200..<300).contains(http.statusCode) {
                throw HTTPError(status: http.statusCode, body: data)
            }
            let io = try buffered(data)
            io.terminationStatus = http.map { Int32($0.statusCode) }
            return io
        case .write:
            let io = try buffered(Data())
            let fd = io.fd
            io.finisher = {
                try fd.seek(offset: 0, from: .start)
                var body = Data()
                var buf = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = try buf.withUnsafeMutableBytes { try fd.read(into: $0) }
                    if n == 0 { break }
                    body.append(contentsOf: buf[0..<n])
                }
                var request = URLRequest(url: url)
                request.httpMethod = method ?? "POST"
                request.httpBody = body
                if let timeout { request.timeoutInterval = timeout }
                let (respData, http) = try fetchSync(request)
                if let http, !(200..<300).contains(http.statusCode) {
                    throw HTTPError(status: http.statusCode, body: respData)
                }
                return http.map { Int32($0.statusCode) }
            }
            return io
        case .append, .readWrite:
            throw Errno.invalidArgument
        }
    }

    /// Blocking fetch — a semaphore over URLSession, the classic
    /// sync-over-async bridge. Shared with the HTTPS type.
    internal static func fetchSync(_ request: URLRequest) throws
        -> (data: Data, http: HTTPURLResponse?) {
        final class Box: @unchecked Sendable {
            var data: Data?
            var response: URLResponse?
            var error: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = box.error { throw error }
        return (box.data ?? Data(), box.response as? HTTPURLResponse)
    }

    /// An IO over an anonymous (created-and-unlinked) temp file
    /// pre-loaded with `data` and rewound — a real descriptor, so
    /// every IO primitive just works, at any size.
    internal static func buffered(_ data: Data) throws -> IO {
        var template = Array((FS.temp.pathString + "/swiftysys.XXXXXX").utf8CString)
        let raw = mkstemp(&template)
        guard raw >= 0 else { throw Errno(rawValue: errno) }
        unlink(&template)
        let fd = FileDescriptor(rawValue: raw)
        do {
            try fd.writeAll(data)
            try fd.seek(offset: 0, from: .start)
        } catch {
            try? fd.close()
            throw error
        }
        return IO(fd: fd, ownsFD: true)
    }
}
