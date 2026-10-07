import XCTest
import RailwayCore
@testable import RailwayDesktop

private final class WorkspaceProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var pending: [String: WorkspaceProtocol] = [:]
    nonisolated(unsafe) static var received: XCTestExpectation?
    static let project = #"{"id":"p","name":"Shared project","environments":{"edges":[{"node":{"id":"e","name":"production"}}]},"services":{"edges":[{"node":{"id":"s","name":"Service"}}]}}"#
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let query = String(decoding: data, as: UTF8.self)
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-account",
           let operation = ["deploymentLogs", "serviceInstances", "deployments(first:"].first(where: { query.contains($0) }) {
            Self.lock.lock(); Self.pending[operation] = self; let received = Self.received; Self.lock.unlock()
            received?.fulfill()
            return
        }
        if query.contains("externalWorkspaces") {
            respond("{\"data\":{\"me\":{\"workspaces\":[]},\"externalWorkspaces\":[{\"projects\":[\(Self.project)]}]}}")
        } else if query.contains("notificationDeliveries") {
            respond(#"{"data":{"notificationDeliveries":{"edges":[]}}}"#)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
    override func stopLoading() {}
    private func respond(_ json: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    static func hold(_ received: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        self.received = received; pending = [:]
    }
    static func finish(_ replies: [String: String]) {
        lock.lock(); let requests = pending; pending = [:]; received = nil; lock.unlock()
        for (operation, request) in requests {
            if let reply = replies[operation] { request.respond(reply) }
            else { request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled)) }
        }
    }
}

