import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private var selectedTextPanel: NSPanel?
    private var filePanel: NSPanel?
    private let frameAutosaveName = "TransOnLocalTranslationOverlayFrame"

    func showLoading(targetLanguage: String) {
        showContent(
            OverlayView(state: .loading(targetLanguage: targetLanguage)),
            title: selectedTextTitle(targetLanguage: targetLanguage, suffix: "Translating"),
            kind: .selectedText
        )
    }

    func show(text: String, targetLanguage: String, duration: TimeInterval) {
        showContent(
            OverlayView(state: .result(text: text)),
            title: selectedTextTitle(targetLanguage: targetLanguage, suffix: Self.formatDuration(duration)),
            kind: .selectedText
        )
    }

    func showError(_ message: String, targetLanguage: String, kind: OverlayWindowKind = .selectedText) {
        showContent(
            OverlayView(state: .error(message)),
            title: title(targetLanguage: targetLanguage, suffix: "Error"),
            kind: kind
        )
    }

    func showFileComplete(fileURL: URL, targetLanguage: String, duration: TimeInterval) {
        showContent(
            OverlayView(state: .fileComplete(fileURL, duration: Self.formatDuration(duration))),
            title: title(targetLanguage: targetLanguage, suffix: "File translated"),
            kind: .file
        )
    }

    private func showContent(_ view: OverlayView, title: String, kind: OverlayWindowKind) {
        let panel = makePanelIfNeeded(kind: kind)
        panel.title = title
        panel.contentView = NSHostingView(rootView: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanelIfNeeded(kind: OverlayWindowKind) -> NSPanel {
        switch kind {
        case .selectedText:
            if let selectedTextPanel {
                return selectedTextPanel
            }
        case .file:
            if let filePanel {
                return filePanel
            }
        }

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = kind.defaultSize(visibleFrame: visibleFrame)
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 56
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: kind.styleMask,
            backing: .buffered,
            defer: false
        )
        panel.title = "TransOn Local"
        panel.minSize = kind.minSize
        if let maxSize = kind.maxSize {
            panel.maxSize = maxSize
        }
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if kind == .selectedText {
            panel.setFrameAutosaveName(frameAutosaveName)
            selectedTextPanel = panel
        } else {
            filePanel = panel
        }
        return panel
    }

    private func selectedTextTitle(targetLanguage: String, suffix: String) -> String {
        title(targetLanguage: targetLanguage, suffix: suffix)
    }

    private func title(targetLanguage: String, suffix: String) -> String {
        "TransOn Local - \(targetLanguage) - \(suffix)"
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

enum OverlayWindowKind {
    case selectedText
    case file

    var styleMask: NSWindow.StyleMask {
        switch self {
        case .selectedText:
            return [.titled, .fullSizeContentView, .nonactivatingPanel, .closable, .resizable]
        case .file:
            return [.titled, .fullSizeContentView, .nonactivatingPanel, .closable]
        }
    }

    var minSize: NSSize {
        switch self {
        case .selectedText:
            return NSSize(width: 360, height: 220)
        case .file:
            return NSSize(width: 520, height: 220)
        }
    }

    var maxSize: NSSize? {
        switch self {
        case .selectedText:
            return nil
        case .file:
            return NSSize(width: 520, height: 220)
        }
    }

    func defaultSize(visibleFrame: NSRect) -> NSSize {
        switch self {
        case .selectedText:
            return NSSize(width: min(560, visibleFrame.width - 48), height: 320)
        case .file:
            return NSSize(width: min(520, visibleFrame.width - 48), height: 220)
        }
    }
}

struct OverlayView: View {
    let state: OverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .loading:
                VStack(alignment: .center, spacing: 16) {
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

            case .fileComplete(let fileURL, let duration):
                VStack(alignment: .leading, spacing: 12) {
                    Label("File Translation Complete", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Label("Time spent: \(duration)", systemImage: "timer")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 17, weight: .semibold, design: .default))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(fileURL.deletingLastPathComponent().path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
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
    case fileComplete(URL, duration: String)
}
