import Foundation
import Observation
import RailwayCore

@MainActor @Observable final class Workspace {
    let conversation = AgentConversation()
    let inbox = FailureInbox()
    let terminal = SSHTerminal()
    var projects: [Project] = []
    var projectID: String?
    var environmentID = ""
    var serviceID: String?
    var deployments: [Deployment] = []
    var canvas: CanvasSnapshot?
    var canvasLoading = false
    private var canvasGeneration = UUID()
    private var selectedProjectID: String?
    var logs: [LogEntry] = []
    var logDeployment: Deployment?
    var agentDraft = ""
    var submittedPatchID: String?
    var submittedPatchEnvironment = ""
    var submittedPatch: StagedChanges?
    var submittedPatchError: String?
    var sessionID: UUID { accountGeneration }
    var pendingAgentThread: String?
    var pendingCloudMachine: String?
    var pendingTerminalTarget: TerminalTarget?
    var pendingTerminalLabel = ""
    var cloudTasks: [CloudTask] = []
    var cloudTaskError: String?
    private var cloudPollDenied = false
    var error: String?
    var busy = false
    var connected = false
    var signingIn = false
    var restoring = false
    var accountProfile: AccountProfile?
    var accountProfileError: String?
    var loadingAccountProfile = false
    var authenticationMethod: String { tokens == nil ? "API token" : "Railway OAuth" }
    var cachedAt: Date?
    var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    private var api: RailwayAPI?
    private var tokens: OAuthTokens?
    private let signIn = SignIn()
    private var refreshTask: Task<String, Error>?
    private var monitorTask: Task<Void, Never>?
    private var generation = UUID()
    private var accountGeneration = UUID()
    private let cacheURL: URL
    var project: Project? { projects.first { $0.id == projectID } }
    init() {
        cacheURL = URL.applicationSupportDirectory.appending(path: "RailwayNative/projects.json")
        do {
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                projects = cache.projects; cachedAt = cache.date
            }
        } catch { self.error = "Could not read cached projects: \(error.localizedDescription)" }
    }
    private struct Cache: Codable { let date: Date; let projects: [Project] }
    func login(writeAccess: Bool = false) async throws {
        guard !signingIn, !restoring else { return }
        signingIn = true
        let request = accountGeneration
        defer { signingIn = false }
        let session = try await signIn.authenticate(writeAccess: writeAccess)
        guard request == accountGeneration else { throw CancellationError() }
        try await Credentials.shared.save(String(decoding: JSONEncoder().encode(session), as: UTF8.self), account: "oauth-session")
        guard request == accountGeneration else { throw CancellationError() }
        tokens = session
        try await connect(session.accessToken, save: false)
    }
    func authorizedAPI() async throws -> RailwayAPI? {
        guard let tokens else { return api }
        if !tokens.needsRefresh { return try RailwayAPI(token: tokens.accessToken) }
        let request = accountGeneration
        if let refreshTask {
            let token = try await refreshTask.value
            guard request == accountGeneration else { throw CancellationError() }
            return try RailwayAPI(token: token)
        }
        let task = Task<String, Error> {
            guard let client = try await Credentials.shared.read(account: "oauth-client") else { throw OAuthFailure.expired }
            let registration = try JSONDecoder().decode(OAuthRegistration.self, from: Data(client.utf8))
            let refreshed = try await RailwayOAuth().refresh(tokens, clientID: registration.client_id)
            try Task.checkCancellation()
            guard request == self.accountGeneration else { throw CancellationError() }
            try await Credentials.shared.save(String(decoding: JSONEncoder().encode(refreshed), as: UTF8.self), account: "oauth-session")
            try Task.checkCancellation()
            guard request == self.accountGeneration else { throw CancellationError() }
            self.tokens = refreshed
            return refreshed.accessToken
        }
        refreshTask = task
        defer { if request == accountGeneration { refreshTask = nil } }
        return try RailwayAPI(token: await task.value)
    }
    func restore() async {
        guard !restoring, !connected else { return }
        restoring = true
        defer { restoring = false }
        let request = accountGeneration
        do {
            if let saved = try await Credentials.shared.read(account: "oauth-session") {
                guard request == accountGeneration else { return }
                tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(saved.utf8))
                if let client = try await authorizedAPI() {
                    guard request == accountGeneration else { return }
                    api = client; connected = true; beginMonitoring(); await refresh()
                }
            } else if let token = try await Credentials.shared.read() {
                guard request == accountGeneration else { return }
                try await connect(token, save: false)
            }
        } catch { if request == accountGeneration { self.error = error.localizedDescription } }
    }
    func connect(_ token: String, save: Bool = true) async throws {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let request = accountGeneration
        let client = try RailwayAPI(token: token)
        let result = try await client.projects()
        guard accountGeneration == request else { throw CancellationError() }
        if save {
            try await Credentials.shared.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            try await Credentials.shared.delete(account: "oauth-session")
            tokens = nil
        }
        guard accountGeneration == request else { throw CancellationError() }
        accountGeneration = UUID()
        refreshTask?.cancel(); refreshTask = nil
        accountProfile = nil; accountProfileError = nil; loadingAccountProfile = false
        submittedPatchID = nil; submittedPatch = nil; submittedPatchError = nil; submittedPatchEnvironment = ""
        conversation.reset(environment: ""); inbox.reset(); terminal.disconnect()
        cloudTasks = []; cloudTaskError = nil
        api = client; connected = true; cloudPollDenied = false; updateProjects(result); error = nil
        try cache(); beginMonitoring()
    }
    func refresh() async {
        guard !busy, connected else { return }
        busy = true; defer { busy = false }
        let request = accountGeneration
        do {
            guard let client = try await authorizedAPI() else { return }
            let result = try await client.projects()
            guard accountGeneration == request else { return }
            updateProjects(result); try cache(); error = nil
            await loadCanvas()
        }
        catch { if request == accountGeneration, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func updateProjects(_ result: [Project]) {
        projects = result
        if !result.contains(where: { $0.id == projectID }) { projectID = nil }
    }
    private func cache() throws {
        let date = Date()
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Cache(date: date, projects: projects)).write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        cachedAt = date
    }
    func selectProject() {
        guard selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        pendingAgentThread = nil; pendingCloudMachine = nil; pendingTerminalTarget = nil; pendingTerminalLabel = ""
        generation = UUID(); canvasGeneration = UUID(); cloudTasks = []; cloudTaskError = nil; canvas = nil; deployments = []; logs = []; logDeployment = nil; serviceID = nil
        environmentID = project?.environments.nodes.first?.id ?? ""
    }
    func loadCanvas() async {
        let request = UUID(); canvasGeneration = request; canvas = nil; canvasLoading = false
        guard !environmentID.isEmpty else { return }
        canvasLoading = true
        defer { if canvasGeneration == request { canvasLoading = false } }
        do {
            guard let client = try await authorizedAPI() else { return }
            let result = try await client.canvas(environment: environmentID)
            guard canvasGeneration == request, !Task.isCancelled else { return }
            canvas = result
        } catch { if canvasGeneration == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func loadDeployments() async {
        let request = UUID(); generation = request; deployments = []; logs = []; logDeployment = nil
        guard let projectID, let serviceID, !environmentID.isEmpty else { return }
        do {
            guard let client = try await authorizedAPI() else { return }
            let result = try await client.deployments(project: projectID, environment: environmentID, service: serviceID)
            guard generation == request, !Task.isCancelled else { return }
            deployments = result
        } catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func loadLogs(_ deployment: Deployment) async {
        let request = UUID(); generation = request; logs = []; logDeployment = deployment
        do {
            guard let client = try await authorizedAPI() else { return }
            let result = try await client.logs(deployment: deployment.id)
            guard generation == request, !Task.isCancelled else { return }
            logs = result
        } catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func refreshLogs() async {
        guard let deployment = logDeployment else { return }
        let request = generation
        do {
            guard let api = try await authorizedAPI() else { return }
            let result = try await api.logs(deployment: deployment.id)
            guard generation == request, !Task.isCancelled, logDeployment?.id == deployment.id else { return }
            logs = result
        } catch { if generation == request, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func terminalToken() async throws -> String? { try await authorizedAPI()?.terminalAccessToken }
    func loadAccountProfile() async {
        guard connected, !loadingAccountProfile else { return }
        let request = accountGeneration
        loadingAccountProfile = true; accountProfileError = nil
        defer { if request == accountGeneration { loadingAccountProfile = false } }
        do {
            guard let client = try await authorizedAPI() else { throw OAuthFailure.expired }
            let result = try await client.accountProfile()
            guard request == accountGeneration, !Task.isCancelled else { return }
            accountProfile = result
        } catch {
            if request == accountGeneration, !Task.isCancelled { accountProfileError = error.localizedDescription }
        }
    }
    private func beginMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { await monitorNotifications() }
    }
    func refreshSubmittedPatch() async {
        guard let id = submittedPatchID else { return }
        let request = accountGeneration
        do {
            guard let client = try await authorizedAPI() else { throw OAuthFailure.expired }
            let result = try await client.environmentPatch(id)
            guard request == accountGeneration, submittedPatchID == id, !Task.isCancelled else { return }
            submittedPatch = result; submittedPatchError = nil
        } catch {
            if request == accountGeneration, submittedPatchID == id, !Task.isCancelled { submittedPatchError = error.localizedDescription }
        }
    }
    func monitorNotifications() async {
        var cycle = 0
        while !Task.isCancelled {
            if connected {
                if submittedPatchID != nil, submittedPatch?.finished != true { await refreshSubmittedPatch() }
                let request = accountGeneration
                let environment = environmentID
                do {
                    if let client = try await authorizedAPI() {
                        if cycle.isMultiple(of: 4) { await inbox.refresh(api: client) }
                        if !environment.isEmpty, !cloudPollDenied {
                            do {
                                let tasks = try await client.cloudTasks(environment: environment)
                                try Task.checkCancellation()
                                if request == accountGeneration, environment == environmentID { cloudTasks = tasks; cloudTaskError = nil }
                            } catch {
                                if request == accountGeneration, environment == environmentID {
                                    cloudTaskError = error.localizedDescription
                                    cloudPollDenied = (error as? RailwayError)?.isPermissionDenied == true
                                }
                            }
                        }
                    }
                } catch { if !Task.isCancelled, request == accountGeneration { inbox.error = error.localizedDescription } }
            }
            cycle += 1
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }
    func favorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func disconnect() async {
        submittedPatchID = nil; submittedPatch = nil; submittedPatchError = nil; submittedPatchEnvironment = ""
        accountProfile = nil; accountProfileError = nil; loadingAccountProfile = false
        conversation.reset(environment: ""); inbox.reset(); terminal.disconnect()
        pendingAgentThread = nil; pendingCloudMachine = nil; pendingTerminalTarget = nil; pendingTerminalLabel = ""
        tokens = nil; api = nil; connected = false; cloudTasks = []; cloudTaskError = nil; cloudPollDenied = false; generation = UUID()
        accountGeneration = UUID(); canvasGeneration = UUID(); canvas = nil
        refreshTask?.cancel(); refreshTask = nil
        monitorTask?.cancel(); monitorTask = nil
        do {
            try await Credentials.shared.delete(account: "oauth-session")
            try await Credentials.shared.delete()
            if FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }
            generation = UUID(); selectedProjectID = nil; api = nil; connected = false; projects = []; projectID = nil
            deployments = []; logs = []; logDeployment = nil; agentDraft = ""; cachedAt = nil
        } catch { self.error = error.localizedDescription }
    }
}
