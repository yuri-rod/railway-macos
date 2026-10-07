import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import RailwayCore

@main struct RailwayNativeApp: App {
    @State private var workspace = Workspace()
    init() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    var body: some Scene {
        Window("Railway", id: "workspace") {
            ZStack {
                DesktopView(workspace: workspace).id(workspace.sessionID)
            }
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .task {
                    UNUserNotificationCenter.current().delegate = workspace.inbox
                    await workspace.restore()
                }
        }
        .defaultSize(width: 1360, height: 880)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Railway") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "RailwayReleaseVersion") as? String ?? "Development build"
                    ])
                }
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Projects") { Task { await workspace.refresh() } }
                    .keyboardShortcut("r").disabled(!workspace.connected || workspace.busy)
            }
        }
        MenuBarExtra { WorkspaceMenu(workspace: workspace) } label: {
            Image(nsImage: RailwayMenuIcon.image).accessibilityLabel("Railway")
        }
        Settings { AccountView(workspace: workspace).id(workspace.sessionID).padding(28).frame(width: 440).tint(RailwayTheme.accent).preferredColorScheme(.dark) }
    }
}

struct DesktopView: View {
    @Bindable var workspace: Workspace
    @State private var search = ""
    @State private var account = false
    @State private var createProject = false
    @State private var tab = "Services"
    @State private var importLogs = false
    @State private var followLogs = false
    @State private var workspaceFilter: String?
    @State private var showInbox = false
    var filtered: [Project] {
        workspace.projects.filter { (workspaceFilter == nil || ($0.workspaceID ?? "shared") == workspaceFilter) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted {
                let a = workspace.favorites.contains($0.id), b = workspace.favorites.contains($1.id)
                return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a
            }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $workspace.projectID) {
                Button { workspace.projectID = nil; workspace.selectProject(); showInbox = false; workspaceFilter = nil; tab = "Services" } label: {
                    Label("Overview", systemImage: "square.grid.2x2").padding(.vertical, 6)
                }.buttonStyle(.plain)
                Section("Workspaces") {
                    ForEach(Array(Set(workspace.projects.map { $0.workspaceID ?? "shared" })).sorted(), id: \.self) { id in
                        Button {
                            workspaceFilter = id; workspace.projectID = nil; workspace.selectProject(); showInbox = false; tab = "Services"
                        } label: {
                            Label(workspace.projects.first { ($0.workspaceID ?? "shared") == id }?.workspaceName ?? "Shared projects", systemImage: "building.2")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                .foregroundStyle(workspaceFilter == id ? RailwayTheme.accent : Color.secondary)
                                .background {
                                    if workspaceFilter == id {
                                        RoundedRectangle(cornerRadius: 9).fill(RailwayTheme.accent.opacity(0.16))
                                            .shadow(color: RailwayTheme.accent.opacity(0.25), radius: 12)
                                    }
                                }
                        }.buttonStyle(.plain)
                    }
                }
                Section("Projects") {
                    ForEach(filtered) { project in
                        HStack(spacing: 11) {
                            Image(systemName: "square.stack.3d.up")
                            Text(project.name).font(.system(size: 13, weight: workspace.projectID == project.id ? .semibold : .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if workspace.favorites.contains(project.id) { Image(systemName: "star.fill").font(.system(size: 9)) }
                        }.padding(.vertical, 8).contentShape(Rectangle()).tag(project.id)
                            .foregroundStyle(workspace.projectID == project.id ? RailwayTheme.accent : Color.primary)
                            .listItemTint(RailwayTheme.accent)
                            .background {
                                if workspace.projectID == project.id {
                                    RoundedRectangle(cornerRadius: 9).fill(RailwayTheme.accent.opacity(0.16))
                                        .shadow(color: RailwayTheme.accent.opacity(0.25), radius: 12)
                                }
                            }
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button(workspace.favorites.contains(project.id) ? "Remove Favorite" : "Favorite") { workspace.favorite(project.id) }
                            }
                    }
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .background {
                SidebarMaterial().ignoresSafeArea()
                    .overlay(RailwayTheme.graphite.opacity(0.45).ignoresSafeArea()).allowsHitTesting(false)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        RailwayLogo(wordmark: true).frame(width: 112, height: 25)
                        Text("DESKTOP").font(.system(size: 9, weight: .medium)).tracking(1.8).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Create project", systemImage: "plus") { createProject = true }.labelStyle(.iconOnly).buttonStyle(.plain).disabled(!workspace.connected)
                }.padding(.horizontal, 24).padding(.vertical, 22)
            }
            .searchable(text: $search, prompt: "Find a project")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(workspace.connected ? "Connected" : (workspace.restoring ? "Restoring session…" : "Offline"), systemImage: workspace.connected ? "network" : "wifi.slash")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { account = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle").font(.system(size: 20)).foregroundStyle(.secondary)
                            Text("Account").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "gearshape").foregroundStyle(.secondary)
                        }.padding(12).background(.white.opacity(0.035), in: .rect(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            VStack(spacing: 0) {
                if let error = workspace.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                        Spacer()
                        Button("Account") { account = true }
                        Button("Dismiss") { workspace.error = nil }
                    }.padding().background(.orange.opacity(0.12))
                }
                if let project = workspace.project {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                if tab == "Services" {
                                    workspaceFilter = project.workspaceID ?? "shared"
                                    workspace.projectID = nil; workspace.selectProject(); showInbox = false
                                } else { tab = "Services" }
                            } label: {
                                Label(tab == "Services" ? "All projects" : "Back to workspace", systemImage: "chevron.left")
                                    .font(.callout).foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                            Text(project.name).font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-0.8)
                            if let description = project.description, !description.isEmpty {
                                Text(description).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("Environment", selection: $workspace.environmentID) {
                            ForEach(project.environments.nodes) { env in Text(env.name).tag(env.id) }
                        }.frame(width: 230)
                    }.padding(24)
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 28) {
                        ForEach(["Services", "Deployments", "Logs", "Metrics", "Variables", "Agent", "Cloud Agents", "Buckets", "Terminal", "Inbox"], id: \.self) { item in
                            Button { tab = item } label: {
                                Text(item)
                                    .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                                    .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                                    .padding(.vertical, 13)
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .bottom) {
                                        if tab == item {
                                            RoundedRectangle(cornerRadius: 1)
                                                .fill(RailwayTheme.accent).frame(height: 2)
                                        }
                                    }
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(tab == item ? .isSelected : [])
                        }
                        Spacer()
                    }.padding(.horizontal, 24) }.fixedSize(horizontal: false, vertical: true)
                    Divider()
                    if tab == "Services" {
                        ServiceCanvas(project: project, snapshot: workspace.canvas, loading: workspace.canvasLoading, selected: $workspace.serviceID) { tab = "Deployments" }
                    } else if tab == "Deployments" {
                        DeploymentView(workspace: workspace, openAgent: { deployment in
                            workspace.agentDraft = "Diagnose deployment \(deployment.id) for the selected service. Explain the failure and propose a fix for review before applying changes."
                            tab = "Agent"
                        }) { deployment in
                            tab = "Logs"
                            Task { await workspace.loadLogs(deployment) }
                        }
                    } else if tab == "Terminal" {
                        TerminalPanel(workspace: workspace, terminal: workspace.terminal)
                    } else if tab == "Buckets" {
                        BucketsView(workspace: workspace)
                    } else if tab == "Inbox" {
                        NotificationsView(workspace: workspace, inbox: workspace.inbox, inspect: inspectNotification)
                    } else if tab == "Cloud Agents" {
                        CloudAgentsView(workspace: workspace) { machine in
                            do {
                                guard let project = workspace.projectID else { return }
                                workspace.pendingTerminalTarget = try TerminalTarget(project: project, environment: workspace.environmentID, resource: machine.id, kind: .cloudAgent)
                                workspace.pendingTerminalLabel = "\(workspace.project?.name ?? project) / cloud agent / \(machine.name)"
                                tab = "Terminal"
                            } catch { workspace.error = error.localizedDescription }
                        }
                    } else if tab == "Agent" {
                        AgentView(workspace: workspace, conversation: workspace.conversation)
                    } else if tab == "Metrics" || tab == "Variables" {
                        ServiceOperationsView(workspace: workspace, section: tab)
                    } else {
                        VStack(spacing: 0) {
                            if workspace.logDeployment != nil {
                                HStack {
                                    Text("Deployment \(workspace.logDeployment?.id ?? "")").font(.caption.monospaced()).lineLimit(1)
                                    Spacer()
                                    Toggle("Follow logs", isOn: $followLogs)
                                    Button("Refresh logs") { Task { await workspace.refreshLogs() } }
                                }.padding(.horizontal, 24).padding(.top, 12)
                            }
                            LogView(entries: workspace.logs)
                        }.task(id: followLogs) {
                            guard followLogs else { return }
                            while !Task.isCancelled {
                                await workspace.refreshLogs()
                                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                            }
                        }
                    }
                } else if tab == "Logs" {
                    LogView(entries: workspace.logs)
                } else if workspace.connected {
                    if showInbox {
                        NotificationsView(workspace: workspace, inbox: workspace.inbox, inspect: inspectNotification)
                    } else {
                        WorkspaceOverview(workspace: workspace, projects: filtered, openProject: { id in
                            workspace.projectID = id; workspace.selectProject(); tab = "Services"
                        }, openInbox: { showInbox = true }, openAccount: { account = true })
                    }
                } else {
                    WelcomeWorkspace(signingIn: workspace.signingIn || workspace.restoring, connect: {
                        Task {
                            do { try await workspace.login() }
                            catch { workspace.error = error.localizedDescription }
                        }
                    }, openLogs: { importLogs = true })
                }
                HStack {
                    Text(workspace.connected ? "Railway" : "Offline workspace")
                    Spacer()
                    let runningTasks = workspace.cloudTasks.filter { ["PENDING", "QUEUED", "RUNNING", "WAITING"].contains($0.status) }.count
                    if runningTasks > 0 {
                        Button("\(runningTasks) agent tasks running") { tab = "Cloud Agents" }.buttonStyle(.plain)
                    }
                    if workspace.conversation.running { Button("Railway Agent is working") { tab = "Agent" }.buttonStyle(.plain) }
                    if workspace.busy { ProgressView().controlSize(.small) }
                    if let date = workspace.cachedAt { Text("Projects synced \(date.formatted(date: .abbreviated, time: .shortened))") }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12).background(.ultraThinMaterial)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { WorkspaceBackdrop() }
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .windowToolbar)
            .toolbar {
                Button("Open Logs", systemImage: "doc.text.magnifyingglass") { importLogs = true }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await workspace.refresh() } }
                    .disabled(!workspace.connected || workspace.busy)
            }
        }
        .tint(RailwayTheme.accent)
        .buttonBorderShape(.capsule)
        .onOpenURL { url in
            guard let route = ServiceRoute(url: url), workspace.projects.contains(where: { $0.id == route.project }) else { return }
            workspace.projectID = route.project
            workspace.selectProject()
            if let environment = route.environment, workspace.project?.environments.nodes.contains(where: { $0.id == environment }) == true { workspace.environmentID = environment }
            if let service = route.service, workspace.project?.services.nodes.contains(where: { $0.id == service }) == true { workspace.serviceID = service; tab = "Deployments" }
            if let agent = route.agent { workspace.pendingAgentThread = agent; tab = "Agent" }
            if let machine = route.cloudAgent { workspace.pendingCloudMachine = machine; tab = "Cloud Agents" }
        }
        .onChange(of: workspace.inbox.requestedID) {
            if let item = workspace.inbox.items.first(where: { $0.id == workspace.inbox.requestedID }) { inspectNotification(item) }
            else { tab = "Inbox"; showInbox = true }
        }
        .onChange(of: workspace.projectID) { workspace.selectProject(); if workspace.projectID != nil { showInbox = false } }
        .task(id: "\(workspace.projectID ?? "")/\(workspace.environmentID)/\(workspace.serviceID ?? "")") { await workspace.loadDeployments() }
        .task(id: workspace.environmentID) { await workspace.loadCanvas() }
        .sheet(isPresented: $createProject) { CreateProjectView(workspace: workspace) }
        .sheet(isPresented: $account) { AccountView(workspace: workspace).padding(28).frame(width: 480) }
        .fileImporter(isPresented: $importLogs, allowedContentTypes: [.plainText, .json, .data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
                workspace.logDeployment = nil; workspace.logs = LogEntry.parse(try String(contentsOf: url, encoding: .utf8)); tab = "Logs"
            } catch { workspace.error = error.localizedDescription }
        }
    }
    private func inspectNotification(_ item: RailwayNotification) {
        let incident = item.notificationInstance
        guard let project = incident.projectId, workspace.projects.contains(where: { $0.id == project }) else { workspace.error = "This notification belongs to a project outside the current grant."; return }
        workspace.projectID = project; workspace.selectProject()
        if let environment = incident.environmentId, workspace.project?.environments.nodes.contains(where: { $0.id == environment }) == true { workspace.environmentID = environment }
        workspace.serviceID = incident.serviceId
        tab = "Deployments"
    }
}

