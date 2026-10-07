import Foundation

public struct MetricSeries: Decodable, Sendable, Identifiable {
    public struct Point: Decodable, Sendable {
        public let ts: Int
        public let value: Double
        public var date: Date { Date(timeIntervalSince1970: Double(ts)) }
    }
    public let measurement: String
    public let values: [Point]
    public var id: String { measurement }
}

extension RailwayAPI {
    public func metrics(environment: String, service: String, since: Date) async throws -> [MetricSeries] {
        struct Result: Decodable { let metrics: [MetricSeries] }
        let result: Result = try await query("query($environment:String!,$service:String!,$start:DateTime!) { metrics(environmentId:$environment,serviceId:$service,startDate:$start,measurements:[CPU_USAGE,MEMORY_USAGE_GB,NETWORK_RX_GB,NETWORK_TX_GB]) { measurement values { ts value } } }", variables: ["environment": environment, "service": service, "start": ISO8601DateFormatter().string(from: since)])
        return result.metrics
    }
    public func variables(project: String, environment: String, service: String) async throws -> [String: String] {
        struct Result: Decodable { let variables: [String: String] }
        let result: Result = try await query("query($project:String!,$environment:String!,$service:String!) { variables(projectId:$project,environmentId:$environment,serviceId:$service,unrendered:true) }", variables: ["project": project, "environment": environment, "service": service])
        return result.variables
    }
    public func setVariable(project: String, environment: String, service: String, name: String, value: String) async throws {
        struct Result: Decodable { let variableUpsert: Bool }
        let result: Result = try await query("mutation($project:String!,$environment:String!,$service:String!,$name:String!,$value:String!) { variableUpsert(input:{projectId:$project,environmentId:$environment,serviceId:$service,name:$name,value:$value,skipDeploys:true}) }", variables: ["project": project, "environment": environment, "service": service, "name": name, "value": value])
        guard result.variableUpsert else { throw RailwayError.api("Railway did not save the variable.") }
    }
    public func redeploy(_ id: String) async throws -> Deployment {
        struct Result: Decodable { let deploymentRedeploy: Deployment }
        let result: Result = try await query("mutation($id:String!) { deploymentRedeploy(id:$id) { id status createdAt staticUrl } }", variables: ["id": id])
        return result.deploymentRedeploy
    }
    public func rollback(_ id: String) async throws {
        struct Result: Decodable { let deploymentRollback: Bool }
        let result: Result = try await query("mutation($id:String!) { deploymentRollback(id:$id) }", variables: ["id": id])
        guard result.deploymentRollback else { throw RailwayError.api("Railway did not accept the rollback.") }
    }
}

public struct CloudMachine: Decodable, Sendable, Identifiable {
    public struct Session: Decodable, Sendable, Identifiable {
        public let sessionId: String
        public let title: String?
        public let state: String
        public let updatedAt: String
        public var id: String { sessionId }
    }
    public struct Domain: Decodable, Sendable {
        public let domain: String
        public let port: Int
    }
    public let id: String
    public let name: String
    public let status: String
    public let region: String?
    public let sessions: [Session]
    public let domains: [Domain]
}
public struct CloudTask: Decodable, Sendable, Identifiable {
    public let id: String
    public let cloudAgentId: String?
    public let sessionId: String?
    public let status: String
    public let promptPreview: String?
    public let text: String?
    public let error: String?
    public let createdAt: String
}
public struct CloudTaskHandle: Decodable, Sendable {
    public let cloudAgentId: String
    public let sessionId: String
    public let taskId: String
    public let status: String
}
extension RailwayAPI {
    public func cloudMachines(environment: String) async throws -> [CloudMachine] {
        struct Result: Decodable { let cloudAgents: [CloudMachine] }
        let result: Result = try await query("query($id:ID!) { cloudAgents(environmentId:$id) { id name status region domains { domain port } sessions { sessionId title state updatedAt } } }", variables: ["id": environment])
        return result.cloudAgents
    }
    public func cloudTasks(environment: String) async throws -> [CloudTask] {
        struct Result: Decodable { struct Page: Decodable { let tasks: [CloudTask]; let nextCursor: String? }; let cloudAgentTasks: Page }
        var all: [CloudTask] = []
        var cursor: String?
        repeat {
            var variables = ["id": environment]; variables["cursor"] = cursor
            let result: Result = try await query("query($id:String!,$cursor:String) { cloudAgentTasks(environmentId:$id,cursor:$cursor,limit:100) { nextCursor tasks { id cloudAgentId sessionId status promptPreview text error createdAt } } }", variables: variables)
            all += result.cloudAgentTasks.tasks
            let next = result.cloudAgentTasks.nextCursor
            guard next == nil || next != cursor else { throw RailwayError.api("Railway repeated the task cursor.") }
            cursor = next
        } while cursor != nil && all.count < 1000
        return all
    }
    public func createCloudMachine(environment: String, name: String) async throws -> CloudMachine {
        struct Result: Decodable { let cloudAgentCreate: CloudMachine }
        let result: Result = try await query("mutation($id:String!,$name:String!) { cloudAgentCreate(input:{environmentId:$id,name:$name}) { id name status region domains { domain port } sessions { sessionId title state updatedAt } } }", variables: ["id": environment, "name": name])
        return result.cloudAgentCreate
    }
    public func cloudLifecycle(id: String, wake: Bool) async throws -> CloudMachine {
        let operation = wake ? "cloudAgentWake" : "cloudAgentSleep"
        struct Result: Decodable { let machine: CloudMachine }
        let result: Result = try await query("mutation($id:ID!) { machine: \(operation)(id:$id) { id name status region domains { domain port } sessions { sessionId title state updatedAt } } }", variables: ["id": id])
        return result.machine
    }
    public func dispatchTask(project: String, environment: String, machine: String, session: String?, prompt: String, idempotencyKey: String) async throws -> CloudTaskHandle {
        struct Result: Decodable { let cloudAgentTaskDispatch: CloudTaskHandle }
        var variables = ["project": project, "environment": environment, "machine": machine, "prompt": prompt, "key": idempotencyKey]; variables["session"] = session
        let result: Result = try await query("mutation($project:String!,$environment:String!,$machine:String!,$session:String,$prompt:String!,$key:String!) { cloudAgentTaskDispatch(input:{projectId:$project,environmentId:$environment,cloudAgentId:$machine,sessionId:$session,prompt:$prompt,idempotencyKey:$key}) { cloudAgentId sessionId taskId status } }", variables: variables)
        return result.cloudAgentTaskDispatch
    }
}

