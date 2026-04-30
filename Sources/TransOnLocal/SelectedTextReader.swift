import AppKit

enum SelectedTextReader {
    static func readSelectedText() -> String? {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        sendCopyShortcut()
        waitForPasteboardChange(from: previousChangeCount)

        let selected = pasteboard.string(forType: .string)
        if let previousString {
            pasteboard.clearContents()
            pasteboard.setString(previousString, forType: .string)
        }

        return selected
    }

    private static func sendCopyShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private static func waitForPasteboardChange(from changeCount: Int) {
        let deadline = Date().addingTimeInterval(0.45)
        while NSPasteboard.general.changeCount == changeCount, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
    }
}
