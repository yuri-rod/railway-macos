import SwiftUI
import Charts
import RailwayCore

struct ServiceOperationsView: View {
    @Bindable var workspace: Workspace
    let section: String
    @State private var hours = 1
    @State private var metrics: [MetricSeries] = []
    @State private var comparisonService: String?
    @State private var comparisonMetrics: [MetricSeries] = []
    private var serviceName: String { workspace.project?.services.nodes.first { $0.id == workspace.serviceID }?.name ?? "Selected service" }
    private var comparisonName: String { workspace.project?.services.nodes.first { $0.id == comparisonService }?.name ?? "Comparison service" }
    @State private var variables: [String: String] = [:]
    @State private var loading = false
    @State private var failure: String?
    @State private var reveal = false
    @State private var name = ""
    @State private var value = ""
    @State private var confirmSave = false
    @State private var saving = false
    private var identity: String { "\(workspace.sessionID)/\(workspace.projectID ?? "")/\(workspace.environmentID)/\(workspace.serviceID ?? "")/\(section)/\(hours)/\(comparisonService ?? "")" }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Picker("Service", selection: $workspace.serviceID) {
                    Text("Choose a service").tag(nil as String?)
                    ForEach(workspace.project?.services.nodes ?? []) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 320)
                Spacer()
                if section == "Metrics" {
                    Picker("Compare", selection: $comparisonService) {
                        Text("No comparison").tag(nil as String?)
                        ForEach((workspace.project?.services.nodes ?? []).filter { $0.id != workspace.serviceID }) {
                            Text($0.name).tag(Optional($0.id))
                        }
                    }.frame(maxWidth: 220)
                    Picker("Range", selection: $hours) {
                        Text("Last hour").tag(1)
                        Text("Last 6 hours").tag(6)
                        Text("Last 24 hours").tag(24)
                        Text("Last 7 days").tag(168)
                        Text("Last 30 days").tag(720)
                    }.frame(width: 180)
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }.disabled(loading || saving)
            }
            if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if workspace.serviceID == nil {
                ContentUnavailableView("Choose a service", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if section == "Metrics" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 20) {
                        ForEach(metrics) { series in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(title(series.measurement)).font(.headline)
                                let comparison = comparisonMetrics.first { $0.measurement == series.measurement }
                                if series.values.isEmpty && (comparison?.values.isEmpty ?? true) {
                                    Text("No samples in this range").foregroundStyle(.secondary).frame(height: 160)
                                } else {
                                    Chart {
                                        ForEach(Array(series.values.enumerated()), id: \.offset) { _, point in
                                            LineMark(x: .value("Time", point.date), y: .value("Usage", point.value))
                                                .foregroundStyle(by: .value("Service", serviceName))
                                        }
                                        ForEach(Array((comparison?.values ?? []).enumerated()), id: \.offset) { _, point in
                                            LineMark(x: .value("Time", point.date), y: .value("Usage", point.value))
                                                .foregroundStyle(by: .value("Service", comparisonName))
                                        }
                                    }.chartForegroundStyleScale(domain: [serviceName, comparisonName], range: [RailwayTheme.accent, Color.cyan])
                                        .frame(height: 160)
                                    if let latest = series.values.last { Text("\(serviceName): \(latest.value.formatted(.number.precision(.fractionLength(0...4))))").font(.caption).foregroundStyle(.secondary) }
                                    if let latest = comparison?.values.last { Text("\(comparisonName): \(latest.value.formatted(.number.precision(.fractionLength(0...4))))").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(20).background(.white.opacity(0.035), in: .rect(cornerRadius: 16))
                        }
                    }
                    if metrics.isEmpty { ContentUnavailableView("No metric samples", systemImage: "chart.xyaxis.line") }
                }
            } else {
                HStack {
                    Text("Service variables").font(.headline)
                    Spacer()
                    Toggle("Reveal values", isOn: $reveal).toggleStyle(.switch)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(variables.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top) {
                                Text(key).font(.system(.body, design: .monospaced)).frame(width: 240, alignment: .leading).textSelection(.enabled)
                                Text(reveal ? variables[key, default: ""] : "••••••••").font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Button("Edit") { name = key; value = variables[key, default: ""] }
                            }.padding(.vertical, 12)
                            Divider()
                        }
                    }
                }
                Divider()
                Text("Save a variable").font(.headline)
                HStack {
                    TextField("Name", text: $name).frame(width: 240)
                    SecureField("Value", text: $value)
                    Button(saving ? "Saving…" : "Review save") { confirmSave = true }
                        .disabled(!workspace.connected || name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }.textFieldStyle(.roundedBorder)
                Text("Values stay in memory. Saving does not trigger a deployment. Your Railway role and OAuth grant must permit writes.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: identity) {
            if let comparisonService, comparisonService == workspace.serviceID || workspace.project?.services.nodes.contains(where: { $0.id == comparisonService }) != true {
                self.comparisonService = nil
            } else { await load() }
        }
        .onDisappear { variables = [:]; value = ""; reveal = false }
        .confirmationDialog("Save \(name) to this service?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save variable") { Task { await save() } }
        } message: {
            Text("Project: \(workspace.project?.name ?? "")\nEnvironment: \(workspace.project?.environments.nodes.first { $0.id == workspace.environmentID }?.name ?? "")\nService: \(workspace.project?.services.nodes.first { $0.id == workspace.serviceID }?.name ?? "")\nAn existing value will be replaced. No deployment will be started.")
        }
    }
    private func title(_ measurement: String) -> String {
        switch measurement {
        case "CPU_USAGE": "CPU (cores)"
        case "MEMORY_USAGE_GB": "Memory (GB)"
        case "NETWORK_RX_GB": "Network received (GB)"
        case "NETWORK_TX_GB": "Network sent (GB)"
        default: measurement
        }
    }
    private func load() async {
        let request = identity
        loading = false; variables = [:]; metrics = []; comparisonMetrics = []; reveal = false; value = ""; name = ""; failure = nil
        guard let project = workspace.projectID, let service = workspace.serviceID, !workspace.environmentID.isEmpty else { return }
        let environment = workspace.environmentID
        loading = true
        defer { if request == identity { loading = false } }
        do {
            guard let api = try await workspace.authorizedAPI() else { throw RailwayError.invalidToken }
            if section == "Metrics" {
                let since = Date().addingTimeInterval(-Double(hours) * 3600)
                let result = try await api.metrics(environment: environment, service: service, since: since)
                guard !Task.isCancelled, request == identity else { return }
                metrics = result
                if let comparisonService {
                    let comparison = try await api.metrics(environment: environment, service: comparisonService, since: since)
                    guard !Task.isCancelled, request == identity else { return }
                    comparisonMetrics = comparison
                }
            } else {
                let result = try await api.variables(project: project, environment: environment, service: service)
                guard !Task.isCancelled, request == identity else { return }
                variables = result
            }
        } catch { if !Task.isCancelled, request == identity { failure = error.localizedDescription } }
    }
    private func save() async {
        guard !saving, let project = workspace.projectID, let service = workspace.serviceID else { return }
        let request = identity
        let environment = workspace.environmentID
        let variableName = name, variableValue = value
        saving = true
        defer { saving = false }
        do {
            guard let api = try await workspace.authorizedAPI() else { throw RailwayError.invalidToken }
            guard request == identity else { return }
            try await api.setVariable(project: project, environment: environment, service: service, name: variableName, value: variableValue)
            guard request == identity else { return }
            await load()
        } catch { if request == identity { failure = error.localizedDescription } }
    }
}
