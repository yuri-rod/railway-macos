import Foundation

public struct RailwayNotification: Codable, Sendable, Identifiable {
    public struct Incident: Codable, Sendable {
        public let projectId: String?
        public let environmentId: String?
        public let serviceId: String?
        public let resourceId: String?
        public let resourceType: String?
        public let severity: String
        public let eventType: String?
        public let payload: JSONValue
    }
    public let id: String
    public let createdAt: String
    public let readAt: String?
    public let notificationInstance: Incident
    public var title: String { notificationInstance.eventType?.replacingOccurrences(of: "_", with: " ") ?? "Railway notification" }
}
public struct ServiceRoute: Equatable, Sendable {
    public let project: String
    public let environment: String?
    public let service: String?
    public let agent: String?
    public let cloudAgent: String?
    public init?(url: URL) {
        guard url.user == nil, url.password == nil,
              (url.scheme == "railway-native" && url.host == "project") || (url.scheme == "https" && url.host == "railway.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        let path = url.scheme == "https" ? Array(parts.dropFirst()) : parts
        guard url.scheme != "https" || parts.first == "project", let id = path.first, UUID(uuidString: id) != nil else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        project = id
        environment = items.first { $0.name == "environmentId" }?.value
        service = path.count >= 3 && path[1] == "service" ? path[2] : items.first { $0.name == "serviceId" }?.value
        agent = path.count >= 3 && path[1] == "agent" ? path[2] : nil
        cloudAgent = path.count >= 3 && path[1] == "cloud-agent" ? path[2] : nil
        guard agent.map(AgentThread.validID) ?? true, cloudAgent.map(AgentThread.validID) ?? true else { return nil }
        guard environment.map({ UUID(uuidString: $0) != nil }) ?? true, service.map({ UUID(uuidString: $0) != nil }) ?? true else { return nil }
    }
}
extension RailwayAPI {
    public func notifications() async throws -> [RailwayNotification] {
        struct Result: Decodable { let notificationDeliveries: Connection<RailwayNotification> }
        let result: Result = try await query("query { notificationDeliveries(first:100) { edges { node { id createdAt readAt notificationInstance { projectId environmentId serviceId resourceId resourceType severity eventType payload } } } } }")
        return result.notificationDeliveries.nodes
    }
    public func markNotificationRead(_ id: String) async throws {
        struct Result: Decodable { let notificationDeliveriesMarkAsRead: Bool }
        let result: Result = try await query("mutation($id:String!) { notificationDeliveriesMarkAsRead(deliveryIds:[$id]) }", variables: ["id": id])
        guard result.notificationDeliveriesMarkAsRead else { throw RailwayError.api("Railway did not mark the notification as read.") }
    }
}