public struct CloudTaskProgress: Decodable, Sendable {
    public struct Progress: Decodable, Sendable {
        public let steps: Int
        public let tools: [String]
        public let todos: JSONValue?
    }
    public struct Interaction: Decodable, Identifiable, Sendable {
        public let requestId: String
        public let message: String?
        public let tool: String?
        public let summary: JSONValue?
        public let actions: [String]
        public var id: String { requestId }
    }
    public let taskId: String
    public let status: String
    public let text: String?
    public let error: String?
    public let progress: Progress?
    public let pendingInteractions: [Interaction]
}
public enum CloudInteractionAction: String, Sendable, CaseIterable { case ACCEPT, ALLOW, CANCEL, DECLINE, DENY }
extension RailwayAPI {
    public func cloudTask(machine: String, session: String, task: String) async throws -> CloudTaskProgress {
        struct Result: Decodable { let cloudAgentTask: CloudTaskProgress }
        let result: Result = try await query("query($machine:String!,$session:String!,$task:String!) { cloudAgentTask(cloudAgentId:$machine,sessionId:$session,taskId:$task) { taskId status text error progress { steps tools todos } pendingInteractions { requestId message tool summary actions } } }", variables: ["machine": machine, "session": session, "task": task])
        return result.cloudAgentTask
    }
    public func respondToCloudTask(task: String, request: String, action: CloudInteractionAction) async throws -> String {
        struct Result: Decodable { struct Response: Decodable { let outcome: String }; let cloudAgentTaskRespond: Response }
        let result: Result = try await query("mutation($task:String!,$request:String!,$action:CloudAgentTaskInteractionAction!) { cloudAgentTaskRespond(input:{taskId:$task,requestId:$request,action:$action}) { outcome } }", variables: ["task": task, "request": request, "action": action.rawValue])
        return result.cloudAgentTaskRespond.outcome
    }
}

public struct WorkspaceSummary: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
}
extension RailwayAPI {
    public func workspaces() async throws -> [WorkspaceSummary] {
        struct Result: Decodable { struct Account: Decodable { let workspaces: [WorkspaceSummary] }; let me: Account }
        let result: Result = try await query("query { me { workspaces { id name } } }")
        return result.me.workspaces
    }
    public func createProject(workspace: String, name: String) async throws -> String {
        struct Result: Decodable { struct Project: Decodable { let id: String }; let projectCreate: Project }
        let result: Result = try await query("mutation($workspace:String!,$name:String!) { projectCreate(input:{workspaceId:$workspace,name:$name,isPublic:false}) { id } }", variables: ["workspace": workspace, "name": name])
        return result.projectCreate.id
    }
}
