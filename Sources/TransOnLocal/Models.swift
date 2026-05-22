import Foundation
import Carbon

struct LocalModelStatus: Codable, Equatable {
    let ready: Bool
    let summary: String
    let detail: String
    let modelPath: String?
    let modelBytes: Int64
    let llamaCliPath: String?
    let downloadProgress: DownloadProgress?

    static let notLoaded = LocalModelStatus(
        ready: false,
        summary: "Checking local runtime",
        detail: "TransOn Local has not contacted the helper yet.",
        modelPath: nil,
        modelBytes: 0,
        llamaCliPath: nil,
        downloadProgress: nil
    )

    static func failed(_ message: String) -> LocalModelStatus {
        LocalModelStatus(
            ready: false,
            summary: "Local helper unavailable",
            detail: message,
            modelPath: nil,
            modelBytes: 0,
            llamaCliPath: nil,
            downloadProgress: nil
        )
    }
}

struct DownloadProgress: Codable, Equatable {
    let modelID: String
    let modelName: String
    let fileName: String
    let fileIndex: Int
    let fileCount: Int
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let fileDownloadedBytes: Int64
    let fileTotalBytes: Int64?
    let startedAt: Date
    let updatedAt: Date
    let phase: DownloadPhase
    let error: String?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    var speedBytesPerSecond: Double {
        let elapsed = max(0.1, updatedAt.timeIntervalSince(startedAt))
        return Double(downloadedBytes) / elapsed
    }
}

enum DownloadPhase: String, Codable, Equatable {
    case preparing
    case downloading
    case finishing
    case complete
    case failed
}

struct TranslationRequest: Codable {
    let text: String
    let sourceLanguage: String?
    let targetLanguage: String
}

struct TranslationResult: Codable {
    let translatedText: String
    let detectedSourceLanguage: String?
    let duration: Double
    let error: String?
}

struct UpdateCheckResult: Codable, Equatable {
    let checkedAt: Date
    let model: UpdateComponentStatus
    let runtime: UpdateComponentStatus
    let modelCatalog: UpdateComponentStatus
    let prompts: UpdateComponentStatus
    let performanceProfiles: UpdateComponentStatus

    static let notChecked = UpdateCheckResult(
        checkedAt: .distantPast,
        model: UpdateComponentStatus(component: .model, status: .unknown, summary: "Not checked", detail: "Run Check Updates to compare the selected model with remote metadata."),
        runtime: UpdateComponentStatus(component: .runtime, status: .unknown, summary: "Not checked", detail: "Runtime version checks are reserved for the next update-center pass."),
        modelCatalog: UpdateComponentStatus(component: .modelCatalog, status: .unknown, summary: "Static catalog", detail: "The model catalog is bundled with this app version."),
        prompts: UpdateComponentStatus(component: .prompts, status: .unknown, summary: "Bundled prompts", detail: "Prompt updates will be tracked later."),
        performanceProfiles: UpdateComponentStatus(component: .performanceProfiles, status: .unknown, summary: "Bundled profiles", detail: "Performance profile updates will be tracked later.")
    )
}

struct UpdateComponentStatus: Codable, Equatable {
    let component: UpdateComponent
    let status: UpdateStatus
    let summary: String
    let detail: String
}

enum UpdateComponent: String, Codable, Equatable {
    case model
    case runtime
    case modelCatalog
    case prompts
    case performanceProfiles
}

enum UpdateStatus: String, Codable, Equatable {
    case upToDate
    case updateAvailable
    case notDownloaded
    case unknown
    case checkFailed
}

struct HelperResponse: Codable {
    let ok: Bool
    let status: LocalModelStatus
    let result: TranslationResult?
    let updates: UpdateCheckResult?
    let error: String?
}

enum HelperAction: String, Codable {
    case status
    case prepareRuntime
    case downloadModel
    case checkUpdates
    case updateModel
    case translate
    case clearCache
}

struct HelperRequest: Codable {
    let action: HelperAction
    let modelID: String?
    let translation: TranslationRequest?
}

