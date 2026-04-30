import AppKit
import SwiftUI

@main
struct TransOnLocalApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra("TransOn Local", systemImage: "text.bubble") {
            MenuBarView()
                .environmentObject(controller)
                .task {
                    await controller.refreshStatus()
                }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .frame(width: 560, height: 520)
                .task {
                    await controller.refreshStatus()
                }
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

    private let helper = HelperClient()
    private let overlay = OverlayWindowController()
    private let hotKeyManager = HotKeyManager()

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
        runWork {
            _ = try await self.helper.prepareRuntime()
            self.status = try await self.helper.downloadModel(modelID: self.selectedModelID)
        }
    }

    func downloadSelectedModel() {
        runWork {
            self.status = try await self.helper.downloadModel(modelID: self.selectedModelID)
        }
    }

    func clearCache() {
        runWork {
            self.status = try await self.helper.clearCache()
        }
    }

    func translateSelectedText() {
        runWork {
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
            self.overlay.show(text: result.translatedText, targetLanguage: self.targetLanguage)
        }
    }

    private func runWork(_ operation: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil

        Task {
            do {
                try await operation()
            } catch {
                lastError = error.localizedDescription
                overlay.showError(error.localizedDescription)
            }
            isWorking = false
            await refreshStatus()
        }
    }

    private func configureHotKey() {
        let option = HotKeyCatalog.option(id: translationHotKeyID)
        hotKeyManager.configure(option: option) { [weak self] in
            self?.translateSelectedText()
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
