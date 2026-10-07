import SwiftUI
import AppKit
import RailwayCore
import UniformTypeIdentifiers

struct ServiceCanvas: View {
    let project: Project
    let snapshot: CanvasSnapshot?
    let loading: Bool
    @Binding var selected: String?
    let inspect: () -> Void
    @State private var filter = ""
    @State private var zoom = 1.0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Architecture").font(.system(size: 13, weight: .semibold))
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                TextField("Filter services", text: $filter).textFieldStyle(.roundedBorder).frame(width: 190)
                Button("Zoom out", systemImage: "minus") { zoom = max(0.7, zoom - 0.1) }.labelStyle(.iconOnly)
                Text(zoom, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).frame(width: 38)
                Button("Zoom in", systemImage: "plus") { zoom = min(1.4, zoom + 0.1) }.labelStyle(.iconOnly)
                Button("Reset zoom") { zoom = 1 }.font(.caption)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            GeometryReader { geometry in
                let columns = max(2, Int((geometry.size.width - 96) / (300 * zoom)))
                let services = project.services.nodes.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                ScrollView([.horizontal, .vertical]) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(276 * zoom), spacing: 24 * zoom, alignment: .top), count: columns), alignment: .leading, spacing: 24 * zoom) {
                        ForEach(services) { service in
                            let detail = snapshot?.serviceInstances.nodes.first { $0.serviceId == service.id }
                            ServiceNode(name: service.name, detail: detail, volumes: snapshot?.volumes(for: service.id) ?? [], selected: selected == service.id, loading: loading) {
                                selected = service.id; inspect()
                            }.frame(width: 276).scaleEffect(zoom, anchor: .topLeading)
                                .frame(width: 276 * zoom, height: (148 + CGFloat(snapshot?.volumes(for: service.id).count ?? 0) * 38) * zoom, alignment: .topLeading)
                        }
                    }.padding(48)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                        .background {
                            Canvas { context, size in
                                let rowHeights: [CGFloat] = stride(from: 0, to: services.count, by: columns).map { start in
                                    let volumes = services[start..<min(start + columns, services.count)].map { snapshot?.volumes(for: $0.id).count ?? 0 }.max() ?? 0
                                    return CGFloat(148 + volumes * 38 + 24) * zoom
                                }
                                let positions = Dictionary(services.enumerated().map { index, service in
                                    (service.id, CGPoint(x: 48 + CGFloat(index % columns) * 300 * zoom + 138 * zoom, y: 48 + rowHeights.prefix(index / columns).reduce(0, +) + 74 * zoom))
                                }, uniquingKeysWith: { first, _ in first })
                                for link in snapshot?.dependencies ?? [] {
                                    guard let from = positions[link.source], let to = positions[link.target] else { continue }
                                    let direction: CGFloat = to.x >= from.x ? 1 : -1
                                    let start = CGPoint(x: from.x + 138 * zoom * direction, y: from.y)
                                    let end = CGPoint(x: to.x - 138 * zoom * direction, y: to.y)
                                    var path = Path(); path.move(to: start)
                                    path.addCurve(to: end, control1: CGPoint(x: start.x + 40 * direction, y: start.y), control2: CGPoint(x: end.x - 40 * direction, y: end.y))
                                    context.stroke(path, with: .color(RailwayTheme.accent.opacity(0.32)), lineWidth: 1.2)
                                }
                                for x in stride(from: 8.0, to: size.width, by: 22) {
                                    for y in stride(from: 8.0, to: size.height, by: 22) {
                                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.3, height: 1.3)), with: .color(.white.opacity(0.14)))
                                    }
                                }
                            }.background(Color(red: 18/255, green: 17/255, blue: 27/255))
                        }
                }
            }
        }
    }
}

private struct ServiceNode: View {
    let name: String
    let detail: ServiceSnapshot?
    let volumes: [String]
    let selected: Bool
    let loading: Bool
    let open: () -> Void
    @State private var hovered = false
    private var statusColor: Color {
        switch detail?.status {
        case "SUCCESS", "SLEEPING", "COMPLETED": Color(red: 0.39, green: 0.73, blue: 0.59)
        case "FAILED", "CRASHED": .red
        case "BUILDING", "DEPLOYING", "INITIALIZING": .orange
        default: .secondary
        }
    }
    private var statusIcon: String {
        switch detail?.status {
        case "SLEEPING": "moon.zzz"
        case "FAILED", "CRASHED": "exclamationmark.circle"
        case "BUILDING", "DEPLOYING", "INITIALIZING": "arrow.triangle.2.circlepath"
        case "COMPLETED": detail?.cronSchedule == nil ? "checkmark.circle" : "clock"
        default: "circle.inset.filled"
        }
    }
    var body: some View {
        Button(action: open) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        ServiceIcon(name: detail?.iconName).frame(width: 25, height: 25)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            if let domain = detail?.domain {
                                Text(domain).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Image(systemName: statusIcon).frame(width: 25)
                        Text(detail?.statusLabel ?? (loading ? "Loading…" : "Status unavailable")).font(.system(size: 12))
                        Spacer()
                        if detail?.failedLatest == true {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                .help("The latest deployment failed; an earlier deployment remains active.")
                        }
                        if let cron = detail?.cronSchedule { Image(systemName: "clock").help("Schedule: \(cron)\nNext run: \(detail?.nextCronRunAt ?? "Not reported")") }
                    }.foregroundStyle(statusColor)
                }.padding(22).frame(height: 148)
                ForEach(Array(volumes.enumerated()), id: \.offset) { _, volume in
                    Divider().overlay(.white.opacity(0.04))
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive").frame(width: 25)
                        Text(volume).lineLimit(1)
                        Spacer()
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 22).frame(height: 37).background(.white.opacity(0.018))
                }
            }.background(Color(red: 24/255, green: 23/255, blue: 34/255), in: .rect(cornerRadius: 13))
                .clipShape(.rect(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? RailwayTheme.accent : .white.opacity(hovered ? 0.3 : 0.13), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityLabel("\(name), \(detail?.statusLabel ?? "Status unavailable"). Inspect deployments")
    }
}
private struct ServiceIcon: View {
    let name: String?
    var body: some View {
        if let name, let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
                .accessibilityLabel(name)
        } else {
            Image(systemName: "shippingbox").font(.system(size: 22)).foregroundStyle(.secondary)
        }
    }
}

