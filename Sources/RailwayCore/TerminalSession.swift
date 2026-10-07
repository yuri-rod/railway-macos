import Foundation

public struct TerminalTarget: Equatable, Sendable {
    public enum Kind: Sendable { case service, cloudAgent }
    public let kind: Kind
    public let project: String
    public let environment: String
    public let resource: String
    public let session: String
    public init(project: String, environment: String, service: String, session: String = UUID().uuidString) throws {
        try self.init(project: project, environment: environment, resource: service, kind: .service, session: session)
    }
    public init(project: String, environment: String, resource: String, kind: Kind, session: String = UUID().uuidString) throws {
        guard [project, environment, session].allSatisfy({ UUID(uuidString: $0) != nil }), kind == .service ? UUID(uuidString: resource) != nil : AgentThread.validID(resource) else { throw RailwayError.api("Terminal targets must use valid Railway resource identifiers.") }
        self.project = project; self.environment = environment; self.resource = resource; self.kind = kind; self.session = session
    }
    public func arguments(persistent: Bool) -> [String] {
        var arguments = kind == .service ? ["ssh", "--project", project, "--environment", environment, "--service", resource] : ["ca", "ssh", resource, "--project", project, "--environment", environment]
        if persistent { arguments += ["--session", "railway-native-" + session] }
        return arguments
    }
}
public struct TerminalReconnect: Sendable {
    public private(set) var attempt = 0
    public private(set) var stopped = false
    public init() {}
    public mutating func connected() { attempt = 0; stopped = false }
    public mutating func stop() { stopped = true }
    public mutating func nextDelay(exitCode: Int32, persistent: Bool) -> TimeInterval? {
        guard !stopped, persistent, exitCode == 255, attempt < 5 else { return nil }
        attempt += 1
        return min(pow(2, Double(attempt)), 30)
    }
}

public struct TerminalOutput: Sendable {
    private var bytes = Data()
    public init() {}
    public var text: String { String(decoding: bytes, as: UTF8.self) }
    @discardableResult public mutating func append(_ data: Data) -> String {
        let received = text + String(decoding: data, as: UTF8.self)
        if data.count >= 8192 { bytes = Data([UInt8](data.suffix(8192))) }
        else {
            bytes = Data([UInt8](bytes.suffix(8192 - data.count)))
            bytes.append(data)
        }
        return received
    }
}