@MainActor final class WorkspaceTests: XCTestCase {
    private func makeWorkspace(removeCredentials: @escaping @Sendable () async throws -> Void = {}) throws -> (Workspace, URL, URLSession) {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WorkspaceProtocol.self]
        let session = URLSession(configuration: config)
        return (Workspace(cacheURL: directory.appending(path: "projects.json"), session: session, removeCredentials: removeCredentials), directory, session)
    }
    private func selectService(_ workspace: Workspace) {
        workspace.projectID = "p"; workspace.selectProject(); workspace.serviceID = "s"
    }
    private func removeTemporaryFiles(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { XCTFail("Could not remove test files: \(error)") }
    }
    private func populateSensitiveState(_ workspace: Workspace) throws {
        selectService(workspace)
        workspace.deployments = [try JSONDecoder().decode(Deployment.self, from: Data(#"{"id":"d","status":"SUCCESS","createdAt":"now"}"#.utf8))]
        workspace.logs = [LogEntry(timestamp: "now", message: "old private output", severity: nil)]
        workspace.logDeployment = workspace.deployments.first
        workspace.agentDraft = "old private draft"
        _ = workspace.terminal.screen.feed(Data("old terminal output".utf8))
        workspace.terminal.targetLabel = "old service"
        workspace.canvas = try JSONDecoder().decode(CanvasSnapshot.self, from: Data(#"{"serviceInstances":{"edges":[]},"volumeInstances":{"edges":[]}}"#.utf8))
    }
    private func assertPrivateStateCleared(_ workspace: Workspace, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(workspace.projectID, file: file, line: line)
        XCTAssertNil(workspace.serviceID, file: file, line: line)
        XCTAssertEqual(workspace.environmentID, "", file: file, line: line)
        XCTAssertTrue(workspace.logs.isEmpty, file: file, line: line)
        XCTAssertTrue(workspace.deployments.isEmpty, file: file, line: line)
        XCTAssertNil(workspace.logDeployment, file: file, line: line)
        XCTAssertNil(workspace.canvas, file: file, line: line)
        XCTAssertFalse(workspace.canvasLoading, file: file, line: line)
        XCTAssertEqual(workspace.agentDraft, "", file: file, line: line)
        XCTAssertEqual(workspace.terminal.targetLabel, "", file: file, line: line)
        XCTAssertFalse(workspace.terminal.screen.text.contains("old terminal output"), file: file, line: line)
    }
    func testAccountSwitchClearsPrivateStateEvenForSameProject() async throws {
        let (workspace, directory, session) = try makeWorkspace()
        defer { session.invalidateAndCancel(); removeTemporaryFiles(directory) }
        try await workspace.connect("first-account", save: false)
        try populateSensitiveState(workspace)
        let previous = workspace.sessionID
        try await workspace.connect("second-account", save: false)
        XCTAssertNotEqual(workspace.sessionID, previous)
        XCTAssertTrue(workspace.connected)
        XCTAssertEqual(workspace.projects.map(\.id), ["p"])
        assertPrivateStateCleared(workspace)
        await workspace.disconnect()
    }
    func testLateResponsesCannotRestorePreviousAccountData() async throws {
        let (workspace, directory, session) = try makeWorkspace()
        defer { WorkspaceProtocol.finish([:]); session.invalidateAndCancel(); removeTemporaryFiles(directory) }
        try await workspace.connect("first-account", save: false)
        try populateSensitiveState(workspace)
        let deployment = try XCTUnwrap(workspace.deployments.first)
        let received = expectation(description: "old requests started"); received.expectedFulfillmentCount = 3
        WorkspaceProtocol.hold(received)
        let logs = Task { await workspace.loadLogs(deployment) }
        let canvas = Task { await workspace.loadCanvas() }
        let deployments = Task { await workspace.loadDeployments() }
        await fulfillment(of: [received], timeout: 3)
        try await workspace.connect("second-account", save: false)
        WorkspaceProtocol.finish([
            "deploymentLogs": #"{"data":{"deploymentLogs":[{"timestamp":"now","message":"old private output"}]}}"#,
            "serviceInstances": #"{"data":{"environment":{"config":{},"serviceInstances":{"edges":[]},"volumeInstances":{"edges":[]}}}}"#,
            "deployments(first:": #"{"data":{"deployments":{"edges":[{"node":{"id":"old","status":"SUCCESS","createdAt":"now"}}]}}}"#
        ])
        await logs.value; await canvas.value; await deployments.value
        assertPrivateStateCleared(workspace)
        XCTAssertNil(workspace.error)
        await workspace.disconnect()
    }
    func testLateLogResponseCannotRepopulateDataAfterAccountSwitch() async throws {
        let (workspace, directory, session) = try makeWorkspace()
        defer { WorkspaceProtocol.finish([:]); session.invalidateAndCancel(); removeTemporaryFiles(directory) }
        try await workspace.connect("first-account", save: false)
        try populateSensitiveState(workspace)
        let deployment = try XCTUnwrap(workspace.deployments.first)
        let received = expectation(description: "old log request started")
        WorkspaceProtocol.hold(received)
        let logs = Task { await workspace.loadLogs(deployment) }
        await fulfillment(of: [received], timeout: 3)
        try await workspace.connect("second-account", save: false)
        WorkspaceProtocol.finish(["deploymentLogs": #"{"data":{"deploymentLogs":[{"timestamp":"now","message":"old private output"}]}}"#])
        await logs.value
        XCTAssertTrue(workspace.logs.isEmpty)
        XCTAssertNil(workspace.error)
        await workspace.disconnect()
    }
    func testCredentialDeletionFailureStillClearsVisibleAccountData() async throws {
        let (workspace, directory, session) = try makeWorkspace {
            throw NSError(domain: "CredentialTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Credential cleanup failed"])
        }
        defer { session.invalidateAndCancel(); removeTemporaryFiles(directory) }
        try await workspace.connect("first-account", save: false)
        try populateSensitiveState(workspace)
        let previous = workspace.sessionID
        await workspace.disconnect()
        assertPrivateStateCleared(workspace)
        XCTAssertTrue(workspace.projects.isEmpty)
        XCTAssertFalse(workspace.connected)
        XCTAssertNotEqual(workspace.sessionID, previous)
        XCTAssertEqual(workspace.error, "Credential cleanup failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "projects.json").path))
        let api = try await workspace.authorizedAPI()
        XCTAssertNil(api)
    }
    func testDisconnectClearsStateBeforeCleanupAndBlocksNewSignIn() async throws {
        let started = expectation(description: "credential cleanup started")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let (workspace, directory, session) = try makeWorkspace {
            started.fulfill()
            for await _ in stream { break }
        }
        defer { continuation.finish(); session.invalidateAndCancel(); removeTemporaryFiles(directory) }
        try await workspace.connect("first-account", save: false)
        try populateSensitiveState(workspace)
        let cleanup = Task { await workspace.disconnect() }
        await fulfillment(of: [started], timeout: 3)
        assertPrivateStateCleared(workspace)
        XCTAssertFalse(workspace.connected)
        do {
            try await workspace.connect("second-account", save: false)
            XCTFail("Sign-in must wait for pending credential deletion")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cleanup")) }
        continuation.finish()
        await cleanup.value
        XCTAssertNil(workspace.error)
    }
}
