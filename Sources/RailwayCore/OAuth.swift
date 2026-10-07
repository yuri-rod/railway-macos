import Foundation
import CryptoKit
import Security

public struct OAuthAttempt: Sendable {
    public static let redirect = "railway-native://oauth/callback"
    public let verifier: String
    public let state: String
    public init() throws {
        verifier = try Self.random(); state = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthFailure.invalidResponse }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func challenge(_ verifier: String) -> String { base64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public func authorizationURL(clientID: String, writeAccess: Bool = false) -> URL {
        var url = URLComponents(string: "https://backboard.railway.com/oauth/auth")!
        url.queryItems = ["response_type": "code", "client_id": clientID, "redirect_uri": Self.redirect,
                          "scope": writeAccess ? "openid email profile offline_access workspace:member project:member" : "openid email profile offline_access workspace:viewer project:viewer", "prompt": "consent",
                          "state": state, "code_challenge": Self.challenge(verifier), "code_challenge_method": "S256"]
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    public func code(from callback: URL) throws -> String {
        guard callback.scheme == "railway-native", callback.host == "oauth", callback.path == "/callback",
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw OAuthFailure.invalidCallback }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { throw OAuthFailure.invalidCallback }
        if let issuer = items.first(where: { $0.name == "iss" })?.value, issuer != "https://backboard.railway.com" { throw OAuthFailure.invalidCallback }
        if items.contains(where: { $0.name == "error" }) { throw OAuthFailure.denied }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw OAuthFailure.invalidCallback }
        return code
    }
}
public enum OAuthFailure: Error, LocalizedError {
    case invalidResponse, invalidCallback, denied, expired, requestFailed(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Railway returned an invalid authentication response."
        case .invalidCallback: "The sign-in callback could not be verified. Please sign in again."
        case .denied: "Railway access was not granted."
        case .expired: "Your Railway session expired. Please sign in again."
        case .requestFailed(let code): "Railway sign-in returned HTTP \(code). Please try again."
        }
    }
}
public struct OAuthRegistration: Codable, Sendable {
    public let client_id: String
    public let registration_access_token: String?
    public let registration_client_uri: String?
}
public struct OAuthTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 60 }
}
public struct RailwayOAuth: Sendable {
    public init() {}
    public func register() async throws -> OAuthRegistration {
        var request = URLRequest(url: URL(string: "https://backboard.railway.com/oauth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Railway (independent desktop client)", "application_type": "native",
            "redirect_uris": [OAuthAttempt.redirect], "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]
        ])
        let result: OAuthRegistration = try await send(request)
        guard !result.client_id.isEmpty else { throw OAuthFailure.invalidResponse }
        return result
    }
    public func exchange(code: String, attempt: OAuthAttempt, clientID: String) async throws -> OAuthTokens {
        try await tokens(["grant_type": "authorization_code", "code": code, "code_verifier": attempt.verifier,
                          "client_id": clientID, "redirect_uri": OAuthAttempt.redirect])
    }
    public func refresh(_ current: OAuthTokens, clientID: String) async throws -> OAuthTokens {
        guard let refresh = current.refreshToken else { throw OAuthFailure.expired }
        return try await tokens(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID], fallbackRefresh: refresh)
    }
    public static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
    private func tokens(_ fields: [String: String], fallbackRefresh: String? = nil) async throws -> OAuthTokens {
        struct Response: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let token_type: String }
        var request = URLRequest(url: URL(string: "https://backboard.railway.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(fields)
        let response: Response = try await send(request)
        guard response.token_type.lowercased() == "bearer", !response.access_token.isEmpty, response.expires_in > 0 else { throw OAuthFailure.invalidResponse }
        return OAuthTokens(accessToken: response.access_token, refreshToken: response.refresh_token ?? fallbackRefresh, expiresAt: Date().addingTimeInterval(response.expires_in))
    }
    private func send<T: Decodable>(_ value: URLRequest) async throws -> T {
        var request = value; request.timeoutInterval = 30
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OAuthFailure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw OAuthFailure.requestFailed(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
