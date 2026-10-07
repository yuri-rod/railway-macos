import XCTest
@testable import RailwayCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var response = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let data = Self.response; Self.lastRequest = request; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func configure(_ json: String) {
        lock.lock(); defer { lock.unlock() }
        response = Data(json.utf8); lastRequest = nil
    }
    static func body() throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let request = lastRequest else { throw RailwayError.missingData }
        if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
        guard let stream = request.httpBodyStream else { throw RailwayError.missingData }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw RailwayError.missingData }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
@MainActor final class APIContractTests: XCTestCase {
    private func api(_ response: String) throws -> RailwayAPI {
        StubProtocol.configure(response)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return try RailwayAPI(token: "test-token", session: URLSession(configuration: config))
    }
    func testProjectListingPreservesWorkspaceMembershipAndSharedAccess() async throws {
        let project = #"{"id":"p1","name":"First","description":null,"environments":{"edges":[]},"services":{"edges":[]}}"#
        let shared = #"{"id":"p2","name":"Second","description":null,"environments":{"edges":[]},"services":{"edges":[]}}"#
        let client = try api("{\"data\":{\"me\":{\"workspaces\":[{\"id\":\"w1\",\"name\":\"Personal\",\"projects\":{\"edges\":[{\"node\":\(project)}]}}]},\"externalWorkspaces\":[{\"projects\":[\(project),\(shared)]}]}}")
        let projects = try await client.projects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].workspaceID, "w1")
        XCTAssertEqual(projects[0].workspaceName, "Personal")
        XCTAssertNil(projects[1].workspaceID)
        XCTAssertTrue((try StubProtocol.body()["query"] as! String).contains("workspaces { id name projects"))
        let cached = try JSONDecoder().decode([Project].self, from: JSONEncoder().encode(projects))
        XCTAssertEqual(cached[0].workspaceID, "w1")
    }
    func testAccountProfileLoadsIdentityAndSharedWorkspaces() async throws {
        let client = try api(#"{"data":{"me":{"id":"user","name":null,"email":"user@example.com","githubUsername":"username","workspaces":[{"id":"workspace","name":"Personal"}]}}}"#)
        let profile = try await client.accountProfile()
        XCTAssertEqual(profile.displayName, "username")
        XCTAssertEqual(profile.email, "user@example.com")
        XCTAssertEqual(profile.workspaces.first?.name, "Personal")
        let body = try StubProtocol.body()
        XCTAssertTrue((body["query"] as! String).contains("me {"))
    }
    func testVariableValuesRemainInVariablesAndDoNotBecomeGraphQLCode() async throws {
        let client = try api(#"{"data":{"variableUpsert":true}}"#)
        let secret = "\" } mutation { deleteEverything } #\n$PASSWORD"
        try await client.setVariable(project: "p", environment: "e", service: "s", name: "SECRET", value: secret)
        let body = try StubProtocol.body()
        XCTAssertFalse((body["query"] as! String).contains(secret))
        XCTAssertTrue((body["query"] as! String).contains("skipDeploys:true"))
        XCTAssertEqual((body["variables"] as! [String: String])["value"], secret)
    }
    func testPermissionDeniedDoesNotBecomeSuccessfulSave() async throws {
        let client = try api(#"{"data":{"variableUpsert":true},"errors":[{"message":"Not Authorized"}]}"#)
        do { try await client.setVariable(project: "p", environment: "e", service: "s", name: "KEY", value: "value"); XCTFail("Expected denial") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Not authorized"))
            XCTAssertTrue(error.localizedDescription.contains("approve member access"))
        }
    }
    func testFalseRollbackIsNotReportedAsSuccess() async throws {
        let client = try api(#"{"data":{"deploymentRollback":false}}"#)
        do { try await client.rollback("deployment"); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("did not accept")) }
    }
    func testStagedApplySubmitsReviewedSnapshotInsteadOfMutableGlobalStage() async throws {
        let client = try api(#"{"data":{"environmentPatchCommit":"patch-id"}}"#)
        let patch: JSONValue = .object(["services": .object(["service": .object(["deploy": .object(["numReplicas": .number(2)])])])])
        let result = try await client.applyStaged(environment: "environment", reviewedPatch: patch)
        XCTAssertEqual(result, "patch-id")
        let body = try StubProtocol.body()
        XCTAssertFalse((body["query"] as! String).contains("environmentPatchCommitStaged"))
        let variables = body["variables"] as! [String: Any]
        let actual = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: variables["patch"]!))
        XCTAssertEqual(actual, patch)
    }
    func testCommittedPatchReadbackPreservesFailureDiagnosis() async throws {
        let client = try api(#"{"data":{"environmentPatch":{"id":"patch-id","status":"FAILED","patch":{},"lastAppliedError":"Build failed","updatedAt":"now"}}}"#)
        let result = try await client.environmentPatch("patch-id")
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.lastAppliedError, "Build failed")
        let body = try StubProtocol.body()
        XCTAssertEqual((body["variables"] as! [String: String])["id"], "patch-id")
        XCTAssertTrue((body["query"] as! String).contains("environmentPatch(id:$id)"))
    }
    func testCloudTaskCarriesScopeAndStableIdempotencyKey() async throws {
        let client = try api(#"{"data":{"cloudAgentTaskDispatch":{"cloudAgentId":"machine","sessionId":"session","taskId":"task","status":"QUEUED"}}}"#)
        let result = try await client.dispatchTask(project: "project", environment: "environment", machine: "machine", session: "session", prompt: "Inspect service", idempotencyKey: "stable-key")
        XCTAssertEqual(result.taskId, "task")
        let variables = try StubProtocol.body()["variables"] as! [String: String]
        XCTAssertEqual(variables["key"], "stable-key"); XCTAssertEqual(variables["environment"], "environment"); XCTAssertEqual(variables["session"], "session")
    }
}
