import Foundation

public struct ServiceSnapshot: Codable, Sendable, Identifiable {
    public struct Source: Codable, Sendable { public let repo: String?; public let image: String? }
    public struct Identity: Codable, Sendable { public let icon: String? }
    public struct Domain: Codable, Sendable { public let domain: String }
    public struct Domains: Codable, Sendable { public let customDomains: [Domain]; public let serviceDomains: [Domain] }
    public struct Runtime: Codable, Sendable { public let status: String }
    public let serviceId: String
    public let serviceName: String
    public let service: Identity
    public let source: Source?
    public let cronSchedule: String?
    public let nextCronRunAt: String?
    public let activeDeployments: [Runtime]
    public let latestDeployment: Runtime?
    public let domains: Domains
    public var id: String { serviceId }
    public var domain: String? { domains.customDomains.first?.domain ?? domains.serviceDomains.first?.domain }
    public var status: String { activeDeployments.first?.status ?? latestDeployment?.status ?? "NOT_DEPLOYED" }
    public var failedLatest: Bool { ["FAILED", "CRASHED"].contains(latestDeployment?.status ?? "") && !["FAILED", "CRASHED"].contains(status) }
    public var statusLabel: String {
        switch status {
        case "SUCCESS": "Online"
        case "SLEEPING": "Sleeping"
        case "BUILDING": "Building"
        case "DEPLOYING", "INITIALIZING": "Deploying"
        case "FAILED": "Failed"
        case "CRASHED": "Crashed"
        case "REMOVED": "Stopped"
        case "COMPLETED": cronSchedule == nil ? "Completed" : "Scheduled"
        case "NOT_DEPLOYED": "Not deployed"
        default: status.capitalized
        }
    }
    public var iconName: String? {
        let icon = (service.icon ?? "").lowercased()
        let image = (source?.image ?? "").lowercased()
        let components = image.split(whereSeparator: { "/:@".contains($0) }).map(String.init)
        if icon.contains("postgresql") || components.contains("postgres") || components.contains("postgresql") || components.contains("postgres-ssl") { return "postgresql" }
        if icon.contains("redis") || components.contains("redis") { return "redis" }
        if icon.contains("n8n") || components.contains("n8n") { return "n8n" }
        if let repo = source?.repo, !repo.isEmpty {
            return repo.contains("://") && !repo.contains("github.com/") ? "git" : "github"
        }
        return image.isEmpty ? nil : "docker"
    }
}
public struct CanvasSnapshot: Codable, Sendable {
    public struct VolumeAttachment: Codable, Sendable {
        public struct Volume: Codable, Sendable { public let name: String }
        public let serviceId: String?
        public let volume: Volume
    }
    public var dependencies: [ServiceDependency]?
    public let serviceInstances: Connection<ServiceSnapshot>
    public let volumeInstances: Connection<VolumeAttachment>
    public func volumes(for service: String) -> [String] {
        volumeInstances.nodes.filter { $0.serviceId == service }.map { $0.volume.name }
    }
}
