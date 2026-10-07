import Foundation

public struct Connection<T: Codable & Sendable>: Codable, Sendable {
    public struct Edge: Codable, Sendable { public let node: T }
    public let edges: [Edge]
    public var nodes: [T] { edges.map(\.node) }
}
public struct Environment: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}
public struct Service: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
}
public struct Project: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public var workspaceID: String?
    public var workspaceName: String?
    public let environments: Connection<Environment>
    public let services: Connection<Service>
}
public struct Deployment: Codable, Identifiable, Sendable {
    public let id: String
    public let status: String
    public let createdAt: String
    public let staticUrl: String?
    public let canRedeploy: Bool?
    public let canRollback: Bool?
    public let diagnosis: JSONValue?
}
public struct LogEntry: Codable, Sendable, Hashable {
    public let timestamp: String
    public let message: String
    public let severity: String?
    public init(timestamp: String, message: String, severity: String?) {
        self.timestamp = timestamp; self.message = message; self.severity = severity
    }
    public func matches(_ query: String, errorsOnly: Bool) -> Bool {
        let isError = ["error", "fatal", "panic"].contains((severity ?? "").lowercased())
            || message.localizedCaseInsensitiveContains("error")
        return (!errorsOnly || isError) && (query.isEmpty || message.localizedCaseInsensitiveContains(query))
    }
    public static func parse(_ text: String) -> [LogEntry] {
        text.split(separator: "\n").map { line in
            if let data = String(line).data(using: .utf8),
               let entry = try? JSONDecoder().decode(LogEntry.self, from: data) { return entry }
            return LogEntry(timestamp: "", message: String(line), severity: nil)
        }
    }
}
public enum RailwayError: Error, LocalizedError {
    case invalidToken, http(Int), api(String), missingData
    public var isPermissionDenied: Bool {
        switch self {
        case .http(403): true
        case .api(let message): message.localizedCaseInsensitiveContains("not authorized")
        default: false
        }
    }
    public var errorDescription: String? {
        if isPermissionDenied {
            return "Not authorized: Railway denied access to this resource. In Account, enable service management and sign in again, then approve member access for this project or workspace. Your Railway account must also have the required role."
        }
        switch self {
        case .invalidToken: return "Enter a Railway account API token."
        case .http(let code): return "Railway returned HTTP \(code). Check your token and connection."
        case .api(let message): return message
        case .missingData: return "Railway returned no data."
        }
    }
}
public struct RailwayAPI: Sendable {
    private static let authenticatedSession = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
    let token: String
    let session: URLSession
    public init(token: String, session: URLSession? = nil) throws {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RailwayError.invalidToken }
        self.token = value
        self.session = session ?? Self.authenticatedSession
    }
    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let message: String }
        let data: T?
        let errors: [Failure]?
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw RailwayError.api(errors.map(\.message).joined(separator: "\n"))
        }
        guard let value = envelope.data else { throw RailwayError.missingData }
        return value
    }
    func query<T: Decodable>(_ query: String, variables: [String: String] = [:]) async throws -> T {
        try await self.query(query, jsonVariables: variables.mapValues(JSONValue.string))
    }
    func query<T: Decodable>(_ query: String, jsonVariables: [String: JSONValue]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://backboard.railway.com/graphql/v2")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(["query": .string(query), "variables": .object(jsonVariables)]))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RailwayError.missingData }
        guard (200..<300).contains(response.statusCode) else { throw RailwayError.http(response.statusCode) }
        return try Self.decode(T.self, from: data)
    }
    public var terminalAccessToken: String { token }
    public func projects() async throws -> [Project] {
        let result: ProjectAccess = try await query("query { me { workspaces { id name projects { edges { node { id name description environments { edges { node { id name } } } services { edges { node { id name } } } } } } } } externalWorkspaces { projects { id name description environments { edges { node { id name } } } services { edges { node { id name } } } } } }")
        return result.projects
    }
    public func canvas(environment: String) async throws -> CanvasSnapshot {
        struct Result: Decodable {
            struct Environment: Decodable {
                let serviceInstances: Connection<ServiceSnapshot>
                let volumeInstances: Connection<CanvasSnapshot.VolumeAttachment>
                let config: JSONValue
            }
            let environment: Environment
        }
        let result: Result = try await query("query($id:String!) { environment(id:$id) { config serviceInstances { edges { node { serviceId serviceName service { icon } source { repo image } cronSchedule nextCronRunAt activeDeployments { status } latestDeployment { status } domains { customDomains { domain } serviceDomains { domain } } } } } volumeInstances { edges { node { serviceId volume { name } } } } } }", variables: ["id": environment])
        let environment = result.environment
        let names = Dictionary(environment.serviceInstances.nodes.map { ($0.serviceId, $0.serviceName) }, uniquingKeysWith: { first, _ in first })
        return CanvasSnapshot(dependencies: ServiceDependency.extract(config: environment.config, names: names), serviceInstances: environment.serviceInstances, volumeInstances: environment.volumeInstances)
    }
    public func deployments(project: String, environment: String, service: String) async throws -> [Deployment] {
        struct Result: Decodable { let deployments: Connection<Deployment> }
        let result: Result = try await query("query($project: String!, $environment: String!, $service: String!) { deployments(first: 30, input: {projectId: $project, environmentId: $environment, serviceId: $service}) { edges { node { id status createdAt staticUrl canRedeploy canRollback diagnosis } } } }", variables: ["project": project, "environment": environment, "service": service])
        return result.deployments.nodes
    }
    public func logs(deployment: String) async throws -> [LogEntry] {
        struct Result: Decodable { let deploymentLogs: [LogEntry] }
        let result: Result = try await query("query($id: String!) { deploymentLogs(deploymentId: $id, limit: 500) { timestamp message severity } }", variables: ["id": deployment])
        return result.deploymentLogs
    }
}

struct ProjectAccess: Decodable {
    struct Account: Decodable {
        struct Workspace: Decodable { let id: String?; let name: String?; let projects: Connection<Project> }
        let workspaces: [Workspace]
    }
    struct SharedWorkspace: Decodable { let projects: [Project] }
    let me: Account
    let externalWorkspaces: [SharedWorkspace]
    var projects: [Project] {
        var seen = Set<String>()
        return (me.workspaces.flatMap { workspace in workspace.projects.nodes.map { project in
            var project = project; project.workspaceID = workspace.id; project.workspaceName = workspace.name; return project
        } } + externalWorkspaces.flatMap(\.projects))
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
