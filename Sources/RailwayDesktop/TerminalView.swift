import SwiftUI
import AppKit
import RailwayCore
import TerminalProcess
import Darwin

@MainActor @Observable final class SSHTerminal {
    var screen = TerminalScreen()
    var status = "Disconnected"
    var targetLabel = ""
    var active = false
    var persistent = false
    var automaticallyReconnect = true
    var reconnecting = false
    var closing: Bool { pid > 0 && !active }
    private var sessionPersistent = false
    private var descriptor: Int32 = -1
    private var pid: Int32 = -1
    private var reader: DispatchSourceRead?
    private var watcher: DispatchSourceProcess?
    private var retry: Task<Void, Never>?
    private var retryGeneration = UUID()
    private var policy = TerminalReconnect()
    private var target: TerminalTarget?
    private var auth: String?
    private var tokenProvider: (@MainActor () async throws -> String?)?
    private var authenticationFailed = false
    private var recentOutput = TerminalOutput()
    private var output = Data()
    private var writer: DispatchSourceWrite?
    func connect(target: TerminalTarget, token: String, label: String, tokenProvider: @escaping @MainActor () async throws -> String?) throws {
        guard pid < 0 else { throw RailwayError.api("Disconnect the current terminal first.") }
        cancelReconnect()
        self.target = target; targetLabel = label; auth = token; self.tokenProvider = tokenProvider; sessionPersistent = persistent; policy.connected()
        screen = TerminalScreen(rows: screen.rows, columns: screen.columns)
        do { try launch() }
        catch { auth = nil; self.tokenProvider = nil; throw error }
    }
    private func launch() throws {
        guard let target, let auth else { throw RailwayError.invalidToken }
        let candidates = ["/opt/homebrew/bin/railway", "/usr/local/bin/railway"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw RailwayError.api("Install the Railway CLI before opening SSH terminals.") }
        let arguments = [executable] + target.arguments(persistent: sessionPersistent)
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "RAILWAY_API_TOKEN": auth]
        for key in ["USER", "LOGNAME", "TMPDIR", "SSH_AUTH_SOCK"] { environment[key] = inherited[key] }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var fd: Int32 = -1
        let child = executable.withCString { path in
            argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    railway_terminal_start(path, args.baseAddress, env.baseAddress, Int32(screen.rows), Int32(screen.columns), &fd)
                }
            }
        }
        guard child > 0 else { throw RailwayError.api("Could not start the SSH pseudoterminal: \(String(cString: strerror(errno)))") }
        descriptor = fd; pid = child; active = true; authenticationFailed = false; recentOutput = TerminalOutput(); status = "Connecting"
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } }
        reader = source; source.resume()
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        exit.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.exited(child) } }
        watcher = exit; exit.resume()
    }
    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 32_768)
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                let recent = recentOutput.append(data).lowercased()
                if ["permission denied", "host key verification failed", "remote host identification has changed", "not authorized", "unauthorized"].contains(where: { recent.contains($0) }) {
                    authenticationFailed = true; status = "Authentication or host verification failed"
                } else { status = "Session running" }
                for response in screen.feed(data) { send(response) }
            } else {
                if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EIO { status = "Terminal read failed: \(String(cString: strerror(errno)))" }
                break
            }
        }
    }
    func send(_ data: Data) {
        guard descriptor >= 0 else { return }
        guard output.count + data.count <= 1_000_000 else { status = "Terminal input exceeds the 1 MB buffer limit."; return }
        output.append(data); flushInput()
        if !output.isEmpty, writer == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flushInput() } }
            writer = source; source.resume()
        }
    }
    private func flushInput() {
        guard descriptor >= 0 else { return }
        while !output.isEmpty {
            let count = output.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { output.removeFirst(count) }
            else {
                if count < 0, errno == EINTR { continue }
                if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                    status = "Terminal write failed: \(String(cString: strerror(errno)))"
                    output = Data()
                }
                break
            }
        }
        if output.isEmpty { writer?.cancel(); writer = nil }
    }
    func resize(rows: Int, columns: Int) {
        guard rows != screen.rows || columns != screen.columns else { return }
        screen.resize(rows: rows, columns: columns)
        if descriptor >= 0, railway_terminal_resize(descriptor, Int32(screen.rows), Int32(screen.columns)) != 0 { status = "Could not resize the remote terminal." }
    }
    private func closeDescriptor() {
        reader?.cancel(); reader = nil; writer?.cancel(); writer = nil; output = Data()
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    private func exited(_ child: Int32) {
        guard child == pid else { return }
        readAvailable()
        let code = railway_terminal_status(child)
        watcher?.cancel(); watcher = nil; closeDescriptor(); pid = -1; active = false
        if !authenticationFailed, automaticallyReconnect, let delay = policy.nextDelay(exitCode: Int32(code), persistent: sessionPersistent) {
            status = "Disconnected. Reconnecting in \(Int(delay)) seconds"
            reconnecting = true
            let request = retryGeneration
            retry = Task {
                defer { if request == retryGeneration { reconnecting = false; retry = nil } }
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard automaticallyReconnect else { return }
                    guard let tokenProvider, let refreshed = try await tokenProvider() else { throw RailwayError.invalidToken }
                    try Task.checkCancellation(); auth = refreshed; try launch()
                }
                catch { if !Task.isCancelled { auth = nil; status = error.localizedDescription } }
            }
        } else {
            status = policy.stopped ? "Disconnected" : (authenticationFailed ? "Authentication or host verification failed. Reconnect manually after resolving it." : "Session ended (\(code))")
            auth = nil
        }
    }
    private func cancelReconnect() {
        retryGeneration = UUID()
        retry?.cancel(); retry = nil; reconnecting = false
    }
    func disconnect() {
        policy.stop(); cancelReconnect(); auth = nil; tokenProvider = nil
        if pid > 0 { kill(-pid, SIGHUP) }
        closeDescriptor(); active = false; status = "Disconnected"
    }
}

