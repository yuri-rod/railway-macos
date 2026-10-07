import XCTest
@testable import RailwayCore

private final class OAuthProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var requestBody = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        Self.lock.lock()
        let data = Self.response, status = Self.status
        Self.requestCount += 1; Self.requestBody = String(decoding: body, as: UTF8.self)
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func configure(_ json: String, status: Int) {
        lock.lock(); defer { lock.unlock() }
        response = Data(json.utf8); self.status = status; requestCount = 0; requestBody = ""
    }
    static func captured() -> (count: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        return (requestCount, requestBody)
    }
}
@MainActor final class OAuthRefreshTests: XCTestCase {
    private func oauth(_ response: String, status: Int = 200) -> RailwayOAuth {
        OAuthProtocol.configure(response, status: status)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OAuthProtocol.self]
        return RailwayOAuth(session: URLSession(configuration: config))
    }
    private var expired: OAuthTokens {
        OAuthTokens(accessToken: "old-access", refreshToken: "old+refresh&token", expiresAt: Date(timeIntervalSince1970: 0))
    }
    func testRefreshRotatesTokensAndEscapesRequest() async throws {
        let client = oauth(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)
        let tokens = try await client.refresh(expired, clientID: "test-client")
        XCTAssertEqual(tokens.accessToken, "new-access")
        XCTAssertEqual(tokens.refreshToken, "new-refresh")
        XCTAssertFalse(tokens.needsRefresh)
        XCTAssertTrue(expired.needsRefresh)
        XCTAssertEqual(OAuthProtocol.captured().body, "client_id=test-client&grant_type=refresh_token&refresh_token=old%2Brefresh%26token")
    }
    func testRefreshRetainsTokenWhenServerDoesNotRotateIt() async throws {
        let client = oauth(#"{"access_token":"new-access","expires_in":3600,"token_type":"bearer"}"#)
        let tokens = try await client.refresh(expired, clientID: "client")
        XCTAssertEqual(tokens.refreshToken, expired.refreshToken)
    }
    func testMissingRefreshTokenFailsWithoutNetworkRequest() async {
        let client = oauth("{}")
        let current = OAuthTokens(accessToken: "old", refreshToken: nil, expiresAt: Date(timeIntervalSince1970: 0))
        do { _ = try await client.refresh(current, clientID: "client"); XCTFail("Expected expired session") }
        catch { guard case OAuthFailure.expired = error else { XCTFail("Unexpected error: \(error)"); return } }
        XCTAssertEqual(OAuthProtocol.captured().count, 0)
    }
    func testRejectedRefreshDoesNotExposeServerBody() async {
        let client = oauth(#"{"error":"invalid_grant","error_description":"private-token-detail"}"#, status: 400)
        do { _ = try await client.refresh(expired, clientID: "client"); XCTFail("Expected refresh rejection") }
        catch {
            guard case OAuthFailure.requestFailed(400) = error else { XCTFail("Unexpected error: \(error)"); return }
            XCTAssertFalse(error.localizedDescription.contains("private-token-detail"))
        }
        XCTAssertEqual(OAuthProtocol.captured().count, 1)
    }
    func testInvalidTokenResponsesCannotBecomeFreshSessions() async {
        for response in [
            #"{"access_token":"","expires_in":3600,"token_type":"bearer"}"#,
            #"{"access_token":"new","expires_in":0,"token_type":"bearer"}"#,
            #"{"access_token":"new","expires_in":3600,"token_type":"Basic"}"#
        ] {
            let client = oauth(response)
            do { _ = try await client.refresh(expired, clientID: "client"); XCTFail("Expected invalid response") }
            catch { guard case OAuthFailure.invalidResponse = error else { XCTFail("Unexpected error: \(error)"); continue } }
        }
    }
}
