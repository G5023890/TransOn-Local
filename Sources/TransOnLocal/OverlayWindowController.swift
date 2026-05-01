import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var panel: NSPanel?
    private let frameAutosaveName = "TransOnLocalTranslationOverlayFrame"

    func showLoading(targetLanguage: String) {
        showContent(OverlayView(state: .loading(targetLanguage: targetLanguage)), title: "TransOn Local")
    }

    func show(text: String, targetLanguage: String, duration: TimeInterval) {
        let title = "\(targetLanguage) (\(Self.formatDuration(duration)))"
        showContent(OverlayView(state: .result(text: text)), title: "TransOn Local - \(title)")
    }

    func showError(_ message: String) {
        showContent(OverlayView(state: .error(message)), title: "TransOn Local")
    }

    private func showContent(_ view: OverlayView, title: String) {
        let panel = makePanelIfNeeded()
        panel.title = title
        panel.contentView = NSHostingView(rootView: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel {
            return panel
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(560, visibleFrame.width - 48), height: 320)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 56
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "TransOn Local"
        panel.minSize = NSSize(width: 360, height: 220)
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameAutosaveName(frameAutosaveName)
        self.panel = panel
        return panel
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.1fs", duration)
        }

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m \(seconds)s"
    }
}

struct OverlayView: View {
    let state: OverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .loading(let targetLanguage):
                VStack(alignment: .center, spacing: 16) {
                    Text(targetLanguage)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView()
                        .controlSize(.large)
                    Text("Translating...")
                        .font(.headline)
                    Text("The local model is working on the selected text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .result(let text):
                ScrollView {
                    Text(text)
                        .font(.system(size: 17, weight: .regular, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                }

            case .error(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label("TransOn Local", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(message)
                        .font(.system(size: 17, weight: .regular, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(22)
        .background(.ultraThinMaterial)
    }
}

enum OverlayState {
    case loading(targetLanguage: String)
    case result(text: String)
    case error(String)
}