struct ModelCatalogEntry: Identifiable, Hashable {
    let id: String
    let displayName: String
    let quant: String
    let sizeGB: Double
    let note: String
    let license: String
}

enum ModelCatalog {
    static let models: [ModelCatalogEntry] = [
        ModelCatalogEntry(id: "qwen2.5-3b-instruct-q6_k", displayName: "Qwen2.5 3B Instruct", quant: "Q6_K", sizeGB: 2.79, note: "Best multilingual model under 3 GB for M3", license: "Qwen Research"),
        ModelCatalogEntry(id: "qwen2.5-7b-instruct-q4_k_m", displayName: "Qwen2.5 7B Instruct", quant: "Q4_K_M", sizeGB: 4.68, note: "Fast quality profile for English to Russian", license: "Apache-2.0"),
        ModelCatalogEntry(id: "gemma-2b-translate-q8_0", displayName: "Gemma 2B Translate", quant: "Q8_0", sizeGB: 2.80, note: "English/Korean only", license: "Gemma"),
        ModelCatalogEntry(id: "gemmax2-28-9b-v0.2-q8_0", displayName: "GemmaX2-28-9B-v0.2", quant: "Q8_0", sizeGB: 9.83, note: "Best quality around 10 GB", license: "Gemma"),
        ModelCatalogEntry(id: "gemmax2-28-9b-v0.2-q6_k", displayName: "GemmaX2-28-9B-v0.2", quant: "Q6_K", sizeGB: 7.59, note: "Very good quality", license: "Gemma"),
        ModelCatalogEntry(id: "gemmax2-28-9b-v0.2-q5_k_m", displayName: "GemmaX2-28-9B-v0.2", quant: "Q5_K_M", sizeGB: 6.65, note: "Balanced fallback", license: "Gemma"),
        ModelCatalogEntry(id: "gemmax2-28-9b-v0.2-q4_k_m", displayName: "GemmaX2-28-9B-v0.2", quant: "Q4_K_M", sizeGB: 5.76, note: "Lightweight fallback", license: "Gemma"),
        ModelCatalogEntry(id: "aya-expanse-8b-q8_0", displayName: "Aya Expanse 8B", quant: "Q8_0", sizeGB: 8.54, note: "Multilingual alternative, non-commercial license", license: "CC-BY-NC-4.0")
    ]

    static let defaultModel = models[0]
}

enum LanguageCatalog {
    static let languages = [
        "Arabic", "Bengali", "Czech", "German", "English", "Spanish", "Persian",
        "French", "Hebrew", "Hindi", "Indonesian", "Italian", "Japanese", "Khmer",
        "Korean", "Lao", "Malay", "Burmese", "Dutch", "Polish", "Portuguese",
        "Russian", "Thai", "Tagalog", "Turkish", "Urdu", "Vietnamese", "Chinese"
    ]
}

struct HotKeyOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let keyCode: UInt32
    let carbonModifiers: UInt32

    var enabled: Bool {
        keyCode > 0
    }
}

enum HotKeyCatalog {
    static let defaultID = "shift-command-l"

    static let options: [HotKeyOption] = [
        HotKeyOption(id: "shift-command-l", displayName: "Shift + Command + L", keyCode: 37, carbonModifiers: UInt32(cmdKey | shiftKey)),
        HotKeyOption(id: "control-option-command-l", displayName: "Control + Option + Command + L", keyCode: 37, carbonModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotKeyOption(id: "shift-command-t", displayName: "Shift + Command + T", keyCode: 17, carbonModifiers: UInt32(cmdKey | shiftKey)),
        HotKeyOption(id: "control-option-command-t", displayName: "Control + Option + Command + T", keyCode: 17, carbonModifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotKeyOption(id: "disabled", displayName: "Disabled", keyCode: 0, carbonModifiers: 0)
    ]

    static func option(id: String) -> HotKeyOption {
        options.first { $0.id == id } ?? options[0]
    }
}