struct TerminalPanel: View {
    @Bindable var workspace: Workspace
    @Bindable var terminal: SSHTerminal
    @State private var confirm = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Service", selection: $workspace.serviceID) {
                    Text("Choose a service").tag(nil as String?)
                    ForEach(workspace.project?.services.nodes ?? []) { Text($0.name).tag(Optional($0.id)) }
                }.frame(width: 260).disabled(terminal.active || terminal.reconnecting || workspace.pendingTerminalTarget != nil)
                Toggle("Persistent session", isOn: $terminal.persistent).disabled(terminal.active || terminal.reconnecting || terminal.closing)
                Toggle("Reconnect", isOn: $terminal.automaticallyReconnect)
                Spacer()
                if terminal.active || terminal.reconnecting { Button("Disconnect") { terminal.disconnect() } }
                else {
                    if workspace.pendingTerminalTarget != nil { Button("Use selected service") { workspace.pendingTerminalTarget = nil } }
                    Button("Connect") { confirm = true }.disabled((workspace.serviceID == nil && workspace.pendingTerminalTarget == nil) || !workspace.connected || terminal.closing)
                }
            }.padding(16)
            if !terminal.targetLabel.isEmpty {
                Text("Remote target: \(terminal.targetLabel)").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error { Text(error).foregroundStyle(.orange).padding(.horizontal) }
            NativeTerminal(terminal: terminal).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if !terminal.active, terminal.screen.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView("SSH terminal", systemImage: "terminal", description: Text("Choose a service and connect. Cloud-agent terminals open from the Cloud Agents tab.")).allowsHitTesting(false)
                    }
                }
            HStack {
                Text(terminal.status).font(.caption)
                if terminal.screen.outputTruncated { Text("Oversized character output truncated").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Copy screen") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(terminal.screen.text, forType: .string) }
                Button("Copy scrollback") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString((terminal.screen.scrollback + [terminal.screen.text]).joined(separator: "\n"), forType: .string) }
            }.padding(12)
        }
        .onChange(of: terminal.automaticallyReconnect) {
            if !terminal.automaticallyReconnect, terminal.reconnecting { terminal.disconnect() }
        }
        .task(id: workspace.pendingTerminalTarget?.resource) { if workspace.pendingTerminalTarget != nil { confirm = true } }
        .confirmationDialog("Open SSH to this target?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Connect") {
                Task {
                    let account = workspace.sessionID
                    do {
                        let target: TerminalTarget
                        let label: String
                        if let pending = workspace.pendingTerminalTarget {
                            target = pending; label = workspace.pendingTerminalLabel
                        } else {
                            guard let project = workspace.projectID, let service = workspace.serviceID else { return }
                            target = try TerminalTarget(project: project, environment: workspace.environmentID, service: service)
                            label = "\(workspace.project?.name ?? project) / \(workspace.project?.environments.nodes.first { $0.id == workspace.environmentID }?.name ?? workspace.environmentID) / \(workspace.project?.services.nodes.first { $0.id == service }?.name ?? service)"
                        }
                        guard let token = try await workspace.terminalToken() else { throw RailwayError.invalidToken }
                        guard workspace.sessionID == account, workspace.connected else { return }
                        try terminal.connect(target: target, token: token, label: label, tokenProvider: { [weak workspace = workspace] in
                            guard let workspace, workspace.sessionID == account, workspace.connected else { throw RailwayError.invalidToken }
                            let token = try await workspace.terminalToken()
                            guard workspace.sessionID == account, workspace.connected else { throw RailwayError.invalidToken }
                            return token
                        }); error = nil
                    } catch { if workspace.sessionID == account { self.error = error.localizedDescription } }
                }
            }
        } message: {
            Text((workspace.pendingTerminalTarget != nil ? workspace.pendingTerminalLabel + "\n" : "") + (terminal.persistent ? "Railway CLI will create a persistent tmux session, installing tmux in the service if needed. Reconnect will reuse this same session. SSH host verification remains enabled." : "Railway CLI will open an interactive shell in the selected service. Commands run directly on that service."))
        }
    }
}
private struct NativeTerminal: NSViewRepresentable {
    let terminal: SSHTerminal
    func makeNSView(context: Context) -> TerminalDrawing { TerminalDrawing(terminal: terminal) }
    func updateNSView(_ view: TerminalDrawing, context: Context) {
        _ = terminal.screen.cells
        view.setAccessibilityValue(terminal.screen.text)
        view.needsDisplay = true
    }
}
private final class TerminalDrawing: NSView {
    let terminal: SSHTerminal
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let cellWidth: CGFloat = 8
    private let cellHeight: CGFloat = 18
    init(terminal: SSHTerminal) { self.terminal = terminal; super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.textArea); setAccessibilityLabel("SSH terminal") }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        terminal.resize(rows: max(2, Int((bounds.height - 16) / cellHeight)), columns: max(2, Int((bounds.width - 16) / cellWidth)))
    }
    private func color(_ rgb: UInt32) -> NSColor { NSColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1) }
    override func draw(_ dirtyRect: NSRect) {
        color(0x12111B).setFill(); bounds.fill()
        for (row, cells) in terminal.screen.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                let rect = NSRect(x: 8 + CGFloat(column) * cellWidth, y: 8 + CGFloat(row) * cellHeight, width: cellWidth, height: cellHeight)
                guard rect.intersects(dirtyRect) else { continue }
                color(cell.inverse ? cell.foreground : cell.background).setFill(); rect.fill()
            }
        }
        for (row, cells) in terminal.screen.cells.enumerated() {
            for (column, cell) in cells.enumerated() {
                let rect = NSRect(x: 8 + CGFloat(column) * cellWidth, y: 8 + CGFloat(row) * cellHeight, width: cellWidth * 2, height: cellHeight)
                guard rect.intersects(dirtyRect) else { continue }
                (cell.text as NSString).draw(at: rect.origin, withAttributes: [.font: cell.bold ? NSFont.monospacedSystemFont(ofSize: 13, weight: .bold) : font, .foregroundColor: color(cell.inverse ? cell.background : cell.foreground)])
            }
        }
        if terminal.screen.cursorVisible, window?.firstResponder === self {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: NSRect(x: 8 + CGFloat(terminal.screen.column) * cellWidth, y: 8 + CGFloat(terminal.screen.row) * cellHeight, width: cellWidth, height: cellHeight)).stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", let text = NSPasteboard.general.string(forType: .string) {
                let value = terminal.screen.bracketedPaste ? "\u{1B}[200~\(text)\u{1B}[201~" : text
                terminal.send(Data(value.utf8))
            } else if event.charactersIgnoringModifiers == "c" {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(terminal.screen.text, forType: .string)
            } else { super.keyDown(with: event) }
            return
        }
        let prefix = terminal.screen.applicationCursor ? "\u{1B}O" : "\u{1B}["
        let keys: [UInt16: String] = [123: prefix + "D", 124: prefix + "C", 125: prefix + "B", 126: prefix + "A", 115: "\u{1B}[H", 119: "\u{1B}[F", 116: "\u{1B}[5~", 121: "\u{1B}[6~", 117: "\u{1B}[3~", 51: "\u{7F}", 36: "\r", 48: event.modifierFlags.contains(.shift) ? "\u{1B}[Z" : "\t", 53: "\u{1B}", 122: "\u{1B}OP", 120: "\u{1B}OQ", 99: "\u{1B}OR", 118: "\u{1B}OS", 96: "\u{1B}[15~", 97: "\u{1B}[17~", 98: "\u{1B}[18~", 100: "\u{1B}[19~", 101: "\u{1B}[20~", 109: "\u{1B}[21~"]
        if let key = keys[event.keyCode] { terminal.send(Data(key.utf8)); return }
        if event.modifierFlags.contains(.control), let scalar = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first, (64...95).contains(scalar.value) { terminal.send(Data([UInt8(scalar.value - 64)])); return }
        if let text = event.characters { terminal.send(Data((event.modifierFlags.contains(.option) ? "\u{1B}" + text : text).utf8)) }
    }
}
