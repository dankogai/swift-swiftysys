//
//  HTTPS.swift
//  SwiftySys
//
//  The secure web as a first-class type. Unlike every other stream
//  this kit speaks, HTTPS carries encryption and CA verification —
//  so it gets its own pillar instead of hiding behind IO.open:
//
//      try HTTPS("example.com").get().bodyString
//      try HTTPS("api.github.com")["users"]["dankogai"].get()
//      try HTTPS("api.example").header("Authorization", "Bearer \(t)")
//          .post(json)
//
//  The type's promise: it is TLS-only. A scheme-less spec becomes
//  https://, an http:// spec is upgraded, and there is deliberately
//  no "skip verification" switch — URLSession's full certificate
//  chain validation always applies.
//
//  REST verbs return a Response rather than throwing on non-2xx
//  (REST scripts want to branch on status); call validate() when a
//  non-2xx should throw. Transport failures (DNS, TLS, refused)
//  throw as usual.
//
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPS: Sendable {
    private var components: URLComponents
    private var extraHeaders: [(String, String)] = []
    private var timeoutInterval: TimeInterval?

    /// `HTTPS("example.com")`, `HTTPS("example.com:8443/api?x=1")`,
    /// or a full URL. Any scheme is replaced with `https`.
    public init(_ spec: String) {
        var s = spec
        if let range = s.range(of: "://") {
            s = String(s[range.upperBound...])
        }
        if let parsed = URLComponents(string: "https://" + s) {
            components = parsed
        } else {
            components = URLComponents()
            components.scheme = "https"
        }
    }

    /// The URL this value denotes, if well-formed.
    public var url: URL? { components.url }

    // MARK: - Building — paths, query, headers

    /// Appends a path segment (percent-encoded as needed), FS-style:
    /// `HTTPS("api.github.com")["users"]["dankogai"]`.
    public subscript(_ segment: String) -> HTTPS {
        var next = self
        for piece in segment.split(separator: "/") {
            next.components.path += "/" + piece
        }
        return next
    }

    /// Same as the subscript: `HTTPS("api.github.com") / "users"`.
    public static func / (lhs: HTTPS, rhs: String) -> HTTPS {
        lhs[rhs]
    }

    /// Adds one query item, preserving order.
    public func query(_ name: String, _ value: String) -> HTTPS {
        var next = self
        next.components.queryItems =
            (next.components.queryItems ?? []) + [URLQueryItem(name: name, value: value)]
        return next
    }

    /// Adds query items (sorted by name, for deterministic URLs).
    public func query(_ items: [String: String]) -> HTTPS {
        var next = self
        for key in items.keys.sorted() {
            next = next.query(key, items[key]!)
        }
        return next
    }

    /// Adds a request header carried by every verb on this value.
    public func header(_ name: String, _ value: String) -> HTTPS {
        var next = self
        next.extraHeaders.append((name, value))
        return next
    }

    /// Sets the request timeout carried by every verb on this value.
    public func timeout(_ seconds: TimeInterval) -> HTTPS {
        var next = self
        next.timeoutInterval = seconds
        return next
    }

    // MARK: - REST verbs

    public func get(headers: [String: String] = [:]) throws -> Response {
        try request("GET", headers: headers)
    }

    public func head(headers: [String: String] = [:]) throws -> Response {
        try request("HEAD", headers: headers)
    }

    public func delete(headers: [String: String] = [:]) throws -> Response {
        try request("DELETE", headers: headers)
    }

    public func post(_ body: some FSContent,
                     headers: [String: String] = [:]) throws -> Response {
        try request("POST", body: body.fsContentData, headers: headers)
    }

    public func put(_ body: some FSContent,
                    headers: [String: String] = [:]) throws -> Response {
        try request("PUT", body: body.fsContentData, headers: headers)
    }

    public func patch(_ body: some FSContent,
                      headers: [String: String] = [:]) throws -> Response {
        try request("PATCH", body: body.fsContentData, headers: headers)
    }

    /// The general form every verb goes through.
    public func request(_ method: String, body: Data? = nil,
                        headers: [String: String] = [:]) throws -> Response {
        let urlRequest = try makeRequest(method, body: body, headers: headers)
        let (data, http) = try IO.fetchSync(urlRequest)
        var responseHeaders: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            responseHeaders["\(key)"] = "\(value)"
        }
        return Response(status: http?.statusCode ?? 0,
                        headers: responseHeaders, body: data)
    }

    /// Builds the URLRequest — split out so it is testable offline.
    internal func makeRequest(_ method: String, body: Data? = nil,
                              headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = components.url, url.host() != nil else {
            throw Errno.invalidArgument
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// GET the body as an IO stream — the bridge to the other pillars.
    public func open() throws -> IO {
        try IO.buffered(get().validate().body)
    }

    // MARK: - Response

    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
        public var bodyString: String { String(decoding: body, as: UTF8.self) }
        /// `true` for 2xx.
        public var ok: Bool { (200..<300).contains(status) }
        /// Throws `IO.HTTPError` unless `ok`. Chainable:
        /// `try HTTPS("api.example").get().validate().bodyString`
        @discardableResult
        public func validate() throws -> Response {
            guard ok else { throw IO.HTTPError(status: status, body: body) }
            return self
        }
    }
}

extension HTTPS: CustomStringConvertible {
    public var description: String {
        "HTTPS(\(url?.absoluteString ?? "invalid"))"
    }
}
