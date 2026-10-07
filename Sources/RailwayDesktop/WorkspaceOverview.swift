import SwiftUI
import RailwayCore

struct WorkspaceOverview: View {
    @Bindable var workspace: Workspace
    let projects: [Project]
    let openProject: (String) -> Void
    let openInbox: () -> Void
    let openAccount: () -> Void
    private var unread: [RailwayNotification] { workspace.inbox.items.filter { $0.readAt == nil } }
    private var alerts: Int { unread.filter { ["ERROR", "CRITICAL", "WARNING", "HIGH"].contains($0.notificationInstance.severity.uppercased()) }.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(workspace.accountProfile.map { "Hello, " + $0.displayName + "!" } ?? "Hello!")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                        Text(workspace.inbox.error != nil ? "Notifications are unavailable with the current access." : unread.isEmpty ? "Your workspace is ready." : "Some activity needs your attention.").font(.title3)
                        Button(action: openInbox) {
                            HStack(spacing: 8) {
                                if workspace.inbox.error != nil {
                                    Text("Review notification access").foregroundStyle(RailwayTheme.accent)
                                } else {
                                    Text("\(alerts) alerts").foregroundStyle(.orange)
                                    Text("\(unread.count - alerts) notices").foregroundStyle(RailwayTheme.accent)
                                }
                                Image(systemName: "arrow.up.right")
                            }
                        }.buttonStyle(.plain)
                        if let error = workspace.inbox.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button(action: openAccount) { Label("Account", systemImage: "person.crop.circle") }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).modifier(GlassSurface(radius: 20))
                HStack {
                    Text("Choose a project").font(.title2.weight(.semibold))
                    Text(String(projects.count)).foregroundStyle(.secondary)
                    Spacer()
                }
                if projects.isEmpty {
                    ContentUnavailableView("No shared projects", systemImage: "folder", description: Text("Use Account to change the projects or workspaces shared with Railway."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], spacing: 20) {
                    ForEach(projects) { project in
                        Button { openProject(project.id) } label: {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack {
                                    Image(systemName: "square.stack.3d.up").foregroundStyle(RailwayTheme.accent)
                                    Text(project.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                                }
                                Text(project.workspaceName ?? "Shared projects").font(.caption).foregroundStyle(.secondary)
                                if let description = project.description, !description.isEmpty { Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                                Divider()
                                HStack {
                                    Label("\(project.services.nodes.count) services", systemImage: "server.rack")
                                    Spacer()
                                    Text("\(project.environments.nodes.count) environments")
                                }.font(.caption).foregroundStyle(.secondary)
                            }.padding(22).frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                                .background(.white.opacity(0.035), in: .rect(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WelcomeBackdrop() }
            .task { await workspace.loadAccountProfile() }
    }
}
