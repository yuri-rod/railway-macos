import SwiftUI

enum RailwayTheme {
    static let accent = Color(red: 0.65, green: 0.40, blue: 0.96)
    static let graphite = Color(red: 16/255, green: 15/255, blue: 19/255)
}

struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                scheme == .dark ? RailwayTheme.graphite : Color(nsColor: .windowBackgroundColor)
                if !reduceTransparency {
                    Ellipse().fill(RailwayTheme.accent.opacity(scheme == .dark ? 0.055 : 0.025))
                        .frame(width: geometry.size.width * 0.8, height: 440)
                        .blur(radius: 110).offset(x: 180, y: -240)
                    Ellipse().fill(RailwayTheme.accent.opacity(scheme == .dark ? 0.025 : 0.015))
                        .frame(width: 520, height: 440)
                        .blur(radius: 100).offset(x: -300, y: 260)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WelcomeBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            if let url = Bundle.main.url(forResource: "WelcomeBackground", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(Color.black.opacity(0.5))
                    .overlay(LinearGradient(colors: [.clear, RailwayTheme.graphite.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            } else { RailwayTheme.graphite }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 20
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content.background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: radius))
            } else if #available(macOS 26, *) {
                content.glassEffect(.regular, in: .rect(cornerRadius: radius))
            } else {
                content.background(.regularMaterial, in: .rect(cornerRadius: radius))
                    .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.16), lineWidth: 0.5))
            }
        }.shadow(color: .black.opacity(0.07), radius: 20, x: 0, y: 10)
    }
}

struct RailwayLogo: View {
    var wordmark = false
    var body: some View {
        if let url = Bundle.main.url(forResource: wordmark ? "RailwayWordmark" : "RailwayMark", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("Railway")
        } else {
            Label("Railway", systemImage: "tram.fill")
        }
    }
}

enum RailwayMenuIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        guard let url = Bundle.main.url(forResource: "RailwayMark", withExtension: "pdf"),
              let source = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Railway") ?? NSImage(size: size)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct WelcomeWorkspace: View {
    let signingIn: Bool
    let connect: () -> Void
    let openLogs: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    RailwayLogo().frame(width: 72, height: 72)
                    VStack(spacing: 12) {
                        Text("Welcome to Railway").font(.system(size: 32, weight: .semibold)).tracking(-1)
                        Text("Your infrastructure. A native workspace.")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 20) {
                        Button(action: connect) {
                            HStack(spacing: 12) {
                                RailwayLogo().frame(width: 21, height: 21)
                                Text(signingIn ? "Waiting for Railway…" : "Sign in with Railway").fontWeight(.semibold)
                                Spacer()
                                if signingIn { ProgressView().controlSize(.small) }
                                else { Image(systemName: "arrow.up.right") }
                            }.padding(.horizontal, 20).frame(height: 52)
                                .background(Color.white.opacity(0.1), in: .rect(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.16)))
                        }.buttonStyle(.plain).disabled(signingIn)
                        Text("Continue securely in your browser. Choose which workspaces this app can access.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                        Divider()
                        Button(action: openLogs) {
                            Label("Open logs without signing in", systemImage: "doc.text.magnifyingglass")
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }.padding(28).modifier(GlassSurface(radius: 22))
                    Text("Independent macOS client for Railway")
                        .font(.caption).foregroundStyle(.tertiary)
                }.frame(width: 420).padding(40)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }.background { WelcomeBackdrop() }
    }
}

struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
