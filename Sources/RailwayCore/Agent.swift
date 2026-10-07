import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var formatted: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "Unable to display response" }
        return String(decoding: data, as: UTF8.self)
    }
}
public struct AgentThread: Decodable, Identifiable, Sendable {
    public static func validID(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first.isNumber, value.utf8.count <= 128 else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    public let id: String
    public let title: String?
    public let updatedAt: String
}
public struct AgentMessage: Decodable, Identifiable, Sendable {
    public let id: String
    public let role: String
    public var content: String
    public let parts: [JSONValue]?
    public init(id: String = UUID().uuidString, role: String, content: String) {
        self.id = id; self.role = role; self.content = content; parts = nil
    }
}
public struct AgentEvent: Sendable {
    public let kind: String
    public let data: [String: JSONValue]
    public func text(_ key: String) -> String? { if case .string(let value) = data[key] { return value }; return nil }
}
public struct ServerEvents: Sendable {
    private var kind = "message"
    private var lines: [String] = []
    public init() {}
    public mutating func consume(_ line: String) throws -> AgentEvent? {
        if line.isEmpty {
            defer { kind = "message"; lines = [] }
            guard !lines.isEmpty else { return nil }
            return AgentEvent(kind: kind, data: try JSONDecoder().decode([String: JSONValue].self, from: Data(lines.joined(separator: "\n").utf8)))
        }
        if line.hasPrefix("event:") { kind = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if line.hasPrefix("data:") {
            let value = line.dropFirst(5)
            lines.append(String(value.first == " " ? value.dropFirst() : value))
            guard lines.reduce(0, { $0 + $1.utf8.count }) <= 4_000_000 else { throw RailwayError.api("Agent event exceeded the size limit.") }
        }
        return nil
    }
}
extension RailwayAPI {
    private func agentRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    public func threads(environment: String) async throws -> [AgentThread] {
        struct Result: Decodable { let threads: [AgentThread] }
        var url = URLComponents(string: "https://backboard.railway.com/api/v1/agent/threads")!
        url.queryItems = [.init(name: "environmentId", value: environment), .init(name: "limit", value: "100")]
        let (data, response) = try await session.data(for: agentRequest(url.url!))
        try Self.checkResponse(response)
        return try JSONDecoder().decode(Result.self, from: data).threads
    }
    public func messages(thread: String) async throws -> [AgentMessage] {
        struct Result: Decodable { let messages: [AgentMessage] }
        guard AgentThread.validID(thread) else { throw RailwayError.api("Invalid conversation identifier.") }
        let url = URL(string: "https://backboard.railway.com/api/v1/agent/threads/\(thread)/messages?limit=100")!
        let (data, response) = try await session.data(for: agentRequest(url))
        try Self.checkResponse(response)
        return try JSONDecoder().decode(Result.self, from: data).messages
    }
    public func chat(project: String, environment: String, service: String?, thread: String?, message: String, onEvent: @Sendable (AgentEvent) async throws -> Void) async throws {
        var request = agentRequest(URL(string: "https://backboard.railway.com/api/v1/agent")!)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = ["projectId": project, "environmentId": environment, "message": message]
        body["threadId"] = thread; body["serviceId"] = service
        request.httpBody = try JSONEncoder().encode(body)
        let (bytes, response) = try await session.bytes(for: request)
        try Self.checkResponse(response)
        var events = ServerEvents()
        var completed = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = try events.consume(line) {
                if ["workflow_completed", "completed"].contains(event.kind) { completed = true }
                try await onEvent(event)
            }
        }
        if let event = try events.consume("") {
            if ["workflow_completed", "completed"].contains(event.kind) { completed = true }
            try await onEvent(event)
        }
        guard completed else { throw RailwayError.api("The agent stream disconnected. Reload history before sending again; the server may still be working.") }
    }
    private static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RailwayError.missingData }
        guard (200..<300).contains(http.statusCode) else { throw RailwayError.http(http.statusCode) }
    }
}
