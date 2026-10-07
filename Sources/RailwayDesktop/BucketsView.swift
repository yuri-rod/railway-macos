import SwiftUI
import RailwayCore
import ImageIO

struct BucketsView: View {
    @Bindable var workspace: Workspace
    @State private var buckets: [StorageBucket] = []
    @State private var selected: String?
    @State private var objects: [BucketObject] = []
    @State private var prefix = ""
    @State private var cursor: String?
    @State private var previewData: Data?
    @State private var previewName = ""
    @State private var reader: BucketReader?
    @State private var error: String?
    @State private var loading = false
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Bucket", selection: $selected) {
                    Text("Choose a bucket").tag(nil as String?)
                    ForEach(buckets) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 300)
                TextField("Object prefix", text: $prefix).textFieldStyle(.roundedBorder).onSubmit { Task { await load() } }
                Button("Search") { Task { await load() } }.disabled(loading || selected == nil)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if loading { ProgressView().controlSize(.small) }
            HSplitView {
                VStack {
                    List(objects) { object in
                        Button {
                            Task { await preview(object) }
                        } label: {
                            HStack {
                                Label(object.key, systemImage: "doc").lineLimit(2)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }.scrollContentBackground(.hidden)
                    if cursor != nil { Button("Load more") { Task { await load(more: true) } }.disabled(loading) }
                }.frame(minWidth: 320)
                VStack(alignment: .leading) {
                    Text(previewName.isEmpty ? "Object preview" : previewName).font(.headline).textSelection(.enabled)
                    if let data = previewData {
                        if let image = safeImage(data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let text = String(data: data, encoding: .utf8) {
                            ScrollView([.vertical, .horizontal]) { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding() }
                        } else { Text("This file type cannot be previewed as text or an image.").foregroundStyle(.secondary) }
                    } else { ContentUnavailableView("Select an object", systemImage: "doc.viewfinder", description: Text("Text and image previews are limited to 2 MB and remain in memory.")) }
                }.padding().frame(minWidth: 300)
            }
        }.padding(24)
        .task(id: "\(workspace.projectID ?? "")/\(workspace.environmentID)") {
            reader = nil; objects = []; buckets = []; selected = nil; previewData = nil; generation = UUID()
            let project = workspace.projectID
            do {
                guard let project, let api = try await workspace.authorizedAPI() else { return }
                let result = try await api.buckets(project: project)
                guard !Task.isCancelled, workspace.projectID == project else { return }
                buckets = result; selected = result.first?.id
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .task(id: selected) { await load() }
        .onDisappear { reader = nil; previewData = nil; generation = UUID() }
    }
    private func safeImage(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 20_000_000 else { return nil }
        return NSImage(data: data)
    }
    private func load(more: Bool = false) async {
        guard let project = workspace.projectID, let selected else { return }
        let environment = workspace.environmentID
        let request = UUID(); generation = request; loading = true; error = nil
        if !more { objects = []; cursor = nil; reader = nil; previewData = nil; previewName = "" }
        defer { if generation == request { loading = false } }
        do {
            guard let api = try await workspace.authorizedAPI() else { return }
            let credentials = try await api.bucketCredentials(project: project, environment: environment, bucket: selected)
            let reader = BucketReader(credentials: credentials)
            let page = try await reader.list(prefix: prefix, cursor: more ? cursor : nil)
            guard !Task.isCancelled, generation == request, self.selected == selected, workspace.environmentID == environment else { return }
            self.reader = reader; objects += page.objects; cursor = page.cursor
        } catch { if !Task.isCancelled, generation == request { self.error = error.localizedDescription } }
    }
    private func preview(_ object: BucketObject) async {
        guard let reader else { return }
        let request = generation
        previewName = object.key; previewData = nil
        guard object.size <= 2_000_000 else { error = "This object exceeds the 2 MB preview limit."; return }
        do {
            let data = try await reader.preview(key: object.key)
            if generation == request, previewName == object.key { previewData = data; error = nil }
        } catch { if generation == request { self.error = error.localizedDescription } }
    }
}
