import SwiftUI
import RailwayCore

@MainActor @Observable final class AgentConversation {
    var threads: [AgentThread] = []
    var threadID: String?
    var messages: [AgentMessage] = []
    var activity: [String] = []
    var error: String?
    var running = false
    var environmentID = ""
    private var stream: Task<Void, Never>?
    private var generation = UUID()
    func reset(environment: String) {
        generation = UUID()
        stream?.cancel(); stream = nil; running = false
        environmentID = environment; threadID = nil; messages = []; activity = []; threads = []; error = nil
    }
    func send(api: RailwayAPI, project: String, environment: String, service: String?, prompt: String) {
        guard !running else { return }
        running = true; error = nil; activity = []
        messages.append(AgentMessage(role: "user", content: prompt))
        let answer = AgentMessage(role: "assistant", content: "")
        messages.append(answer)
        let thread = threadID
        let request = generation
        stream = Task {
            defer { if request == generation { running = false } }
            do {
                try await api.chat(project: project, environment: environment, service: service, thread: thread, message: prompt) { event in
                    try await self.consume(event, answer: answer.id, environment: environment, request: request)
                }
                let result = try await api.threads(environment: environment)
                if request == generation, !Task.isCancelled { threads = result }
            } catch {
                if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private func consume(_ event: AgentEvent, answer: String, environment: String, request: UUID) throws {
        guard request == generation, environmentID == environment else { return }
        switch event.kind {
        case "metadata": threadID = event.text("threadId")
        case "chunk":
            if let index = messages.firstIndex(where: { $0.id == answer }) { messages[index].content += event.text("text") ?? "" }
        case "tool_call_ready": activity.append("\(event.text("toolName") ?? "Tool")\n\(event.data["args"]?.formatted ?? "")")
        case "tool_execution_complete": activity.append(event.data["result"]?.formatted ?? "Tool completed")
        case "error": throw RailwayError.api(event.text("error") ?? event.text("message") ?? "Agent failed")
        case "aborted": throw RailwayError.api(event.text("reason") ?? "Agent stopped")
        default: break
        }
    }
    func disconnectStream() {
        generation = UUID()
        stream?.cancel(); stream = nil; running = false
        error = "Disconnected locally. The agent may still be running. Reload history before sending again."
    }
}

struct AgentView: View {
    @Bindable var workspace: Workspace
    @Bindable var conversation: AgentConversation
    @State private var staged: StagedChanges?
    @State private var stagedEnvironment = ""
    @State private var showChanges = false
    @State private var applying = false
    @State private var confirmApply = false
    @State private var failed: [StagedChanges] = []
    @State private var recovering: StagedChanges?
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                HStack {
                    Text("Conversations").font(.headline)
                    Spacer()
                    Button("New", systemImage: "plus") { conversation.threadID = nil; conversation.messages = []; conversation.activity = [] }.labelStyle(.iconOnly).disabled(conversation.running)
                }.padding()
                List(conversation.threads, selection: $conversation.threadID) { thread in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(thread.title ?? "Untitled conversation").lineLimit(2)
                        Text(thread.updatedAt).font(.caption2).foregroundStyle(.secondary)
                    }.tag(thread.id)
                }.disabled(conversation.running).scrollContentBackground(.hidden)
                Button("Reload history") { Task { await history() } }.padding().disabled(conversation.running)
            }.frame(minWidth: 180, idealWidth: 230, maxWidth: 280)
            VStack(spacing: 0) {
                HStack {
                    Label("Railway Agent", systemImage: "sparkle").font(.headline)
                    Spacer()
                    Button("Staged changes") { Task { await loadChanges() } }
                }.padding()
                Divider()
                if let error = conversation.error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding() }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(conversation.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(message.role == "user" ? "You" : "Railway").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.content, forType: .string) }.labelStyle(.iconOnly)
                                    }
                                    Text(message.content.isEmpty ? "Working…" : message.content).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    if let parts = message.parts, !parts.isEmpty {
                                        DisclosureGroup("Message details") { ForEach(Array(parts.enumerated()), id: \.offset) { _, part in Text(part.formatted).font(.caption.monospaced()).textSelection(.enabled) } }
                                    }
                                }.padding(16).background(.white.opacity(message.role == "user" ? 0.06 : 0.025), in: .rect(cornerRadius: 14)).id(message.id)
                            }
                            if !conversation.activity.isEmpty {
                                DisclosureGroup("Agent activity (\(conversation.activity.count))") {
                                    ForEach(Array(conversation.activity.enumerated()), id: \.offset) { _, item in Text(item).font(.caption.monospaced()).textSelection(.enabled).padding(.vertical, 6) }
                                }
                            }
                        }.padding(20)
                    }.onChange(of: conversation.messages.count) { if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Ask about this environment or request infrastructure changes", text: $workspace.agentDraft, axis: .vertical).lineLimit(2...6).textFieldStyle(.plain)
                    if conversation.running {
                        ProgressView().controlSize(.small)
                        Button("Disconnect") { conversation.disconnectStream() }
                    } else {
                        Button("Send", systemImage: "arrow.up") { Task { await send() } }.disabled(!workspace.connected || workspace.agentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(18)
            }.frame(minWidth: 400)
        }
        .task(id: workspace.environmentID) {
            if conversation.environmentID != workspace.environmentID { conversation.reset(environment: workspace.environmentID) }
            await history()
            await openPendingThread()
        }
        .onChange(of: workspace.pendingAgentThread) { Task { await openPendingThread() } }
        .onChange(of: conversation.threadID) { if !conversation.running { Task { await messages() } } }
        .sheet(isPresented: $showChanges) { changesSheet }
    }
    private var changesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Staged infrastructure changes").font(.title2.bold())
            if workspace.submittedPatchID != nil {
                Text("Submitted patch: \(workspace.submittedPatch?.status ?? "Checking server status…")").font(.headline)
                if let error = workspace.submittedPatch?.lastAppliedError ?? workspace.submittedPatchError {
                    Text(error).foregroundStyle(.orange).textSelection(.enabled)
                }
                Button("Check submitted patch") { Task { await workspace.refreshSubmittedPatch() } }
            }
            if let staged {
                Text("Status: \(staged.status)").foregroundStyle(.secondary)
                if let error = staged.lastAppliedError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                ScrollView { Text(staged.patch.formatted).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Text("Applying changes can create resources, restart services, and incur charges.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Close") { showChanges = false }
                    Spacer()
                    Menu("Recover failed changes") {
                        ForEach(failed) { patch in
                            Button(patch.updatedAt + " · " + String(patch.id.prefix(8))) { recovering = patch }
                        }
                    }.disabled(failed.isEmpty || applying)
                    Button("Refresh") { Task { await loadChanges() } }
                    Button("Apply changes") { confirmApply = true }.disabled(applying || workspace.submittedPatchID != nil)
                }
            } else { Text("No staged changes loaded."); Button("Close") { showChanges = false } }
            if applying { ProgressView() }
        }.padding(24).frame(width: 650, height: 500)
        .confirmationDialog("Copy this failed patch back into staged changes?", isPresented: Binding(get: { recovering != nil }, set: { if !$0 { recovering = nil } }), titleVisibility: .visible) {
            if let patch = recovering { Button("Restage for review") { Task { await recover(patch) } } }
        } message: { Text("The failed record stays intact. Railway will copy its changes into the current staged patch. Review the combined result before applying.\n\(recovering?.lastAppliedError ?? "")") }
        .confirmationDialog("Apply these changes to \(workspace.project?.name ?? "project")?", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("Apply changes") { Task { await apply() } }
        } message: { Text("The app checks the staged patch again and submits exactly the reviewed changes. Failed requests are never retried automatically.") }
    }
    private func openPendingThread() async {
        guard let id = workspace.pendingAgentThread, !conversation.running else { return }
        await history()
        guard conversation.threads.contains(where: { $0.id == id }) else {
            conversation.error = "This conversation is not available in the selected environment."; workspace.pendingAgentThread = nil; return
        }
        conversation.threadID = id; workspace.pendingAgentThread = nil
    }
    private func history() async {
        let environment = workspace.environmentID
        let account = workspace.sessionID
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            let threads = try await api.threads(environment: environment)
            if account == workspace.sessionID, environment == workspace.environmentID, !Task.isCancelled { conversation.threads = threads }
        } catch { if account == workspace.sessionID, environment == workspace.environmentID, !Task.isCancelled { conversation.error = error.localizedDescription } }
    }
    private func messages() async {
        guard let thread = conversation.threadID else { return }
        let account = workspace.sessionID
        let environment = workspace.environmentID
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            let result = try await api.messages(thread: thread)
            if account == workspace.sessionID, environment == workspace.environmentID, conversation.threadID == thread, !conversation.running, !Task.isCancelled { conversation.messages = result; conversation.activity = [] }
        } catch { if account == workspace.sessionID, environment == workspace.environmentID, !Task.isCancelled { conversation.error = error.localizedDescription } }
    }
    private func send() async {
        guard let project = workspace.projectID else { return }
        let account = workspace.sessionID, environment = workspace.environmentID, service = workspace.serviceID, prompt = workspace.agentDraft
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID, project == workspace.projectID else { return }
            conversation.send(api: api, project: project, environment: environment, service: service, prompt: prompt)
            workspace.agentDraft = ""
        } catch { if account == workspace.sessionID, environment == workspace.environmentID { conversation.error = error.localizedDescription } }
    }
    private func loadChanges() async {
        let account = workspace.sessionID
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            let environment = workspace.environmentID
            let result = try await api.stagedChanges(environment: environment)
            guard account == workspace.sessionID, environment == workspace.environmentID else { return }
            if workspace.submittedPatch?.finished == true {
                workspace.submittedPatchID = nil; workspace.submittedPatch = nil; workspace.submittedPatchError = nil
            }
            staged = result; stagedEnvironment = environment; showChanges = true
            let failed = try await api.failedPatches(environment: environment)
            if account == workspace.sessionID, environment == workspace.environmentID { self.failed = failed }
        } catch { if account == workspace.sessionID { conversation.error = error.localizedDescription } }
    }
    private func recover(_ failed: StagedChanges) async {
        guard !applying, stagedEnvironment == workspace.environmentID else { return }
        let environment = stagedEnvironment
        let account = workspace.sessionID
        applying = true
        defer { applying = false }
        do {
            guard let api = try await workspace.authorizedAPI(), account == workspace.sessionID, environment == workspace.environmentID else { return }
            _ = try await api.restage(patch: failed.id)
            let result = try await api.stagedChanges(environment: environment)
            if account == workspace.sessionID, environment == workspace.environmentID { staged = result; recovering = nil }
        } catch { if account == workspace.sessionID { conversation.error = "\(error.localizedDescription) Refresh staged changes before retrying recovery."; showChanges = false } }
    }
    private func apply() async {
        guard !applying, let staged, stagedEnvironment == workspace.environmentID, workspace.submittedPatchID == nil else { return }
        let environment = workspace.environmentID
        let account = workspace.sessionID
        applying = true
        defer { applying = false }
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            let current = try await api.stagedChanges(environment: environment)
            guard account == workspace.sessionID, environment == workspace.environmentID else { return }
            guard current.id == staged.id, current.updatedAt == staged.updatedAt, current.patch == staged.patch else { throw RailwayError.api("Staged changes have changed. Refresh and review them again.") }
            let id = try await api.applyStaged(environment: environment, reviewedPatch: staged.patch)
            guard account == workspace.sessionID else { return }
            workspace.submittedPatchID = id; workspace.submittedPatchEnvironment = environment
            workspace.submittedPatch = nil; workspace.submittedPatchError = nil
            await workspace.refreshSubmittedPatch()
            await workspace.loadCanvas()
        } catch { if account == workspace.sessionID { conversation.error = "\(error.localizedDescription) Refresh staged changes to check the server state before retrying."; showChanges = false } }
    }
}
