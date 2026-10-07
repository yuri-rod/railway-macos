import XCTest
@testable import RailwayCore

final class RailwayTests: XCTestCase {
    func testRejectsEmptyAndInjectedCredentials() {
        XCTAssertThrowsError(try RailwayAPI(token: "  "))
        XCTAssertThrowsError(try RailwayAPI(token: "token\r\nX-Injected: yes"))
    }
    func testPermissionClassificationDoesNotDependOnDisplayText() {
        XCTAssertTrue(RailwayError.http(403).isPermissionDenied)
        XCTAssertTrue(RailwayError.api("Not Authorized").isPermissionDenied)
        XCTAssertFalse(RailwayError.http(401).isPermissionDenied)
        XCTAssertFalse(RailwayError.api("Service unavailable").isPermissionDenied)
    }
    func testGraphQLErrorsDoNotBecomeEmptySuccess() {
        let data = Data(#"{"data":{"value":1},"errors":[{"message":"Permission denied"}]}"#.utf8)
        XCTAssertThrowsError(try RailwayAPI.decode([String: Int].self, from: data)) { error in
            XCTAssertEqual(error.localizedDescription, "Permission denied")
        }
    }
    func testMissingDataRejected() {
        XCTAssertThrowsError(try RailwayAPI.decode([String: Int].self, from: Data("{}".utf8)))
    }
    func testSuccessfulResponse() throws {
        XCTAssertEqual(try RailwayAPI.decode([String: Int].self, from: Data(#"{"data":{"count":2}}"#.utf8)), ["count": 2])
    }
    func testMixedLogImportPreservesMalformedAndPlainLines() {
        let lines = LogEntry.parse("{\"timestamp\":\"now\",\"message\":\"failed\",\"severity\":\"error\"}\nplain text\n{broken}")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].severity, "error")
        XCTAssertEqual(lines[2].message, "{broken}")
    }
    func testLogFilteringCombinesSeverityAndQuery() {
        let line = LogEntry(timestamp: "", message: "Connection refused", severity: "ERROR")
        XCTAssertTrue(line.matches("CONNECTION", errorsOnly: true))
        XCTAssertFalse(line.matches("database", errorsOnly: true))
        XCTAssertFalse(LogEntry(timestamp: "", message: "ready", severity: "info").matches("", errorsOnly: true))
    }
}