struct DeploymentView: View {
    @Bindable var workspace: Workspace
    let openAgent: (Deployment) -> Void
    let openLogs: (Deployment) -> Void
    @State private var pending: Deployment?
    @State private var rollback = false
    @State private var running = false
    @State private var diagnosis: String?
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Service", selection: $workspace.serviceID) {
                Text("Select a service").tag(String?.none)
                ForEach(workspace.project?.services.nodes ?? []) { Text($0.name).tag(Optional($0.id)) }
            }.frame(maxWidth: 320).padding(20)
            if workspace.deployments.isEmpty {
                ContentUnavailableView("No deployment history loaded", systemImage: "shippingbox", description: Text("Select a service while connected to load its recent deployments."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                    ForEach(workspace.deployments) { deployment in
                    HStack(spacing: 18) {
                        Circle().fill(statusColor(deployment.status)).frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(deployment.status.capitalized).font(.system(size: 13, weight: .semibold)).foregroundStyle(statusColor(deployment.status))
                            Text(String(deployment.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).help(deployment.id)
                        }
                        Spacer()
                        Text(formattedDate(deployment.createdAt)).font(.caption).foregroundStyle(.secondary).help(deployment.createdAt)
                        Button("Logs", systemImage: "text.alignleft") { openLogs(deployment) }.buttonStyle(.borderless).fixedSize()
                        Menu {
                            Button("Ask Agent for a fix") { openAgent(deployment) }
                            Button("Diagnosis") { diagnosis = deployment.diagnosis?.formatted ?? "Railway has not provided a diagnosis for this deployment." }
                            Button("Redeploy") { pending = deployment; rollback = false }.disabled(deployment.canRedeploy != true || running)
                            Button("Roll back") { pending = deployment; rollback = true }.disabled(deployment.canRollback != true || running)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 24, height: 24)
                        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Deployment actions")
                    }.padding(18)
                        .background(Color(red: 24/255, green: 23/255, blue: 34/255), in: .rect(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.09), lineWidth: 1))
                    }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .confirmationDialog(rollback ? "Roll back to this deployment?" : "Redeploy this deployment?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(rollback ? "Roll back" : "Redeploy") {
                guard let target = pending else { return }
                let rollingBack = rollback
                running = true
                Task {
                    defer { running = false }
                    do {
                        guard let api = try await workspace.authorizedAPI() else { return }
                        if rollingBack { try await api.rollback(target.id) }
                        else { _ = try await api.redeploy(target.id) }
                        await workspace.loadDeployments(); await workspace.loadCanvas()
                    } catch { workspace.error = "\(error.localizedDescription) Refresh deployment history before retrying; the request may have reached Railway." }
                }
            }
        } message: { Text("Deployment: \(pending?.id ?? "")\nThis changes the running service and can incur usage charges.") }
        .alert("Deployment diagnosis", isPresented: Binding(get: { diagnosis != nil }, set: { if !$0 { diagnosis = nil } })) {
            Button("Close") { diagnosis = nil }
        } message: { Text(diagnosis ?? "") }
    }
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "SUCCESS", "COMPLETED": .green
        case "FAILED", "CRASHED": .red
        case "BUILDING", "DEPLOYING", "INITIALIZING", "QUEUED": .orange
        default: .secondary
        }
    }
    private func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

struct LogView: View {
    let entries: [LogEntry]
    @State private var search = ""
    @State private var errorsOnly = false
    @State private var exporter = false
    @State private var exportError: String?
    var filtered: [LogEntry] { entries.filter { $0.matches(search, errorsOnly: errorsOnly) } }
    var rendered: String { filtered.map { [$0.timestamp, $0.severity ?? "", $0.message].filter { !$0.isEmpty }.joined(separator: "  ") }.joined(separator: "\n") }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search log messages", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Errors only", isOn: $errorsOnly)
                Text("\(filtered.count) / \(entries.count)").monospacedDigit().foregroundStyle(.secondary)
                Button("Copy", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(rendered, forType: .string) }
                Button("Export", systemImage: "square.and.arrow.up") { exporter = true }
            }.padding(14).modifier(GlassSurface(radius: 16)).padding(16)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No logs loaded", systemImage: "text.alignleft", description: Text("Open a deployment’s logs or import a text or JSON-lines file."))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(filtered.enumerated()), id: \.offset) { index, entry in
                            HStack(alignment: .top, spacing: 16) {
                                Text(String(index + 1)).foregroundStyle(.tertiary).frame(width: 45, alignment: .trailing)
                                Text(entry.timestamp).foregroundStyle(.secondary)
                                Text(entry.message).foregroundStyle(entry.matches("", errorsOnly: true) ? Color.red : Color.primary)
                            }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .padding(.vertical, 5).padding(.horizontal, 10)
                                .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.025) : .clear, in: .rect(cornerRadius: 6))
                        }
                    }.padding()
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: .rect(cornerRadius: 16)).padding(16)
            }
        }.fileExporter(isPresented: $exporter, document: LogDocument(text: rendered), contentType: .plainText, defaultFilename: "railway-logs") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }.alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}
struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
