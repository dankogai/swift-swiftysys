import Testing
import Foundation
@testable import SwiftySys

/// A one-shot local HTTP server (via python3, run through our own
/// readPipe): prints its port, serves `requests` requests, exits.
/// GET / → "hello from http\n"; GET /missing → 404;
/// POST → replies "ok" and echoes the body to its stdout.
private func withHTTPServer(
    requests: Int, _ body: (_ base: String, _ server: IO) throws -> Void
) throws {
    guard (try? IO.which("python3")) != nil else { return }  // skip quietly
    let script = """
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/missing':
                    self.send_response(404); self.end_headers()
                    self.wfile.write(b'gone')
                else:
                    self.send_response(200); self.end_headers()
                    self.wfile.write(b'hello from http\\n')
            def do_POST(self):
                n = int(self.headers.get('Content-Length') or 0)
                data = self.rfile.read(n)
                self.send_response(200); self.end_headers()
                self.wfile.write(b'ok')
                sys.stdout.write('BODY:' + data.decode()); sys.stdout.flush()
            def log_message(self, *args): pass
        srv = HTTPServer(('127.0.0.1', 0), H)
        print(srv.server_port, flush=True)
        for _ in range(int(sys.argv[1])):
            srv.handle_request()
        """
    let server = try IO.readPipe(from: ["python3", "-c", script, String(requests)])
    var portLine = ""
    while !portLine.hasSuffix("\n") {
        let byte = try server.read(1)
        if byte.isEmpty { break }
        portLine += String(decoding: byte, as: UTF8.self)
    }
    let port = portLine.trimmingCharacters(in: .whitespacesAndNewlines)
    try #require(Int(port) != nil, "server did not report a port")
    try body("http://127.0.0.1:\(port)", server)
    try server.close()
}

@Suite(.serialized) struct URLStreams {
    @Test func readsOverHTTP() throws {
        try withHTTPServer(requests: 1) { base, _ in
            let io = try IO.open(URL(string: base + "/")!, timeout: 15)
            let body = try io.readString()
            #expect(body == "hello from http\n")
            #expect(io.terminationStatus == 200)
            try io.close()
        }
    }

    @Test func magicOpenRecognizesURLs() throws {
        try withHTTPServer(requests: 1) { base, _ in
            let body = try IO.open("\(base)/").readString()
            #expect(body == "hello from http\n")
        }
    }

    @Test func writesOverHTTP() throws {
        try withHTTPServer(requests: 1) { base, server in
            let io = try IO.open(URL(string: base + "/submit")!, .write, timeout: 15)
            try io.write("posted ")
            try io.write("data")
            let status = try io.close()             // uploads here
            #expect(status == 200)
            #expect(io.terminationStatus == 200)
            // the server echoed the body to its stdout
            let echoed = try server.readString()
            #expect(echoed.contains("BODY:posted data"))
        }
    }

    @Test func non2xxThrowsHTTPError() throws {
        try withHTTPServer(requests: 1) { base, _ in
            #expect {
                try IO.open(URL(string: base + "/missing")!, timeout: 15)
            } throws: { error in
                (error as? IO.HTTPError)?.status == 404
            }
        }
    }

    @Test func fileURLsBypassTheNetwork() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftysys-url-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        // writing works too — file URLs go straight to the file layer
        let out = try IO.open(url, .write)
        try out.write("via file url\n")
        try out.close()
        let body = try IO.open(url).readString()
        #expect(body == "via file url\n")
    }

    @Test func urlWriteRejectsBadModes() throws {
        #expect(throws: Errno.invalidArgument) {
            try IO.open(URL(string: "https://example.com")!, .append)
        }
    }
}

@Suite(.serialized) struct PlainHTTP {
    @Test func schemeIsLockedToHTTP() {
        #expect(IO.HTTP("intranet.local:8080").url?.absoluteString
                == "http://intranet.local:8080")
        // the type's scheme always wins — choosing plaintext is
        // done by typing IO.HTTP, never by a spec string
        #expect(IO.HTTP("https://example.com").url?.scheme == "http")
        #expect(IO.HTTPS("http://example.com").url?.scheme == "https")
    }

    @Test func buildersWorkAcrossSchemes() {
        let u = IO.HTTP("host")["api"]["v1"].query("q", "x").url
        #expect(u?.absoluteString == "http://host/api/v1?q=x")
        #expect("\(IO.HTTP("host"))" == "IO.HTTP(http://host)")
        #expect("\(IO.HTTPS("host"))" == "IO.HTTPS(https://host)")
    }

    @Test func restVerbsOverRealHTTP() throws {
        // unlike HTTPS, plaintext HTTP is end-to-end testable locally
        try withHTTPServer(requests: 2) { base, server in
            let host = String(base.dropFirst("http://".count))
            let ok = try IO.HTTP(host).timeout(15).get()
            #expect(ok.status == 200)
            #expect(ok.bodyString == "hello from http\n")
            let posted = try IO.HTTP(host)["submit"]
                .timeout(15).post("intranet payload")
            #expect(posted.ok)
            let echoed = try server.readString()
            #expect(echoed.contains("BODY:intranet payload"))
        }
    }

    @Test func validateWorksOverHTTP() throws {
        try withHTTPServer(requests: 1) { base, _ in
            let host = String(base.dropFirst("http://".count))
            let response = try IO.HTTP(host)["missing"].timeout(15).get()
            #expect(response.status == 404)
            #expect {
                try response.validate()
            } throws: { error in
                (error as? IO.HTTPError)?.status == 404
            }
        }
    }
}
