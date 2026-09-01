import AppKit
import SwiftUI

enum SessionState {
    case idle
    case connected
    case ended
}

/// SF Symbols 用法对齐 HIG：工具栏/列表用轮廓，选中与状态用填充，多层符号用 hierarchical。
enum AnnyIcon {
    static let host = "server.rack"
    static let add = "plus"
    static let edit = "pencil"
    static let remove = "minus"
    static let metrics = "chart.bar"
    static let terminal = "terminal"
    static let refresh = "arrow.clockwise"
    static let reconnect = "arrow.triangle.2.circlepath"
    static let disconnect = "xmark"
    static let cpu = "cpu"
    static let memory = "memorychip"
    static let disk = "internaldrive"
    static let network = "network"
    static let fetch = "arrow.down.circle"
    static let keyboard = "keyboard"
    static let status = "circle.fill"
    static let ssh = "cable.connector"
    static let user = "person"
    static let password = "key"
    static let system = "desktopcomputer"
    static let distro = "square.stack"
    static let version = "number"
    static let kernel = "gearshape"
}

enum Theme {
    static func portDigits(_ port: Int) -> String {
        String(port)
    }

    static func cleanedPort(_ raw: String) -> String {
        raw.filter(\.isNumber)
    }

    static func parsePort(_ raw: String) -> Int? {
        let t = cleanedPort(raw)
        if t.isEmpty { return 22 }
        guard let n = Int(t), (1...65535).contains(n) else { return nil }
        return n
    }

    static func diskLevel(_ percent: String) -> Double {
        Double(percent.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    static func usageColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }
}

struct AnnySymbol: View {
    let name: String
    var font: Font = .body

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(font)
            .imageScale(.medium)
    }
}

struct PortField: View {
    @Binding var text: String

    var body: some View {
        TextField("22", text: $text)
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .onChange(of: text) { _, newValue in
                let cleaned = Theme.cleanedPort(newValue)
                if cleaned != newValue { text = cleaned }
            }
    }
}

struct AnnyAtmosphere: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [
                    Color(red: 0.42, green: 0.56, blue: 0.86).opacity(0.42),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
            RadialGradient(
                colors: [
                    Color(red: 0.58, green: 0.44, blue: 0.78).opacity(0.28),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.92, y: 0.18),
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color(red: 0.36, green: 0.72, blue: 0.78).opacity(0.16),
                    Color.clear,
                ],
                center: UnitPoint(x: 0.55, y: 1.05),
                startRadius: 10,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct AnnyGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .padding(padding)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .padding(padding)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

struct AnnyGlassCluster<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

private struct AnnyGlassButtonStyle: PrimitiveButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label
                }
                .buttonStyle(.glassProminent)
            } else {
                Button(role: configuration.role, action: configuration.trigger) {
                    configuration.label
                }
                .buttonStyle(.glass)
            }
        } else if prominent {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label
            }
            .buttonStyle(.bordered)
        }
    }
}

extension View {
    func cardBackground() -> some View {
        modifier(AnnyGlassSurface())
    }

    func annyGlass(prominent: Bool = false) -> some View {
        buttonStyle(AnnyGlassButtonStyle(prominent: prominent))
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    var range: ClosedRange<CGFloat> = 160...520
    @State private var dragOrigin: CGFloat?

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = width }
                    let next = (dragOrigin ?? width) + value.translation.width
                    width = min(max(next, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    dragOrigin = nil
                }
        )
        .help("拖动调整名单宽度")
    }
}

struct AnnyWindowChrome: NSViewRepresentable {
    var title: String
    var subtitle: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.title = title
            window.subtitle = subtitle
        }
    }
}
