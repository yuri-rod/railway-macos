import SwiftUI
import RailwayCore

struct CreateProjectView: View {
    @Bindable var workspace: Workspace
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var workspaces: [WorkspaceSummary] = []
    @State private var selected: String?
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create a project").font(.title2.bold())
            Picker("Workspace", selection: $selected) {
                Text("Choose a workspace").tag(nil as String?)
                ForEach(workspaces) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("Project name", text: $name).textFieldStyle(.roundedBorder)
            Text("The project will be private. You can ask Railway Agent to add services or deploy a template after creating it.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Button("Cancel") { dismiss() }.disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Review creation") { confirm = true }.disabled(busy || selected == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 460)
        .task {
            do { if let api = try await workspace.authorizedAPI() { workspaces = try await api.workspaces() } }
            catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Create \(name) in \(workspaces.first { $0.id == selected }?.name ?? "workspace")?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Create private project") {
                guard let selected else { return }
                let account = workspace.sessionID
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        guard let api = try await workspace.authorizedAPI() else { throw RailwayError.invalidToken }
                        guard account == workspace.sessionID else { return }
                        let id = try await api.createProject(workspace: selected, name: name)
                        guard account == workspace.sessionID else { return }
                        await workspace.refresh()
                        guard account == workspace.sessionID else { return }
                        workspace.projectID = id; workspace.selectProject(); dismiss()
                    } catch {
                        if account == workspace.sessionID { self.error = "\(error.localizedDescription) Refresh projects before retrying if the result is uncertain." }
                    }
                }
            }
        }
    }
}
