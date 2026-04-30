import Foundation
import NaturalLanguage

TransOnLocalHelper().run()

private final class TransOnLocalHelper {
    private let manager = RuntimeManager()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func run() {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let request = input.isEmpty
                ? HelperRequest(action: .status, modelID: nil, translation: nil)
                : try decoder.decode(HelperRequest.self, from: input)
            let response = try handle(request)
            try write(response)
            exit(response.ok ? 0 : 1)
        } catch {
            let status = manager.status()
            let response = HelperResponse(ok: false, status: status, result: nil, error: error.localizedDescription)
            try? write(response)
            fputs("[TransOnLocalHelper] \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func handle(_ request: HelperRequest) throws -> HelperResponse {
        switch request.action {
        case .status:
            return HelperResponse(ok: true, status: manager.status(), result: nil, error: nil)
        case .prepareRuntime:
            try manager.prepareRuntime()
            return HelperResponse(ok: true, status: manager.status(), result: nil, error: nil)
        case .downloadModel:
            try manager.downloadModel(id: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: nil, error: nil)
        case .translate:
            guard let translation = request.translation else {
                throw HelperError.invalidRequest("Missing translation payload.")
            }
            let result = try manager.translate(translation, modelID: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: result, error: nil)
        case .clearCache:
            try manager.clearCache()
            return HelperResponse(ok: true, status: manager.status(), result: nil, error: nil)
        }
    }

    private func write(_ response: HelperResponse) throws {
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data)
    }
}

private final class RuntimeManager {
    private let fileManager = FileManager.default

