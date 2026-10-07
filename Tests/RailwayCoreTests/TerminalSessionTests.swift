import XCTest
@testable import RailwayCore

final class TerminalSessionTests: XCTestCase {
    func testRecentOutputBoundsGiantGraphemesAndKeepsLatestFailure() {
        var output = TerminalOutput()
        let flood = Data(("a" + String(repeating: "\u{301}", count: 20_000)).utf8)
        for _ in 0..<4 { output.append(flood) }
        XCTAssertLessThanOrEqual(output.text.utf8.count, 8194)
        output.append(Data("permission ".utf8))
        output.append(Data("denied".utf8))
        XCTAssertTrue(output.text.hasSuffix("permission denied"))
        XCTAssertLessThanOrEqual(output.text.utf8.count, 8194)
        output.append(Data(String(repeating: "x", count: 9000).utf8))
        XCTAssertEqual(output.text, String(repeating: "x", count: 8192))
        XCTAssertEqual(TerminalOutput().text, "")
    }
    func testFailureDetectionIncludesReadBeforeHistoryEviction() {
        var output = TerminalOutput()
        let read = Data(("permission denied" + String(repeating: "界", count: 3000)).utf8)
        XCTAssertTrue(output.append(read).contains("permission denied"))
        XCTAssertFalse(output.text.contains("permission denied"))
        output.append(Data("host key verification ".utf8))
        XCTAssertTrue(output.append(Data("failed".utf8)).contains("host key verification failed"))
    }
    func testRecentOutputPreservesUTF8AcrossReads() {
        var output = TerminalOutput()
        for byte in "Olá 世界".utf8 { output.append(Data([byte])) }
        XCTAssertEqual(output.text, "Olá 世界")
    }
    func testReconnectRetainsRemoteSessionIdentity() throws {
        let target = try TerminalTarget(project: UUID().uuidString, environment: UUID().uuidString, service: UUID().uuidString)
        XCTAssertEqual(target.arguments(persistent: true), target.arguments(persistent: true))
        XCTAssertTrue(target.arguments(persistent: true).last!.contains(target.session))
        XCTAssertFalse(target.arguments(persistent: false).contains("--session"))
    }
    func testCloudTerminalUsesExplicitMachineAndEnvironment() throws {
        let project = UUID().uuidString, environment = UUID().uuidString, machine = UUID().uuidString
        let target = try TerminalTarget(project: project, environment: environment, resource: machine, kind: .cloudAgent)
        XCTAssertEqual(Array(target.arguments(persistent: true).prefix(7)), ["ca", "ssh", machine, "--project", project, "--environment", environment])
        XCTAssertTrue(target.arguments(persistent: true).contains("--session"))
    }
    func testRejectsShellFragmentsAndOptionInjection() {
        XCTAssertThrowsError(try TerminalTarget(project: "--help", environment: UUID().uuidString, service: UUID().uuidString))
        XCTAssertThrowsError(try TerminalTarget(project: UUID().uuidString, environment: UUID().uuidString, service: "$(touch /tmp/injection)"))
    }
    func testReconnectBackoffIsBoundedAndNeverRestartsEndedShell() {
        var policy = TerminalReconnect()
        XCTAssertNil(policy.nextDelay(exitCode: 0, persistent: true))
        XCTAssertNil(policy.nextDelay(exitCode: 255, persistent: false))
        XCTAssertEqual((0..<5).compactMap { _ in policy.nextDelay(exitCode: 255, persistent: true) }, [2, 4, 8, 16, 30])
        XCTAssertNil(policy.nextDelay(exitCode: 255, persistent: true))
        policy.connected(); policy.stop()
        XCTAssertNil(policy.nextDelay(exitCode: 255, persistent: true))
    }
}
