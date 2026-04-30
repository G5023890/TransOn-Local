import Foundation
import Carbon

struct LocalModelStatus: Codable, Equatable {
    let ready: Bool
    let summary: String
    let detail: String
    let modelPath: String?
    let modelBytes: Int64
    let llamaCliPath: String?

    static let notLoaded = LocalModelStatus(
        ready: false,
        summary: "Checking local runtime",
        detail: "TransOn Local has not contacted the helper yet.",
        modelPath: nil,
        modelBytes: 0,
        llamaCliPath: nil
    )

    static func failed(_ message: String) -> LocalModelStatus {
        LocalModelStatus(
            ready: false,
            summary: "Local helper unavailable",
            detail: message,
            modelPath: nil,
            modelBytes: 0,
            llamaCliPath: nil
        )
    }
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

struct HelperResponse: Codable {
    let ok: Bool
    let status: LocalModelStatus
    let result: TranslationResult?
    let error: String?
}

enum HelperAction: String, Codable {
    case status
    case prepareRuntime
    case downloadModel
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