    private var rootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("com.grigorym.TransOnLocal", isDirectory: true)
    }

    private var llamaDirectory: URL { rootDirectory.appendingPathComponent("llama.cpp", isDirectory: true) }
    private var modelDirectory: URL { rootDirectory.appendingPathComponent("models", isDirectory: true) }
    private var stateURL: URL { rootDirectory.appendingPathComponent("state.json") }
    private var llamaCliURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-cli") }
    private var llamaCompletionURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-completion") }

    func status() -> LocalModelStatus {
        ensureRootDirectories()
        let state = loadState()
        let model = ModelCatalog.model(id: state.selectedModelID ?? ModelCatalog.defaultModel.id) ?? ModelCatalog.defaultModel
        let modelURL = modelDirectory.appendingPathComponent(model.fileName)
        let hasRuntime = fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
        let hasModel = fileManager.fileExists(atPath: modelURL.path)
        let ready = hasRuntime && hasModel

        let summary: String
        let detail: String
        if ready {
            summary = "GemmaX2 GGUF ready"
            detail = "\(model.displayName) \(model.quant) is available for local translation."
        } else if !hasRuntime {
            summary = "llama.cpp not prepared"
            detail = "Run Prepare / Update to build llama.cpp completion runtime with Metal."
        } else {
            summary = "Model not downloaded"
            detail = "Download \(model.displayName) \(model.quant) before translating."
        }

        return LocalModelStatus(
            ready: ready,
            summary: summary,
            detail: detail,
            modelPath: hasModel ? modelURL.path : nil,
            modelBytes: directorySize(at: modelDirectory),
            llamaCliPath: hasRuntime ? llamaCompletionURL.path : nil
        )
    }

    func prepareRuntime() throws {
        ensureRootDirectories()

        if !fileManager.fileExists(atPath: llamaDirectory.appendingPathComponent(".git").path) {
            try runChecked(
                URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["clone", "--depth", "1", "https://github.com/ggml-org/llama.cpp.git", llamaDirectory.path],
                label: "git clone llama.cpp"
            )
        } else {
            try runChecked(
                URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", llamaDirectory.path, "pull", "--ff-only"],
                label: "git pull llama.cpp"
            )
        }

        let cmake = try resolveExecutable(candidates: ["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake", "/usr/bin/cmake"])
        try runChecked(cmake, arguments: ["-S", llamaDirectory.path, "-B", llamaDirectory.appendingPathComponent("build").path, "-DCMAKE_BUILD_TYPE=Release"], label: "cmake configure llama.cpp")
        try runChecked(cmake, arguments: ["--build", llamaDirectory.appendingPathComponent("build").path, "--config", "Release", "--target", "llama-cli", "-j", "\(ProcessInfo.processInfo.activeProcessorCount)"], label: "cmake build llama-cli")
        try runChecked(cmake, arguments: ["--build", llamaDirectory.appendingPathComponent("build").path, "--config", "Release", "--target", "llama-completion", "-j", "\(ProcessInfo.processInfo.activeProcessorCount)"], label: "cmake build llama-completion")
    }

    func downloadModel(id: String) throws {
        ensureRootDirectories()
        guard let model = ModelCatalog.model(id: id) else {
            throw HelperError.invalidRequest("Unknown model: \(id)")
        }

        var state = loadState()
        state.selectedModelID = id

        let destination = modelDirectory.appendingPathComponent(model.fileName)
        if fileManager.fileExists(atPath: destination.path), fileSize(at: destination) > 1024 * 1024 {
            saveState(state)
            return
        }

        guard let url = URL(string: model.downloadURL) else {
            throw HelperError.invalidRequest("Invalid model URL.")
        }

        let partial = destination.appendingPathExtension("download")
        let curl = try resolveExecutable(candidates: ["/usr/bin/curl", "/opt/homebrew/bin/curl", "/usr/local/bin/curl"])
        try runChecked(
            curl,
            arguments: ["-L", "--fail", "--retry", "3", "-C", "-", "-o", partial.path, url.absoluteString],
            label: "download \(model.fileName)"
        )

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partial, to: destination)
        saveState(state)
    }

    func translate(_ request: TranslationRequest, modelID: String) throws -> TranslationResult {
        ensureRootDirectories()
        guard let model = ModelCatalog.model(id: modelID) else {
            throw HelperError.invalidRequest("Unknown model: \(modelID)")
        }
        guard fileManager.isExecutableFile(atPath: llamaCompletionURL.path) else {
            throw HelperError.runtimeNotReady("llama-completion is not built. Run Prepare / Update again.")
        }

        let modelURL = modelDirectory.appendingPathComponent(model.fileName)
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw HelperError.runtimeNotReady("Model file is missing: \(model.fileName)")
        }

        let sourceLanguage = request.sourceLanguage.flatMap { $0 == "Unknown" ? nil : $0 } ?? detectLanguageName(for: request.text) ?? "Unknown"
        let prompt = """
        Translate this from \(sourceLanguage) to \(request.targetLanguage):
        \(sourceLanguage): \(request.text)
        \(request.targetLanguage):
        """

        let start = Date()
        let result = try runProcess(
            llamaCompletionURL,
            arguments: [
                "-m", modelURL.path,
                "-p", prompt,
                "-n", "\(predictionLimit(for: request.text))",
                "-c", "1024",
                "-b", "256",
                "-ub", "128",
                "--temp", "0",
                "--top-k", "1",
                "--no-display-prompt",
                "--no-warmup",
                "--simple-io"
            ],
            timeout: 900
        )

        let combinedOutput = result.stdout + "\n" + result.stderr
        if combinedOutput.localizedCaseInsensitiveContains("Insufficient Memory")
            || combinedOutput.localizedCaseInsensitiveContains("OutOfMemory")
            || combinedOutput.localizedCaseInsensitiveContains("Compute error") {
            throw HelperError.runtimeNotReady("GemmaX2 Q8_0 does not fit comfortably in current Metal memory. Switch to Q5_K_M or Q4_K_M, or close memory-heavy apps and try again.")
        }

        guard result.exitCode == 0 else {
            throw HelperError.processFailed("llama-completion", result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let translated = cleanTranslation(result.stdout)
        guard !translated.isEmpty else {
            throw HelperError.processFailed("llama-completion", "The model returned an empty translation.")
        }

        return TranslationResult(
            translatedText: translated,
            detectedSourceLanguage: sourceLanguage == "Unknown" ? nil : sourceLanguage,
            duration: Date().timeIntervalSince(start),
            error: nil
        )
    }

    func clearCache() throws {
        try? fileManager.removeItem(at: modelDirectory)
        try? fileManager.removeItem(at: stateURL)
        ensureRootDirectories()
    }

    private func ensureRootDirectories() {
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    private func detectLanguageName(for text: String) -> String? {
        if text.range(of: #"[\u0590-\u05FF]"#, options: .regularExpression) != nil {
            return "Hebrew"
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else {
            return nil
        }
        return languageName(for: dominant)
    }

    private func languageName(for language: NLLanguage) -> String? {
        switch language {
        case .arabic: return "Arabic"
        case .bengali: return "Bengali"
        case .czech: return "Czech"
        case .german: return "German"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .persian: return "Persian"
        case .french: return "French"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .khmer: return "Khmer"
        case .korean: return "Korean"
        case .lao: return "Lao"
        case .malay: return "Malay"
        case .burmese: return "Burmese"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .russian: return "Russian"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .urdu: return "Urdu"
        case .vietnamese: return "Vietnamese"
        case .simplifiedChinese, .traditionalChinese: return "Chinese"
        default: return nil
        }
    }

    private func cleanTranslation(_ output: String) -> String {
        let relevantOutput: String
        if let markerRange = output.range(of: "generate:") {
            relevantOutput = String(output[markerRange.upperBound...])
        } else {
            relevantOutput = output
        }

        let lines = relevantOutput
            .components(separatedBy: .newlines)
            .drop { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    || trimmed.hasPrefix("n_ctx")
                    || trimmed.hasPrefix("=")
            }

        let textLines = lines.prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("common_")
                && !trimmed.hasPrefix("ggml_")
                && !trimmed.hasPrefix("llama_")
                && !trimmed.hasPrefix("sched_")
                && !trimmed.hasPrefix("[ Prompt:")
                && !trimmed.hasPrefix("Exiting")
        }

        return textLines.joined(separator: "\n")
            .replacingOccurrences(of: "[end of text]", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<eos>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func predictionLimit(for text: String) -> Int {
        min(384, max(64, text.count / 2 + 48))
    }

    private func loadState() -> StateFile {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(StateFile.self, from: data) else {
            return StateFile(selectedModelID: ModelCatalog.defaultModel.id)
        }
        return state
    }

    private func saveState(_ state: StateFile) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }

    private func resolveExecutable(candidates: [String]) throws -> URL {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HelperError.runtimeNotReady("Missing executable. Tried: \(candidates.joined(separator: ", "))")
    }

    private func runChecked(_ executable: URL, arguments: [String], label: String) throws {
        let result = try runProcess(executable, arguments: arguments, timeout: 1800)
        guard result.exitCode == 0 else {
            throw HelperError.processFailed(label, result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func runProcess(_ executable: URL, arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw HelperError.processFailed(executable.lastPathComponent, "Timed out after \(Int(timeout)) seconds.")
        }
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return enumerator.compactMap { item -> Int64? in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
            return Int64(values.fileSize ?? 0)
        }.reduce(0, +)
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return 0 }
        return Int64(values.fileSize ?? 0)
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private struct StateFile: Codable {
    var selectedModelID: String?
}

private struct LocalModelStatus: Codable {
    let ready: Bool
    let summary: String
    let detail: String
    let modelPath: String?
    let modelBytes: Int64
    let llamaCliPath: String?
}

private struct TranslationRequest: Codable {
    let text: String
    let sourceLanguage: String?
    let targetLanguage: String
}

private struct TranslationResult: Codable {
    let translatedText: String
    let detectedSourceLanguage: String?
    let duration: Double
    let error: String?
}

private struct HelperRequest: Codable {
    let action: HelperAction
    let modelID: String?
    let translation: TranslationRequest?
}

private struct HelperResponse: Codable {
    let ok: Bool
    let status: LocalModelStatus
    let result: TranslationResult?
    let error: String?
}

private enum HelperAction: String, Codable {
    case status
    case prepareRuntime
    case downloadModel
    case translate
    case clearCache
}

private struct ModelCatalogEntry {
    let id: String
    let displayName: String
    let quant: String
    let sizeGB: Double
    let fileName: String
    let downloadURL: String
}

private enum ModelCatalog {
    static let models: [ModelCatalogEntry] = [
        gemma("gemmax2-28-9b-v0.2-q8_0", "Q8_0", 9.83),
        gemma("gemmax2-28-9b-v0.2-q6_k", "Q6_K", 7.59),
        gemma("gemmax2-28-9b-v0.2-q5_k_m", "Q5_K_M", 6.65),
        gemma("gemmax2-28-9b-v0.2-q4_k_m", "Q4_K_M", 5.76),
        ModelCatalogEntry(
            id: "aya-expanse-8b-q8_0",
            displayName: "Aya Expanse 8B",
            quant: "Q8_0",
            sizeGB: 8.54,
            fileName: "aya-expanse-8b-Q8_0.gguf",
            downloadURL: "https://huggingface.co/lmstudio-community/aya-expanse-8b-GGUF/resolve/main/aya-expanse-8b-Q8_0.gguf?download=true"
        )
    ]

    static let defaultModel = models[0]

    static func model(id: String) -> ModelCatalogEntry? {
        models.first { $0.id == id }
    }

    private static func gemma(_ id: String, _ quant: String, _ sizeGB: Double) -> ModelCatalogEntry {
        let fileName = "GemmaX2-28-9B-v0.2.\(quant).gguf"
        return ModelCatalogEntry(
            id: id,
            displayName: "GemmaX2-28-9B-v0.2",
            quant: quant,
            sizeGB: sizeGB,
            fileName: fileName,
            downloadURL: "https://huggingface.co/mradermacher/GemmaX2-28-9B-v0.2-GGUF/resolve/main/\(fileName)?download=true"
        )
    }
}

private enum HelperError: LocalizedError {
    case invalidRequest(String)
    case runtimeNotReady(String)
    case processFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .runtimeNotReady(let message):
            return message
        case .processFailed(let command, let output):
            return "\(command) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

private var applicationSupportDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
}
