import SwiftUI
import WebKit
import RailwayCore

struct CloudAgentsView: View {
    @Bindable var workspace: Workspace
    let openTerminal: (CloudMachine) -> Void
    @State private var machines: [CloudMachine] = []
    @State private var tasks: [CloudTask] = []
    @State private var selected: String?
    @State private var session: String?
    @State private var prompt = ""
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var create = false
    @State private var confirmCreate = false
    @State private var preview: URL?
    @State private var requestKey = UUID().uuidString
    @State private var uncertain = false
    @State private var progress: CloudTaskProgress?
    @State private var responding: CloudTaskProgress.Interaction?
    @State private var responseAction: CloudInteractionAction?
    @AppStorage("archivedCloudSessions") private var archivedData = Data()
    @State private var showArchived = false
    @State private var statusFilter = "All"
    private var archived: Set<String> { Set((try? JSONDecoder().decode([String].self, from: archivedData)) ?? []) }
    private var archiveKey: String { "\(workspace.projectID ?? "")/\(workspace.environmentID)/\(selected ?? "")/\(session ?? "")" }
    private func isArchived(_ id: String) -> Bool { archived.contains("\(workspace.projectID ?? "")/\(workspace.environmentID)/\(selected ?? "")/\(id)") }
    private var machine: CloudMachine? { machines.first { $0.id == selected } }
    private var shownTasks: [CloudTask] { tasks.filter { $0.cloudAgentId == selected && (session == nil || $0.sessionId == session) }.sorted { $0.createdAt < $1.createdAt } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Cloud agents").font(.headline)
                    Spacer()
                    Button("Create", systemImage: "plus") { create = true }.labelStyle(.iconOnly).disabled(!workspace.connected)
                }.padding()
                Picker("Status", selection: $statusFilter) {
                    Text("All statuses").tag("All")
                    ForEach(Array(Set(machines.map(\.status))).sorted(), id: \.self) { Text($0).tag($0) }
                }.padding(.horizontal)
                List(selection: $selected) {
                    ForEach(machines.filter { statusFilter == "All" || $0.status == statusFilter }) { machine in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(machine.name).font(.headline)
                            Text("\(machine.status) · \(machine.region ?? "")").font(.caption).foregroundStyle(.secondary)
                            Text("\(machine.sessions.count) sessions").font(.caption2).foregroundStyle(.secondary)
                        }.tag(machine.id).padding(.vertical, 5)
                    }
                }.scrollContentBackground(.hidden)
                Button("Refresh") { Task { await refresh() } }.padding().disabled(busy)
            }.frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
            VStack(alignment: .leading, spacing: 0) {
                if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding() }
                if let machine {
                    HStack {
                        Text(machine.name).font(.title3.bold())
                        Spacer()
                        Button("Terminal") { openTerminal(machine) }
                        Menu("Preview") {
                            ForEach(machine.domains, id: \.domain) { domain in
                                Button("\(domain.domain) :\(domain.port)") {
                                    if let url = URL(string: "https://\(domain.domain)"), url.host == domain.domain, url.user == nil { preview = url }
                                }
                            }
                        }.disabled(machine.domains.isEmpty)
                        Button(machine.status == "SLEEPING" ? "Wake" : "Sleep") { Task { await lifecycle(machine) } }.disabled(busy)
                    }.padding()
                    Picker("Session", selection: $session) {
                        Text("New conversation").tag(nil as String?)
                        ForEach(machine.sessions.filter { showArchived || !isArchived($0.id) }) { Text("\($0.title ?? $0.id) · \($0.state)").tag(Optional($0.id)) }
                    }.padding(.horizontal).disabled(uncertain || busy)
                    HStack {
                        Toggle("Show archived", isOn: $showArchived)
                        Spacer()
                        if session != nil {
                            Button(archived.contains(archiveKey) ? "Restore in this app" : "Archive in this app") {
                                var values = archived
                                if values.contains(archiveKey) { values.remove(archiveKey) } else { values.insert(archiveKey) }
                                do { archivedData = try JSONEncoder().encode(Array(values)); session = nil }
                                catch { self.error = error.localizedDescription }
                            }.help("Organizes conversations locally. Running tasks continue on Railway.")
                        }
                    }.font(.caption).padding(.horizontal)
                    Divider().padding(.top)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            if let progress {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Current task: \(progress.status)").font(.headline)
                                    if let details = progress.progress {
                                        Text("\(details.steps) steps · \(details.tools.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                                        if let todos = details.todos { Text(todos.formatted).font(.caption).textSelection(.enabled) }
                                    }
                                    if let text = progress.text { Text(text).textSelection(.enabled) }
                                    ForEach(progress.pendingInteractions) { interaction in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(interaction.message ?? interaction.tool ?? "Agent needs your decision").font(.headline)
                                            if let summary = interaction.summary { Text(summary.formatted).font(.caption.monospaced()).textSelection(.enabled) }
                                            HStack {
                                                ForEach(interaction.actions, id: \.self) { action in
                                                    if let action = CloudInteractionAction(rawValue: action) {
                                                        Button(action.rawValue.capitalized) { responding = interaction; responseAction = action }.disabled(busy)
                                                    }
                                                }
                                            }
                                        }.padding().background(.orange.opacity(0.08), in: .rect(cornerRadius: 12))
                                    }
                                }
                            }
                            ForEach(shownTasks) { task in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Text(task.status).font(.caption.bold()); Spacer(); Text(task.createdAt).font(.caption).foregroundStyle(.secondary) }
                                    if let prompt = task.promptPreview { Text(prompt).font(.headline).textSelection(.enabled) }
                                    if let text = task.text { Text(text).textSelection(.enabled) }
                                    if let error = task.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.04), in: .rect(cornerRadius: 14))
                            }
                        }.padding()
                    }
                    HStack(alignment: .bottom) {
                        TextField("Instructions for this agent", text: $prompt, axis: .vertical).lineLimit(2...6).disabled(uncertain || busy)
                        Button(uncertain ? "Retry same request" : "Send") { Task { await send() } }.disabled(!workspace.connected || busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding()
                    if uncertain { Text("The last request may have reached Railway. Retry retains its idempotency key to prevent a duplicate task.").font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                } else {
                    ContentUnavailableView("Choose a cloud agent", systemImage: "cloud", description: Text("Create a machine or select one to see its sessions and execution progress."))
                }
            }.frame(minWidth: 300)
            if let preview {
                VStack(spacing: 0) {
                    HStack { Text(preview.host ?? "App preview").font(.caption); Spacer(); Button("Close preview") { self.preview = nil } }.padding()
                    AgentPreview(url: preview).id(preview)
                }.frame(minWidth: 250, idealWidth: 450)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: workspace.environmentID) {
            machines = []; tasks = []; selected = nil; session = nil; progress = nil; preview = nil
            prompt = ""; requestKey = UUID().uuidString; uncertain = false; error = nil
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: workspace.pendingCloudMachine) { Task { await refresh() } }
        .onChange(of: selected) { session = nil; prompt = ""; requestKey = UUID().uuidString; uncertain = false }
        .confirmationDialog("Send this decision to the agent?", isPresented: Binding(get: { responding != nil }, set: { if !$0 { responding = nil } }), titleVisibility: .visible) {
            if let interaction = responding, let action = responseAction {
                Button(action.rawValue.capitalized) { Task { await respond(interaction, action: action) } }
            }
        } message: { Text(responding?.message ?? "The agent may continue its requested operation after your approval.") }
        .sheet(isPresented: $create) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Create cloud agent").font(.title2.bold())
                TextField("Machine name", text: $name)
                Text("This provisions a Railway machine in the selected environment and can incur charges.").foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { create = false }
                    Spacer()
                    Button("Create machine") { confirmCreate = true }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }.padding(24).frame(width: 440)
            .confirmationDialog("Provision \(name)?", isPresented: $confirmCreate, titleVisibility: .visible) {
                Button("Create machine") { Task { await createMachine() } }
            }
        }
    }
    private func refresh() async {
        let account = workspace.sessionID
        let environment = workspace.environmentID
        guard !environment.isEmpty else { return }
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            async let machines = api.cloudMachines(environment: environment)
            async let tasks = api.cloudTasks(environment: environment)
            let machineResult = try await machines
            guard account == workspace.sessionID, !Task.isCancelled, environment == workspace.environmentID else { return }
            self.machines = machineResult
            if let pending = workspace.pendingCloudMachine {
                if machineResult.contains(where: { $0.id == pending }) { selected = pending }
                else { error = "This cloud agent is not available in the selected environment." }
                workspace.pendingCloudMachine = nil
            } else if selected == nil { selected = machineResult.first?.id }
            let taskResult = try await tasks
            guard account == workspace.sessionID, !Task.isCancelled, environment == workspace.environmentID else { return }
            self.tasks = taskResult
            if let task = taskResult.first(where: { $0.cloudAgentId == selected && $0.sessionId == session }), let machine = task.cloudAgentId, let session = task.sessionId {
                let detail = try await api.cloudTask(machine: machine, session: session, task: task.id)
                if account == workspace.sessionID, environment == workspace.environmentID, selected == machine, self.session == session { progress = detail }
            } else { progress = nil }
        } catch { if account == workspace.sessionID, !Task.isCancelled, environment == workspace.environmentID { self.error = error.localizedDescription } }
    }
    private func createMachine() async {
        guard !busy else { return }; busy = true
        let account = workspace.sessionID, environment = workspace.environmentID, machineName = name
        defer { busy = false; create = false }
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID else { return }
            let machine = try await api.createCloudMachine(environment: environment, name: machineName)
            guard account == workspace.sessionID, environment == workspace.environmentID else { return }
            selected = machine.id; name = ""; error = nil; await refresh()
        } catch { if account == workspace.sessionID, environment == workspace.environmentID { self.error = "\(error.localizedDescription) Refresh the machine list before retrying creation." } }
    }
    private func lifecycle(_ machine: CloudMachine) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let account = workspace.sessionID, environment = workspace.environmentID
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID else { return }
            _ = try await api.cloudLifecycle(id: machine.id, wake: machine.status == "SLEEPING")
            guard account == workspace.sessionID, environment == workspace.environmentID else { return }
            error = nil; await refresh()
        } catch { if account == workspace.sessionID, environment == workspace.environmentID { self.error = error.localizedDescription } }
    }
    private func respond(_ interaction: CloudTaskProgress.Interaction, action: CloudInteractionAction) async {
        guard !busy, let progress else { return }
        busy = true; defer { busy = false }
        let account = workspace.sessionID, environment = workspace.environmentID
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID else { return }
            let outcome = try await api.respondToCloudTask(task: progress.taskId, request: interaction.requestId, action: action)
            guard account == workspace.sessionID, environment == workspace.environmentID else { return }
            error = "Decision result: \(outcome)"; await refresh()
        } catch { if account == workspace.sessionID, environment == workspace.environmentID { self.error = error.localizedDescription } }
    }
    private func send() async {
        guard !busy, let selected, let project = workspace.projectID else { return }
        let account = workspace.sessionID, environment = workspace.environmentID
        let requestSession = session, requestPrompt = prompt, key = requestKey
        busy = true; defer { busy = false }
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID else { return }
            let handle = try await api.dispatchTask(project: project, environment: environment, machine: selected, session: requestSession, prompt: requestPrompt, idempotencyKey: key)
            guard account == workspace.sessionID, environment == workspace.environmentID, self.selected == selected else { return }
            session = handle.sessionId; prompt = ""; requestKey = UUID().uuidString; uncertain = false; error = nil
            await refresh()
        } catch {
            if account == workspace.sessionID, environment == workspace.environmentID, self.selected == selected { uncertain = true; self.error = error.localizedDescription }
        }
    }
}
private struct AgentPreview: NSViewRepresentable {
    let url: URL
    final class Navigation: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, url.scheme == "https", url.user == nil, url.password == nil else { return .cancel }
            return .allow
        }
    }
    func makeCoordinator() -> Navigation { Navigation() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url)); return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
