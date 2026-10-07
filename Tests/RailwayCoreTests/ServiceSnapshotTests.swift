import XCTest
@testable import RailwayCore

final class ServiceSnapshotTests: XCTestCase {
    private func service(image: String? = nil, repo: String? = nil, active: String? = nil, latest: String? = nil, cron: String? = nil) throws -> ServiceSnapshot {
        let value: [String: Any] = [
            "serviceId": "s", "serviceName": "arbitrary-name", "service": ["icon": NSNull()],
            "source": ["image": image as Any? ?? NSNull(), "repo": repo as Any? ?? NSNull()],
            "cronSchedule": cron as Any? ?? NSNull(),
            "activeDeployments": active.map { [["status": $0]] } ?? [],
            "latestDeployment": latest.map { ["status": $0] } as Any? ?? NSNull(),
            "domains": ["customDomains": [["domain": "example.com"]], "serviceDomains": [["domain": "generated.example.com"]]]
        ]
        return try JSONDecoder().decode(ServiceSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testSourceIconsDoNotDependOnServiceName() throws {
        for (image, icon) in [("postgres:17", "postgresql"), ("ghcr.io/railwayapp-templates/postgres-ssl:17", "postgresql"), ("redis:7", "redis"), ("docker.n8n.io/n8nio/n8n:latest", "n8n"), ("acme/worker:1", "docker")] {
            XCTAssertEqual(try service(image: image).iconName, icon)
        }
        XCTAssertEqual(try service(repo: "owner/project").iconName, "github")
        XCTAssertEqual(try service(repo: "https://git.example.com/repo").iconName, "git")
        XCTAssertNil(try service().iconName)
    }
    func testFailedLatestDoesNotHideServingDeployment() throws {
        let value = try service(active: "SUCCESS", latest: "FAILED")
        XCTAssertEqual(value.statusLabel, "Online")
        XCTAssertTrue(value.failedLatest)
    }
    func testSleepingAndCronAreDistinctFromOnline() throws {
        XCTAssertEqual(try service(active: "SLEEPING").statusLabel, "Sleeping")
        XCTAssertEqual(try service(latest: "COMPLETED", cron: "0 * * * *").statusLabel, "Scheduled")
        XCTAssertEqual(try service().statusLabel, "Not deployed")
    }
    func testCustomDomainTakesPriority() throws {
        XCTAssertEqual(try service().domain, "example.com")
    }
}
