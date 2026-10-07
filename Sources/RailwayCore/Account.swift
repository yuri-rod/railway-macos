import Foundation

public struct AccountProfile: Decodable, Sendable {
    public let id: String
    public let name: String?
    public let email: String
    public let githubUsername: String?
    public let workspaces: [WorkspaceSummary]
    public var displayName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? githubUsername ?? email }
}

extension RailwayAPI {
    public func accountProfile() async throws -> AccountProfile {
        struct Result: Decodable { let me: AccountProfile }
        let result: Result = try await query("query { me { id name email githubUsername workspaces { id name } } }")
        return result.me
    }
}
