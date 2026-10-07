import Foundation

public struct ServiceDependency: Codable, Sendable, Hashable {
    public let source: String
    public let target: String
    public static func extract(config: JSONValue, names: [String: String]) -> [ServiceDependency] {
        guard case .object(let root) = config, case .object(let services) = root["services"],
              let expression = try? NSRegularExpression(pattern: #"\$\{\{\s*([^.}]+)\.([^}]+)\}\}"#) else { return [] }
        let idsByName = Dictionary(names.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var links = Set<ServiceDependency>()
        for (service, value) in services {
            guard names[service] != nil, case .object(let fields) = value, case .object(let variables) = fields["variables"] else { continue }
            for variable in variables.values {
                guard case .object(let entry) = variable, case .string(let text) = entry["value"] else { continue }
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in expression.matches(in: text, range: range) {
                    guard let range = Range(match.range(at: 1), in: text), let target = idsByName[String(text[range]).trimmingCharacters(in: .whitespaces)], target != service else { continue }
                    links.insert(ServiceDependency(source: service, target: target))
                }
            }
        }
        return links.sorted { $0.source == $1.source ? $0.target < $1.target : $0.source < $1.source }
    }
}
