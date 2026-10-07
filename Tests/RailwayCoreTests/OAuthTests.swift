import XCTest
@testable import RailwayCore

final class OAuthTests: XCTestCase {
    func testPKCEStandardVector() {
        XCTAssertEqual(OAuthAttempt.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testAuthorizationUsesPKCEAndSelectiveAccess() throws {
        let attempt = try OAuthAttempt()
        let url = attempt.authorizationURL(clientID: "client")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertFalse(items.contains { $0.name == "client_secret" })
        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertNotEqual(attempt.state, attempt.verifier)
    }
    func testCallbackRejectsWrongStateAndOrigin() throws {
        let attempt = try OAuthAttempt()
        XCTAssertThrowsError(try attempt.code(from: URL(string: "railway-native://oauth/callback?code=abc&state=wrong")!))
        XCTAssertThrowsError(try attempt.code(from: URL(string: "railway-native://other/callback?code=abc&state=\(attempt.state)")!))
        XCTAssertThrowsError(try attempt.code(from: URL(string: "railway-native://oauth/callback?code=abc&state=\(attempt.state)&iss=https://evil.test")!))
    }
    func testCallbackRejectsDuplicateParametersAndDenial() throws {
        let attempt = try OAuthAttempt()
        XCTAssertThrowsError(try attempt.code(from: URL(string: "railway-native://oauth/callback?code=a&code=b&state=\(attempt.state)")!))
        XCTAssertThrowsError(try attempt.code(from: URL(string: "railway-native://oauth/callback?error=access_denied&state=\(attempt.state)")!))
        XCTAssertEqual(try attempt.code(from: URL(string: "railway-native://oauth/callback?code=abc&state=\(attempt.state)")!), "abc")
    }
    func testFormEscapesReservedCharacters() {
        XCTAssertEqual(String(decoding: RailwayOAuth.form(["code": "a+b&c=d /"]), as: UTF8.self), "code=a%2Bb%26c%3Dd%20%2F")
    }
    func testProjectsCombineWorkspaceAndIndividualGrantsWithoutDuplicates() throws {
        let project = #"{"id":"one","name":"App","description":null,"environments":{"edges":[]},"services":{"edges":[]}}"#
        let other = project.replacingOccurrences(of: "one", with: "two").replacingOccurrences(of: "App", with: "Worker")
        let json = "{\"data\":{\"me\":{\"workspaces\":[{\"projects\":{\"edges\":[{\"node\":\(project)}]}}]},\"externalWorkspaces\":[{\"projects\":[\(project),\(other)]}]}}"
        let result = try RailwayAPI.decode(ProjectAccess.self, from: Data(json.utf8))
        XCTAssertEqual(result.projects.map(\.id), ["one", "two"])
    }
    func testNoGrantedProjectsIsValidEmptyResult() throws {
        let result = try RailwayAPI.decode(ProjectAccess.self, from: Data(#"{"data":{"me":{"workspaces":[]},"externalWorkspaces":[]}}"#.utf8))
        XCTAssertTrue(result.projects.isEmpty)
    }

}
