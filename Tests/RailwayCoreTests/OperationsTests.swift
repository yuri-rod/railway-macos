import XCTest
@testable import RailwayCore

final class OperationsTests: XCTestCase {
    func testServerEventsPreserveUnicodeAndMultipleDataLines() throws {
        var stream = ServerEvents()
        XCTAssertNil(try stream.consume(": keepalive"))
        XCTAssertNil(try stream.consume("event: chunk"))
        XCTAssertNil(try stream.consume("data: {\"text\":"))
        XCTAssertNil(try stream.consume("data: \"Olá 世界\"}"))
        let event = try XCTUnwrap(stream.consume(""))
        XCTAssertEqual(event.kind, "chunk")
        XCTAssertEqual(event.text("text"), "Olá 世界")
        XCTAssertNil(try stream.consume(""))
    }
    func testMalformedAgentEventFailsInsteadOfSilentlyLosingChanges() throws {
        var stream = ServerEvents()
        _ = try stream.consume("event: tool_call_ready")
        _ = try stream.consume("data: invalid JSON")
        XCTAssertThrowsError(try stream.consume(""))
    }
    func testUnknownAgentEventPreservesToolPayload() throws {
        var stream = ServerEvents()
        _ = try stream.consume("event: future_tool")
        _ = try stream.consume("data: {\"args\":{\"replicas\":2,\"enabled\":true}}")
        let event = try XCTUnwrap(stream.consume(""))
        XCTAssertEqual(event.data["args"], .object(["replicas": .number(2), "enabled": .bool(true)]))
    }
    func testOpaqueAgentIdentifiersCannotEscapeTheirURLPath() {
        XCTAssertTrue(AgentThread.validID("thread_abc123"))
        XCTAssertFalse(AgentThread.validID("../other-resource"))
        XCTAssertFalse(AgentThread.validID("thread?environmentId=other"))
        XCTAssertFalse(AgentThread.validID("--help"))
    }
    func testDeepLinksRejectForeignHostsDuplicatesAndInvalidIDs() throws {
        let project = UUID().uuidString, environment = UUID().uuidString, service = UUID().uuidString
        let link = URL(string: "railway-native://project/\(project)/service/\(service)?environmentId=\(environment)")!
        let route = try XCTUnwrap(ServiceRoute(url: link))
        let thread = UUID().uuidString
        XCTAssertEqual(ServiceRoute(url: URL(string: "railway-native://project/\(project)/agent/\(thread)")!)?.agent, thread)
        XCTAssertEqual(ServiceRoute(url: URL(string: "railway-native://project/\(project)/cloud-agent/\(thread)")!)?.cloudAgent, thread)
        XCTAssertEqual(route.project, project); XCTAssertEqual(route.environment, environment); XCTAssertEqual(route.service, service)
        XCTAssertNil(ServiceRoute(url: URL(string: "https://railway.com.evil.test/project/\(project)")!))
        XCTAssertNil(ServiceRoute(url: URL(string: "railway-native://project/\(project)?environmentId=\(environment)&environmentId=\(environment)")!))
        XCTAssertNil(ServiceRoute(url: URL(string: "railway-native://project/invalid")!))
    }
    func testStorageSigningEscapesKeysAndRejectsCredentialExfiltration() throws {
        let credentials = try JSONDecoder().decode(BucketCredentials.self, from: Data(#"{"accessKeyId":"EXAMPLE","secretAccessKey":"test-secret","bucketName":"example","endpoint":"https://t3.storageapi.dev","region":"auto","urlStyle":"virtual-hosted"}"#.utf8))
        let reader = BucketReader(credentials: credentials)
        let request = try reader.request(key: "a folder/photo+1.png", date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.url?.absoluteString, "https://example.t3.storageapi.dev/a%20folder/photo%2B1.png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "19700101T000000Z")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("Credential=EXAMPLE/19700101/auto/s3/aws4_request") == true)
        XCTAssertFalse(request.allHTTPHeaderFields!.description.contains("test-secret"))
        XCTAssertThrowsError(try reader.request(key: "../other-bucket/secret"))
        let bad = try JSONDecoder().decode(BucketCredentials.self, from: Data(#"{"accessKeyId":"EXAMPLE","secretAccessKey":"test-secret","bucketName":"example","endpoint":"https://localhost","region":"auto","urlStyle":"path"}"#.utf8))
        XCTAssertThrowsError(try BucketReader(credentials: bad).request())
    }
    func testDependenciesUseReferencesWithoutRetainingSecretValues() throws {
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"services":{"api":{"variables":{"DATABASE_URL":{"value":"${{Postgres.DATABASE_URL}}"},"CACHE":{"value":"redis://${{Redis.HOST}}:6379"},"SECRET":{"value":"do-not-display"},"SELF":{"value":"${{api.PORT}}"}}}}}"#.utf8))
        let links = ServiceDependency.extract(config: config, names: ["api": "api", "db": "Postgres", "cache": "Redis"])
        XCTAssertEqual(Set(links.map(\.target)), Set(["db", "cache"]))
        let encoded = String(decoding: try JSONEncoder().encode(links), as: UTF8.self)
        XCTAssertFalse(encoded.contains("do-not-display"))
        XCTAssertFalse(encoded.contains("DATABASE_URL"))
    }
    func testMemberScopeIsExplicitOptIn() throws {
        let attempt = try OAuthAttempt()
        let normal = URLComponents(url: attempt.authorizationURL(clientID: "client"), resolvingAgainstBaseURL: false)!.queryItems!
        let member = URLComponents(url: attempt.authorizationURL(clientID: "client", writeAccess: true), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(normal.first { $0.name == "scope" }!.value!.contains("project:viewer"))
        XCTAssertFalse(normal.first { $0.name == "scope" }!.value!.contains("project:member"))
        XCTAssertTrue(member.first { $0.name == "scope" }!.value!.contains("project:member"))
    }
    func testMetricsKeepRealTimestampsAndMissingSamples() throws {
        let result = try JSONDecoder().decode([MetricSeries].self, from: Data(#"[{"measurement":"CPU_USAGE","values":[{"ts":1700000000,"value":0.25}]},{"measurement":"MEMORY_USAGE_GB","values":[]}]"#.utf8))
        XCTAssertEqual(result[0].values[0].date.timeIntervalSince1970, 1700000000)
        XCTAssertEqual(result[0].values[0].value, 0.25)
        XCTAssertTrue(result[1].values.isEmpty)
    }
}
