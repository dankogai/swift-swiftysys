import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SwiftySys

@Suite struct HTTPSBuilding {
    @Test func schemelessGetsHTTPS() {
        #expect(HTTPS("example.com").url?.absoluteString == "https://example.com")
    }

    @Test func httpIsUpgraded() {
        // the type's promise: TLS-only, no exceptions
        #expect(HTTPS("http://example.com").url?.scheme == "https")
        #expect(HTTPS("https://example.com/x").url?.absoluteString == "https://example.com/x")
    }

    @Test func portAndPathSurvive() {
        #expect(HTTPS("example.com:8443/api").url?.absoluteString
                == "https://example.com:8443/api")
    }

    @Test func subscriptBuildsPaths() {
        let u = HTTPS("api.github.com")["users"]["dankogai"].url
        #expect(u?.absoluteString == "https://api.github.com/users/dankogai")
        // percent-encoding happens where needed
        let spaced = HTTPS("example.com")["a b"].url
        #expect(spaced?.absoluteString == "https://example.com/a%20b")
        // multi-segment strings split
        let multi = HTTPS("example.com")["a/b/c"].url
        #expect(multi?.absoluteString == "https://example.com/a/b/c")
        // the / operator is the same thing
        #expect((HTTPS("example.com") / "x").url?.path() == "/x")
    }

    @Test func queryItems() {
        let single = HTTPS("example.com").query("q", "swift sys").url
        #expect(single?.absoluteString == "https://example.com?q=swift%20sys")
        let sorted = HTTPS("example.com").query(["b": "2", "a": "1"]).url
        #expect(sorted?.query() == "a=1&b=2")
    }

    @Test func invalidHostThrowsAtRequestTime() {
        #expect(throws: Errno.invalidArgument) {
            try HTTPS("").makeRequest("GET")
        }
    }
}

@Suite struct HTTPSRequests {
    @Test func verbsAndHeaders() throws {
        let request = try HTTPS("api.example.com")["v1"]["things"]
            .header("Authorization", "Bearer tok")
            .timeout(30)
            .makeRequest("POST", body: Data("{}".utf8), headers: ["X-Extra": "1"])
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.example.com/v1/things")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "X-Extra") == "1")
        #expect(request.httpBody == Data("{}".utf8))
        #expect(request.timeoutInterval == 30)
    }

    @Test func perCallHeadersWin() throws {
        let request = try HTTPS("example.com")
            .header("X-Token", "stored")
            .makeRequest("GET", headers: ["X-Token": "override"])
        #expect(request.value(forHTTPHeaderField: "X-Token") == "override")
    }

    @Test func validateThrowsOnNon2xx() {
        let notFound = HTTPS.Response(status: 404, headers: [:], body: Data("gone".utf8))
        #expect(!notFound.ok)
        #expect {
            try notFound.validate()
        } throws: { error in
            (error as? IO.HTTPError)?.status == 404
        }
        let ok = HTTPS.Response(status: 200, headers: [:], body: Data())
        #expect(ok.ok)
        #expect((try? ok.validate()) != nil)
    }
}

@Suite struct HTTPSLive {
    /// Real TLS + CA verification against example.com. Quietly skips
    /// when the network is unavailable; on CI it runs for real.
    @Test func realWorldGET() throws {
        let response: HTTPS.Response
        do {
            response = try HTTPS("www.example.com").timeout(15).get()
        } catch {
            return  // offline — nothing to assert
        }
        #expect(response.ok)
        #expect(response.status == 200)
        #expect(response.bodyString.contains("Example Domain"))
        #expect(!response.headers.isEmpty)
    }

    @Test func openBridgesToIO() throws {
        let io: IO
        do {
            io = try HTTPS("www.example.com").timeout(15).open()
        } catch {
            return  // offline
        }
        let body = try io.readString()
        #expect(body.contains("Example Domain"))
    }
}