struct AccountView: View {
    @Bindable var workspace: Workspace
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var signingIn = false
    @State private var writeAccess = false
    @State private var manageAccess = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            RailwayLogo(wordmark: true).frame(width: 160, height: 36)
            Text(workspace.connected ? "Your account" : "Sign in to your workspace")
                .font(.title2.weight(.semibold))
            if workspace.connected {
                if let profile = workspace.accountProfile {
                    HStack(spacing: 14) {
                        Text(String(profile.displayName.prefix(1)).uppercased())
                            .font(.title2.weight(.semibold)).frame(width: 48, height: 48)
                            .background(RailwayTheme.accent.opacity(0.18), in: .circle)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(profile.displayName).font(.headline)
                            Text(profile.email).foregroundStyle(.secondary).textSelection(.enabled)
                            if let github = profile.githubUsername { Text("GitHub: \(github)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    LabeledContent("Authentication", value: workspace.authenticationMethod)
                    LabeledContent("Shared projects", value: String(workspace.projects.count))
                    if !profile.workspaces.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Workspaces").font(.caption).foregroundStyle(.secondary)
                            Text(profile.workspaces.map(\.name).joined(separator: ", ")).textSelection(.enabled)
                        }
                    }
                } else if workspace.loadingAccountProfile {
                    ProgressView("Loading account…")
                }
                if let error = workspace.accountProfileError {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Retry account details") { Task { await workspace.loadAccountProfile() } }
                }
                DisclosureGroup("Change account or shared access", isExpanded: $manageAccess) {
                    Text("Reauthorize only when you want to change the account, selected resources, or permissions.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            if !workspace.connected || manageAccess {
                Text("Sign in through Railway and choose the projects or workspaces to share. Your session is stored in Keychain.")
                    .foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Toggle("Allow service management (member access)", isOn: $writeAccess)
                Text("Member access enables logs, variables, deployments, and agent operations for only the resources you select on Railway.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    signingIn = true; error = nil
                    Task {
                        defer { signingIn = false }
                        do { try await workspace.login(writeAccess: writeAccess); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        RailwayLogo().frame(width: 20, height: 20)
                        Text(signingIn ? "Waiting for Railway…" : "Sign in with Railway")
                        Spacer()
                        if signingIn { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up.right") }
                    }.padding(14).background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14)))
                }.buttonStyle(.plain).disabled(signingIn || workspace.busy || workspace.restoring)
                if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                DisclosureGroup("Advanced: account API token") {
                    VStack(alignment: .leading, spacing: 12) {
                        SecureField("Account API token", text: $token).textFieldStyle(.roundedBorder)
                        Button("Connect with token") {
                            Task {
                                do { try await workspace.connect(token); token = ""; dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }.disabled(token.isEmpty || workspace.busy || signingIn)
                    }.padding(.top, 12)
                }.font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(signingIn)
                Spacer()
                if workspace.connected {
                    Button("Disconnect", role: .destructive) { Task { await workspace.disconnect(); dismiss() } }.disabled(signingIn)
                }
            }
        }.padding(4)
        }
        .frame(minHeight: 360, idealHeight: workspace.connected && !manageAccess ? 460 : 620, maxHeight: 620)
        .tint(RailwayTheme.accent)
            .task(id: workspace.connected) { await workspace.loadAccountProfile() }
    }
}

private struct WorkspaceMenu: View {
    @Bindable var workspace: Workspace
    @SwiftUI.Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(workspace.connected ? "Railway connected" : "Railway offline")
        Text("\(workspace.inbox.items.filter { $0.readAt == nil }.count) unread notifications")
        if workspace.conversation.running { Text("Railway Agent is working") }
        ForEach(workspace.cloudTasks.filter { ["PENDING", "QUEUED", "RUNNING", "WAITING"].contains($0.status) }.prefix(5)) { task in
            Text("\(task.status): \(task.promptPreview ?? "Cloud task")").lineLimit(1)
        }
        Divider()
        Button("Open Railway") { openWindow(id: "workspace"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
