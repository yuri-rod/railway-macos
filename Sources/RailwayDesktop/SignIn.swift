import AppKit
import AuthenticationServices
import RailwayCore

@MainActor final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
    func authenticate(writeAccess: Bool = false) async throws -> OAuthTokens {
        let registration: OAuthRegistration
        if let saved = try await Credentials.shared.read(account: "oauth-client") {
            registration = try JSONDecoder().decode(OAuthRegistration.self, from: Data(saved.utf8))
        } else {
            registration = try await RailwayOAuth().register()
            try await Credentials.shared.save(String(decoding: JSONEncoder().encode(registration), as: UTF8.self), account: "oauth-client")
        }
        let attempt = try OAuthAttempt()
        defer { session = nil }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: attempt.authorizationURL(clientID: registration.client_id, writeAccess: writeAccess), callbackURLScheme: "railway-native") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: OAuthFailure.invalidCallback) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: OAuthFailure.invalidResponse) }
        }
        return try await RailwayOAuth().exchange(code: attempt.code(from: callback), attempt: attempt, clientID: registration.client_id)
    }
}
