import AppKit
import SwiftUI

@main
struct TransOnLocalApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
                .task {
                    await controller.refreshStatus()
                }
        } label: {
            MenuBarLabel(isFileTranslation: controller.currentWork.isFileTranslation, spinnerFrame: controller.menuBarSpinnerFrame)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .frame(width: 560, height: 640)
                .task {
                    await controller.refreshStatus()
                }
        }
    }
}

struct MenuBarLabel: View {
    let isFileTranslation: Bool
    let spinnerFrame: Int

    var body: some View {
        if isFileTranslation {
            Image(systemName: "progress.indicator", variableValue: Double(spinnerFrame % 12) / 11.0)
                .id(spinnerFrame)
        } else {
            Image(systemName: "text.bubble")
        }
    }
}

@MainActor
final class AppController: ObservableObject {
    @AppStorage("targetLanguage") var targetLanguage: String = "Russian"
    @AppStorage("selectedModelID") var selectedModelID: String = ModelCatalog.defaultModel.id
    @AppStorage("autoDetectSource") var autoDetectSource: Bool = true
    @AppStorage("translationHotKeyID") var translationHotKeyID: String = HotKeyCatalog.defaultID {
        didSet {
            configureHotKey()
        }
    }

    @Published var status = LocalModelStatus.notLoaded
    @Published var isWorking = false
    @Published var lastError: String?
    @Published var lastResult: TranslationResult?
    @Published var currentWork: AppWork = .none
    @Published var menuBarSpinnerFrame = 0
    @Published var updateCheck = UpdateCheckResult.notChecked

    private let helper = HelperClient()
    private let overlay = OverlayWindowController()
    private let hotKeyManager = HotKeyManager()
    private var currentTask: Task<Void, Never>?
    private var menuBarSpinnerTimer: Timer?
    private var statusPollingTask: Task<Void, Never>?

    init() {
        configureHotKey()
    }

