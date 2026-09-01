import AppKit
import SwiftTerm
import SwiftUI

struct SSHTerminalView: NSViewRepresentable {
    let host: WatchedHost
    @Binding var running: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(host: host, running: $running)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        Self.applyPalette(view)
        view.processDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.host = host
        context.coordinator.running = $running
        DispatchQueue.main.async {
            context.coordinator.startIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
        coordinator.running.wrappedValue = false
    }

    /// One Dark 16 色，ls / git / prompt 的 ANSI 会按这个着色。
    private static func applyPalette(_ view: LocalProcessTerminalView) {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }
        func term(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
        }

        view.nativeBackgroundColor = rgb(40, 44, 52)
        view.nativeForegroundColor = rgb(171, 178, 191)
        view.caretColor = rgb(97, 175, 239)
        view.caretTextColor = rgb(40, 44, 52)
        view.selectedTextBackgroundColor = rgb(62, 68, 81)
        view.useBrightColors = true
        view.installColors([
            term(0x28, 0x2c, 0x34),
            term(0xe0, 0x6c, 0x75),
            term(0x98, 0xc3, 0x79),
            term(0xe5, 0xc0, 0x7b),
            term(0x61, 0xaf, 0xef),
            term(0xc6, 0x78, 0xdd),
            term(0x56, 0xb6, 0xc2),
            term(0xab, 0xb2, 0xbf),
            term(0x5c, 0x63, 0x70),
            term(0xe0, 0x6c, 0x75),
            term(0x98, 0xc3, 0x79),
            term(0xe5, 0xc0, 0x7b),
            term(0x61, 0xaf, 0xef),
            term(0xc6, 0x78, 0xdd),
            term(0x56, 0xb6, 0xc2),
            term(0xff, 0xff, 0xff),
        ])
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var host: WatchedHost
        var running: Binding<Bool>
        private weak var terminal: LocalProcessTerminalView?
        private var started = false

        init(host: WatchedHost, running: Binding<Bool>) {
            self.host = host
            self.running = running
        }

        func attach(_ view: LocalProcessTerminalView) {
            terminal = view
        }

        func startIfNeeded() {
            guard !started, let terminal else { return }
            guard terminal.bounds.width > 40, terminal.bounds.height > 40 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.startIfNeeded()
                }
                return
            }
            started = true
            running.wrappedValue = true
            terminal.startProcess(
                executable: TerminalService.sshExecutable,
                args: TerminalService.sshArguments(host),
                environment: TerminalService.processEnvironment(),
                execName: "ssh",
                currentDirectory: NSHomeDirectory()
            )
            DispatchQueue.main.async {
                terminal.window?.makeFirstResponder(terminal)
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            started = false
            DispatchQueue.main.async {
                self.running.wrappedValue = false
            }
        }
    }
}
