import Foundation

public struct StagedChanges: Codable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let patch: JSONValue
    public let lastAppliedError: String?
    public let updatedAt: String
    public var finished: Bool { status == "COMMITTED" || status == "FAILED" }
}
extension RailwayAPI {
    public func environmentPatch(_ id: String) async throws -> StagedChanges {
        struct Result: Decodable { let environmentPatch: StagedChanges }
        let result: Result = try await query("query($id:String!) { environmentPatch(id:$id) { id status patch lastAppliedError updatedAt } }", variables: ["id": id])
        return result.environmentPatch
    }
    public func stagedChanges(environment: String) async throws -> StagedChanges {
        struct Result: Decodable { let environmentStagedChanges: StagedChanges }
        let result: Result = try await query("query($id:String!) { environmentStagedChanges(environmentId:$id) { id status patch lastAppliedError updatedAt } }", variables: ["id": environment])
        return result.environmentStagedChanges
    }
    public func applyStaged(environment: String, reviewedPatch: JSONValue) async throws -> String {
        struct Result: Decodable { let environmentPatchCommit: String }
        let result: Result = try await query("mutation($id:String!,$patch:EnvironmentConfig!) { environmentPatchCommit(environmentId:$id,patch:$patch) }", jsonVariables: ["id": .string(environment), "patch": reviewedPatch])
        return result.environmentPatchCommit
    }
    public func failedPatches(environment: String) async throws -> [StagedChanges] {
        struct Result: Decodable { let environmentPatches: Connection<StagedChanges> }
        let result: Result = try await query("query($id:String!) { environmentPatches(environmentId:$id,first:30) { edges { node { id status patch lastAppliedError updatedAt } } } }", variables: ["id": environment])
        return result.environmentPatches.nodes.filter { $0.status == "FAILED" }
    }
    public func restage(patch: String) async throws -> StagedChanges {
        struct Result: Decodable { let environmentPatchRestage: StagedChanges }
        let result: Result = try await query("mutation($id:String!) { environmentPatchRestage(patchId:$id) { id status patch lastAppliedError updatedAt } }", variables: ["id": patch])
        return result.environmentPatchRestage
    }
}