    func refreshStatus() async {
        do {
            status = try await helper.status()
            lastError = status.ready ? nil : status.detail
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func prepare() {
        runWork(.maintenance) {
            _ = try await self.helper.prepareRuntime()
            self.status = try await self.helper.downloadModel(modelID: self.selectedModelID)
        }
    }

    func downloadSelectedModel() {
        runWork(.maintenance) {
            self.status = try await self.helper.downloadModel(modelID: self.selectedModelID)
        }
    }

    func checkUpdates() {
        runWork(.maintenance) {
            self.updateCheck = try await self.helper.checkUpdates(modelID: self.selectedModelID)
        }
    }

    func repairModelMetadata() {
        runWork(.maintenance) {
            self.updateCheck = try await self.helper.repairModelMetadata(modelID: self.selectedModelID)
            self.status = try await self.helper.status()
        }
    }

    func updateSelectedModel() {
        runWork(.maintenance) {
            self.status = try await self.helper.updateModel(modelID: self.selectedModelID)
            self.updateCheck = try await self.helper.checkUpdates(modelID: self.selectedModelID)
        }
    }

    func clearCache() {
        runWork(.maintenance) {
            self.status = try await self.helper.clearCache()
            self.updateCheck = .notChecked
        }
    }

    func translateSelectedText() {
        runWork(.selectedText) {
            guard let selectedText = SelectedTextReader.readSelectedText(), !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.noSelectedText
            }

            self.overlay.showLoading(targetLanguage: self.targetLanguage)

            let request = TranslationRequest(
                text: selectedText,
                sourceLanguage: self.autoDetectSource ? nil : "Unknown",
                targetLanguage: self.targetLanguage
            )
            let result = try await self.helper.translate(request: request, modelID: self.selectedModelID)
            self.lastResult = result
            self.overlay.show(text: result.translatedText, targetLanguage: self.targetLanguage, duration: result.duration)
        }
    }

    func translateFile() {
        guard !isWorking else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose a file to translate"
        panel.prompt = "Translate"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = FileTranslationService.allowedContentTypes

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return
        }

        runWork(.file(fileURL)) {
            let document = try FileTranslationService.prepareDocument(from: fileURL, targetLanguage: self.targetLanguage)
            guard document.segments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw FileTranslationError.emptyFile(fileURL.lastPathComponent)
            }

            let start = Date()
            var translatedSegments: [String] = []
            translatedSegments.reserveCapacity(document.segments.count)

            for batch in FileTranslationBatch.make(segments: document.segments) {
                try Task.checkCancellation()
                let request = TranslationRequest(
                    text: batch.promptText,
                    sourceLanguage: self.autoDetectSource ? nil : "Unknown",
                    targetLanguage: self.targetLanguage
                )
                let result = try await self.helper.translate(request: request, modelID: self.selectedModelID)
                try Task.checkCancellation()
                if let batchSegments = batch.translatedSegments(from: result.translatedText) {
                    translatedSegments.append(contentsOf: batchSegments)
                } else {
                    for segment in batch.originalSegments {
                        try Task.checkCancellation()
                        let fallbackRequest = TranslationRequest(
                            text: segment,
                            sourceLanguage: self.autoDetectSource ? nil : "Unknown",
                            targetLanguage: self.targetLanguage
                        )
                        let fallbackResult = try await self.helper.translate(request: fallbackRequest, modelID: self.selectedModelID)
                        try Task.checkCancellation()
                        translatedSegments.append(fallbackResult.translatedText)
                    }
                }
            }

            try Task.checkCancellation()
            let rendered = try document.render(translatedSegments)
            try FileTranslationService.write(rendered, to: document.outputURL)
            let duration = Date().timeIntervalSince(start)
            self.overlay.showFileComplete(fileURL: document.outputURL, targetLanguage: self.targetLanguage, duration: duration)
            self.playSuccessSound()
        }
    }

    func cancelCurrentWork() {
        guard currentWork.isActive else { return }
        currentTask?.cancel()
    }

    private func runWork(_ work: AppWork, operation: @escaping @MainActor () async throws -> Void) {
        guard !currentWork.isActive else { return }
        currentWork = work
        updateMenuBarSpinner()
        startStatusPolling()
        isWorking = true
        lastError = nil

        let task = Task { @MainActor in
            do {
                try await operation()
            } catch is CancellationError {
                lastError = nil
                playCancelSound()
            } catch {
                lastError = error.localizedDescription
                playErrorSound()
                overlay.showError(error.localizedDescription, targetLanguage: targetLanguage, kind: work.overlayKind)
            }
            currentWork = .none
            updateMenuBarSpinner()
            stopStatusPolling()
            isWorking = false
            currentTask = nil
            await refreshStatus()
        }
        currentTask = task
    }

    private func configureHotKey() {
        let option = HotKeyCatalog.option(id: translationHotKeyID)
        hotKeyManager.configure(option: option) { [weak self] in
            self?.translateSelectedText()
        }
    }

    private func playSuccessSound() {
        (NSSound(named: "Glass") ?? NSSound(named: "Hero"))?.play()
    }

    private func playErrorSound() {
        (NSSound(named: "Basso") ?? NSSound(named: "Funk"))?.play()
    }

    private func playCancelSound() {
        (NSSound(named: "Pop") ?? NSSound(named: "Tink"))?.play()
    }

    private func updateMenuBarSpinner() {
        menuBarSpinnerTimer?.invalidate()
        menuBarSpinnerTimer = nil
        menuBarSpinnerFrame = 0

        guard currentWork.isFileTranslation else { return }
        menuBarSpinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.menuBarSpinnerFrame += 1
            }
        }
    }

    private func startStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard currentWork.isActive else { break }
                do {
                    status = try await helper.status()
                    if status.ready {
                        lastError = nil
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
    }

    private func stopStatusPolling() {
        statusPollingTask?.cancel()
        statusPollingTask = nil
    }
}

enum AppWork: Equatable {
    case none
    case selectedText
    case file(URL)
    case maintenance

    var isActive: Bool {
        self != .none
    }

    var isFileTranslation: Bool {
        if case .file = self {
            return true
        }
        return false
    }

    var overlayKind: OverlayWindowKind {
        switch self {
        case .file:
            return .file
        case .none, .selectedText, .maintenance:
            return .selectedText
        }
    }
}

enum AppError: LocalizedError {
    case noSelectedText

    var errorDescription: String? {
        switch self {
        case .noSelectedText:
            return "No selected text found. Select text in another app and try again."
        }
    }
}
