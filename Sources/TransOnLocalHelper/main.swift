import Foundation
import NaturalLanguage
import Darwin

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
            let response = HelperResponse(ok: false, status: status, result: nil, updates: nil, error: error.localizedDescription)
            try? write(response)
            fputs("[TransOnLocalHelper] \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private func handle(_ request: HelperRequest) throws -> HelperResponse {
        switch request.action {
        case .status:
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: nil, error: nil)
        case .prepareRuntime:
            try manager.prepareRuntime()
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: nil, error: nil)
        case .downloadModel:
            try manager.downloadModel(id: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: nil, error: nil)
        case .checkUpdates:
            let updates = manager.checkUpdates(id: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: updates, error: nil)
        case .updateModel:
            try manager.updateModel(id: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: nil, error: nil)
        case .translate:
            guard let translation = request.translation else {
                throw HelperError.invalidRequest("Missing translation payload.")
            }
            let result = try manager.translate(translation, modelID: request.modelID ?? ModelCatalog.defaultModel.id)
            return HelperResponse(ok: true, status: manager.status(), result: result, updates: nil, error: nil)
        case .clearCache:
            try manager.clearCache()
            return HelperResponse(ok: true, status: manager.status(), result: nil, updates: nil, error: nil)
        }
    }

    private func write(_ response: HelperResponse) throws {
        let data = try encoder.encode(response)
        FileHandle.standardOutput.write(data)
    }
}

private final class RuntimeManager {
    private let fileManager = FileManager.default
    private let requiredRuntimeDylibs = [
        "libllama-common.0.dylib",
        "libllama.0.dylib",
        "libggml.0.dylib",
        "libggml-cpu.0.dylib",
        "libggml-blas.0.dylib",
        "libggml-metal.0.dylib",
        "libggml-base.0.dylib"
    ]

    private var rootDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("com.grigorym.TransOnLocal", isDirectory: true)
    }

    private var llamaDirectory: URL { rootDirectory.appendingPathComponent("llama.cpp", isDirectory: true) }
    private var modelDirectory: URL { rootDirectory.appendingPathComponent("models", isDirectory: true) }
    private var stateURL: URL { rootDirectory.appendingPathComponent("state.json") }
    private var downloadProgressURL: URL { rootDirectory.appendingPathComponent("download-progress.json") }
    private var downloadLockURL: URL { rootDirectory.appendingPathComponent("download.lock") }
    private var serverStateURL: URL { rootDirectory.appendingPathComponent("server.json") }
    private var serverLogURL: URL { rootDirectory.appendingPathComponent("llama-server.log") }
    private var llamaCliURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-cli") }
    private var llamaCompletionURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-completion") }
    private var llamaServerURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-server") }
    private func modelMetadataURL(for model: ModelCatalogEntry) -> URL {
        modelDirectory.appendingPathComponent("\(model.id).metadata.json")
    }
    private var bundledLlamaBinDirectory: URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let appBundleURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidate = appBundleURL
            .appendingPathComponent("Contents/Resources/Runtime/llama.cpp/build/bin", isDirectory: true)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func status() -> LocalModelStatus {
        ensureRootDirectories()
        try? installBundledRuntimeIfNeeded()

        let state = loadState()
        let model = ModelCatalog.model(id: state.selectedModelID ?? ModelCatalog.defaultModel.id) ?? ModelCatalog.defaultModel
        let modelURL = modelDirectory.appendingPathComponent(model.fileName)
        let hasRuntime = fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
            || fileManager.isExecutableFile(atPath: llamaServerURL.path)
        let hasModel = hasDownloadedModel(model)
        let ready = hasRuntime && hasModel
        let storedDownloadProgress = loadDownloadProgress()
        let downloadProgress = storedDownloadProgress?.modelID == model.id ? storedDownloadProgress : nil

        var summary: String
        var detail: String
        if let downloadProgress, downloadProgress.phase != .complete, !ready {
            summary = downloadProgress.phase == .failed ? "Model download failed" : "Downloading \(model.displayName)"
            detail = downloadProgress.fileName
        } else if ready {
            summary = "\(model.displayName) ready"
            detail = "\(model.displayName) \(model.quant) is available for local translation."
        } else if !hasRuntime {
            summary = "llama runtime missing"
            detail = "Run Prepare / Update to install the bundled llama runtime."
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
            llamaCliPath: hasRuntime ? (fileManager.isExecutableFile(atPath: llamaServerURL.path) ? llamaServerURL.path : llamaCompletionURL.path) : nil,
            downloadProgress: ready ? nil : downloadProgress
        )
    }

    func prepareRuntime() throws {
        ensureRootDirectories()
        try installBundledRuntimeIfNeeded(force: true)
    }

    func downloadModel(id: String) throws {
        try downloadModel(id: id, force: false)
    }

    func updateModel(id: String) throws {
        try downloadModel(id: id, force: true)
    }

    private func downloadModel(id: String, force: Bool) throws {
        ensureRootDirectories()
        let lock = try acquireDownloadLock()
        defer { lock.release() }

        guard let model = ModelCatalog.model(id: id) else {
            throw HelperError.invalidRequest("Unknown model: \(id)")
        }

        var state = loadState()
        state.selectedModelID = id
        removeDownloadProgress()

        if hasDownloadedModel(model), !force {
            saveState(state)
            return
        }

        if force {
            stopServerIfRunning()
            for file in model.files {
                try? fileManager.removeItem(at: modelDirectory.appendingPathComponent(file.fileName))
            }
            try? fileManager.removeItem(at: modelMetadataURL(for: model))
        }

        let files = try model.files.map { file in
            guard let url = URL(string: file.downloadURL) else {
                throw HelperError.invalidRequest("Invalid model URL.")
            }
            let destination = modelDirectory.appendingPathComponent(file.fileName)
            return ModelDownloadFile(catalogFile: file, sourceURL: url, destinationURL: destination)
        }
        var remoteMetadataByFile: [String: RemoteModelFileMetadata] = [:]
        let totalBytes = files.reduce(Int64(0)) { partial, file in
            let metadata = remoteFileMetadata(url: file.sourceURL)
            remoteMetadataByFile[file.catalogFile.fileName] = metadata
            let size = metadata?.contentLength ?? Int64(fileSize(at: file.destinationURL))
            return partial + max(0, size)
        }
        var completedBytes: Int64 = 0

        do {
            for (index, file) in files.enumerated() {
                if fileManager.fileExists(atPath: file.destinationURL.path), fileSize(at: file.destinationURL) > 1024 * 1024 {
                    completedBytes += Int64(fileSize(at: file.destinationURL))
                    continue
                }

                let startedAt = Date()
                writeDownloadProgress(
                    DownloadProgress(
                        modelID: model.id,
                        modelName: model.displayName,
                        fileName: file.catalogFile.fileName,
                        fileIndex: index + 1,
                        fileCount: files.count,
                        downloadedBytes: completedBytes,
                        totalBytes: totalBytes > 0 ? totalBytes : nil,
                        fileDownloadedBytes: 0,
                        fileTotalBytes: nil,
                        startedAt: startedAt,
                        updatedAt: startedAt,
                        phase: .preparing,
                        error: nil
                    )
                )

                let downloader = SegmentedDownloader(threadCount: 4)
                let downloadedFileBytes = try downloader.download(
                    from: file.sourceURL,
                    to: file.destinationURL,
                    fileName: file.catalogFile.fileName
                ) { progress in
                    let updated = Date()
                    self.writeDownloadProgress(
                        DownloadProgress(
                            modelID: model.id,
                            modelName: model.displayName,
                            fileName: file.catalogFile.fileName,
                            fileIndex: index + 1,
                            fileCount: files.count,
                            downloadedBytes: completedBytes + progress.downloadedBytes,
                            totalBytes: totalBytes > 0 ? totalBytes : progress.totalBytes,
                            fileDownloadedBytes: progress.downloadedBytes,
                            fileTotalBytes: progress.totalBytes,
                            startedAt: startedAt,
                            updatedAt: updated,
                            phase: progress.phase,
                            error: nil
                        )
                    )
                }
                completedBytes += downloadedFileBytes
            }
            saveModelMetadata(model, remoteMetadataByFile: remoteMetadataByFile)
            removeDownloadProgress()
        } catch {
            writeDownloadProgress(
                DownloadProgress(
                    modelID: model.id,
                    modelName: model.displayName,
                    fileName: model.fileName,
                    fileIndex: 1,
                    fileCount: model.files.count,
                    downloadedBytes: completedBytes,
                    totalBytes: totalBytes > 0 ? totalBytes : nil,
                    fileDownloadedBytes: 0,
                    fileTotalBytes: nil,
                    startedAt: Date(),
                    updatedAt: Date(),
                    phase: .failed,
                    error: error.localizedDescription
                )
            )
            throw error
        }
        saveState(state)
    }

    func checkUpdates(id: String) -> UpdateCheckResult {
        ensureRootDirectories()
        let checkedAt = Date()
        let modelStatus: UpdateComponentStatus

        guard let model = ModelCatalog.model(id: id) else {
            modelStatus = UpdateComponentStatus(
                component: .model,
                status: .checkFailed,
                summary: "Check failed",
                detail: "Unknown model: \(id)"
            )
            return updateResult(checkedAt: checkedAt, modelStatus: modelStatus)
        }

        if !hasDownloadedModel(model) {
            modelStatus = UpdateComponentStatus(
                component: .model,
                status: .notDownloaded,
                summary: "Not downloaded",
                detail: "\(model.displayName) \(model.quant) is not installed."
            )
        } else if let metadata = loadModelMetadata(for: model) {
            modelStatus = compareModelMetadata(model, local: metadata)
        } else {
            modelStatus = UpdateComponentStatus(
                component: .model,
                status: .unknown,
                summary: "Installed, update state unknown",
                detail: "Local model exists, but download metadata is missing. Re-download once to enable exact update checks."
            )
        }

        return updateResult(checkedAt: checkedAt, modelStatus: modelStatus)
    }

    func translate(_ request: TranslationRequest, modelID: String) throws -> TranslationResult {
        ensureRootDirectories()
        try installBundledRuntimeIfNeeded()

        guard let model = ModelCatalog.model(id: modelID) else {
            throw HelperError.invalidRequest("Unknown model: \(modelID)")
        }
        guard fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
                || fileManager.isExecutableFile(atPath: llamaServerURL.path) else {
            throw HelperError.runtimeNotReady("llama runtime is not installed. Run Prepare / Update again.")
        }

        let modelURL = modelDirectory.appendingPathComponent(model.fileName)
        guard hasDownloadedModel(model) else {
            throw HelperError.runtimeNotReady("Model file is missing: \(model.fileName)")
        }

        let sourceLanguage = request.sourceLanguage.flatMap { $0 == "Unknown" ? nil : $0 } ?? detectLanguageName(for: request.text) ?? "Unknown"
        let chunks = translationChunks(for: request.text)
        let start = Date()
        let translatedChunks: [String]
        if fileManager.isExecutableFile(atPath: llamaServerURL.path) {
            let server = try ensureServer(modelURL: modelURL)
            translatedChunks = try chunks.enumerated().map { index, chunk in
                try translateChunkViaServer(
                    chunk,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: request.targetLanguage,
                    chunkNumber: index + 1,
                    chunkCount: chunks.count,
                    modelID: model.id,
                    server: server
                )
            }
        } else {
            translatedChunks = try chunks.enumerated().map { index, chunk in
                try translateChunkWithCompletion(
                    chunk,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: request.targetLanguage,
                    chunkNumber: index + 1,
                    chunkCount: chunks.count,
                    modelID: model.id,
                    modelURL: modelURL
                )
            }
        }

        return TranslationResult(
            translatedText: translatedChunks.joined(separator: "\n\n"),
            detectedSourceLanguage: sourceLanguage == "Unknown" ? nil : sourceLanguage,
            duration: Date().timeIntervalSince(start),
            error: nil
        )
    }

    private func translateChunkWithCompletion(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String,
        chunkNumber: Int,
        chunkCount: Int,
        modelID: String,
        modelURL: URL
    ) throws -> String {
        let prompt = translationPrompt(
            text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            chunkNumber: chunkNumber,
            chunkCount: chunkCount,
            modelID: modelID,
            strictMode: false
        )

        let maxPredictionTokens = predictionLimit(for: text)
        let maxContextTokens = contextLimit(for: prompt, predictionLimit: maxPredictionTokens)
        let result = try runProcess(
            llamaCompletionURL,
            arguments: [
                "-m", modelURL.path,
                "-p", prompt,
                "-n", "\(maxPredictionTokens)",
                "-c", "\(maxContextTokens)",
                "-b", "512",
                "-ub", "256",
                "-fa", "auto",
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
        if combinedOutput.localizedCaseInsensitiveContains("prompt is too long") {
            throw HelperError.runtimeNotReady("The selected text is too long for the current local context window. Select a shorter passage and try again.")
        }

        guard result.exitCode == 0 else {
            throw HelperError.processFailed("llama-completion", result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        var translated = cleanTranslation(result.stdout)
        if shouldRetryTranslation(translated, targetLanguage: targetLanguage) {
            let retryPrompt = translationPrompt(
                text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                chunkNumber: chunkNumber,
                chunkCount: chunkCount,
                modelID: modelID,
                strictMode: true
            )
            let retryPredictionTokens = predictionLimit(for: text)
            let retryContextTokens = contextLimit(for: retryPrompt, predictionLimit: retryPredictionTokens)
            let retryResult = try runProcess(
                llamaCompletionURL,
                arguments: [
                    "-m", modelURL.path,
                    "-p", retryPrompt,
                    "-n", "\(retryPredictionTokens)",
                    "-c", "\(retryContextTokens)",
                    "-b", "512",
                    "-ub", "256",
                    "-fa", "auto",
                    "--temp", "0",
                    "--top-k", "1",
                    "--no-display-prompt",
                    "--no-warmup",
                    "--simple-io"
                ],
                timeout: 900
            )
            translated = cleanTranslation(retryResult.stdout)
        }
        guard !translated.isEmpty else {
            throw HelperError.processFailed("llama-completion", "The model returned an empty translation.")
        }

        return translated
    }

    private func translateChunkViaServer(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String,
        chunkNumber: Int,
        chunkCount: Int,
        modelID: String,
        server: LlamaServer
    ) throws -> String {
        let prompt = translationPrompt(
            text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            chunkNumber: chunkNumber,
            chunkCount: chunkCount,
            modelID: modelID,
            strictMode: false
        )
        let response = try postJSON(
            endpoint: "/completion",
            port: server.port,
            payload: LlamaCompletionRequest(
                prompt: prompt,
                n_predict: predictionLimit(for: text),
                temperature: 0,
                top_k: 1,
                stop: ["<|im_end|>", "<end_of_turn>", "<eos>", "</s>"]
            ),
            responseType: LlamaCompletionResponse.self,
            timeout: 900
        )

        var translated = cleanTranslation(response.content)
        if shouldRetryTranslation(translated, targetLanguage: targetLanguage) {
            let retryPrompt = translationPrompt(
                text,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                chunkNumber: chunkNumber,
                chunkCount: chunkCount,
                modelID: modelID,
                strictMode: true
            )
            let retryResponse = try postJSON(
                endpoint: "/completion",
                port: server.port,
                payload: LlamaCompletionRequest(
                    prompt: retryPrompt,
                    n_predict: predictionLimit(for: text),
                    temperature: 0,
                    top_k: 1,
                    stop: ["<|im_end|>", "<end_of_turn>", "<eos>", "</s>"]
                ),
                responseType: LlamaCompletionResponse.self,
                timeout: 900
            )
            translated = cleanTranslation(retryResponse.content)
        }
        guard !translated.isEmpty else {
            throw HelperError.processFailed("llama-server", "The model returned an empty translation.")
        }
        return translated
    }

    private func translationPrompt(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String,
        chunkNumber: Int,
        chunkCount: Int,
        modelID: String,
        strictMode: Bool
    ) -> String {
        let targetHint = translationTargetHint(for: targetLanguage)
        let instructions = """
        Translate chunk \(chunkNumber) of \(chunkCount) from \(sourceLanguage) to \(targetHint).
        Translate the entire text below.
        Preserve Markdown structure and paragraph breaks.
        Preserve marker lines like <<<TRANS_ON_SEGMENT_1>>> exactly as written.
        Do not summarize, shorten, omit, explain, or add commentary.
        Return only the translated text in \(targetHint).
        """
        let strictInstruction = strictMode
            ? "\nCritical: the answer must be written only in \(targetHint). Do not use Chinese, Korean, or any other language unless it appears as an unchanged brand name."
            : ""

        if modelID.hasPrefix("qwen2.5") {
            return """
            <|im_start|>system
            You are a professional translation engine. Follow the user request exactly. Output only the translation, with no labels or explanations.\(strictInstruction)<|im_end|>
            <|im_start|>user
            \(instructions)\(strictInstruction)

            Text:
            \(text)<|im_end|>
            <|im_start|>assistant
            """
        }

        return """
        \(instructions)\(strictInstruction)

        Text:
        \(text)

        \(targetLanguage):
        """
    }

    private func translationTargetHint(for targetLanguage: String) -> String {
        switch targetLanguage {
        case "Russian":
            return "Russian (Русский, Cyrillic script)"
        default:
            return targetLanguage
        }
    }

    private func shouldRetryTranslation(_ translated: String, targetLanguage: String) -> Bool {
        guard targetLanguage == "Russian" else { return false }
        return translated.range(of: #"[\u4E00-\u9FFF\u3400-\u4DBF\u3040-\u30FF\uAC00-\uD7AF]"#, options: .regularExpression) != nil
    }

    func clearCache() throws {
        stopServerIfRunning()
        try? fileManager.removeItem(at: modelDirectory)
        try? fileManager.removeItem(at: stateURL)
        try? fileManager.removeItem(at: serverStateURL)
        ensureRootDirectories()
    }

    private func ensureRootDirectories() {
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    private func installBundledRuntimeIfNeeded(force: Bool = false) throws {
        let bundledHasServer = bundledLlamaBinDirectory
            .map { fileManager.isExecutableFile(atPath: $0.appendingPathComponent("llama-server").path) } ?? false
        let runtimeReady = installedRuntimeIsReady(bundledHasServer: bundledHasServer)
        if runtimeReady && !force {
            return
        }

        guard let bundledLlamaBinDirectory else {
            throw HelperError.runtimeNotReady("Bundled llama runtime is missing from the app. Reinstall TransOn Local.")
        }

        stopServerIfRunning()
        let destinationBinDirectory = llamaDirectory.appendingPathComponent("build/bin", isDirectory: true)
        try? fileManager.removeItem(at: destinationBinDirectory)
        try fileManager.createDirectory(
            at: destinationBinDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: bundledLlamaBinDirectory, to: destinationBinDirectory)

        for executable in [llamaCliURL, llamaCompletionURL, llamaServerURL] where fileManager.fileExists(atPath: executable.path) {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        guard installedRuntimeIsReady(bundledHasServer: bundledHasServer) else {
            throw HelperError.runtimeNotReady("Bundled llama runtime could not be installed.")
        }
    }

    private func installedRuntimeIsReady(bundledHasServer: Bool) -> Bool {
        guard fileManager.isExecutableFile(atPath: llamaCliURL.path),
              fileManager.isExecutableFile(atPath: llamaCompletionURL.path),
              !bundledHasServer || fileManager.isExecutableFile(atPath: llamaServerURL.path) else {
            return false
        }

        let binDirectory = llamaDirectory.appendingPathComponent("build/bin", isDirectory: true)
        return requiredRuntimeDylibs.allSatisfy { dylibName in
            fileManager.fileExists(atPath: binDirectory.appendingPathComponent(dylibName).path)
        }
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

        let cleaned = textLines.joined(separator: "\n")
            .replacingOccurrences(of: "[end of text]", with: "")
            .replacingOccurrences(of: "<end_of_turn>", with: "")
            .replacingOccurrences(of: "<eos>", with: "")
            .replacingOccurrences(of: "</s>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let withoutPromptEcho = stripPromptEcho(from: cleaned)
        return withoutPromptEcho
            .replacingOccurrences(of: #"^\s*[A-Za-z ]+:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripPromptEcho(from text: String) -> String {
        let markers = ["\nТекст:\n", "\nText:\n", "\nTranslation:\n", "\nПеревод:\n"]
        for marker in markers {
            if let range = text.range(of: marker) {
                return String(text[range.upperBound...])
            }
        }
        return text
    }

    private func predictionLimit(for text: String) -> Int {
        min(3072, max(384, Int(Double(text.count)) + 384))
    }

    private func contextLimit(for prompt: String, predictionLimit: Int) -> Int {
        let estimatedPromptTokens = max(256, prompt.count / 3 + 64)
        let requiredTokens = estimatedPromptTokens + predictionLimit + 128
        if requiredTokens <= 2048 {
            return 2048
        }
        if requiredTokens <= 4096 {
            return 4096
        }
        return 8192
    }

    private func translationChunks(for text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let maxCharacters = 900
        var chunks: [String] = []
        var current = ""

        for paragraph in normalized.components(separatedBy: "\n\n") {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count > maxCharacters {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(contentsOf: splitLongParagraph(trimmed, maxCharacters: maxCharacters))
                continue
            }

            let candidate = current.isEmpty ? trimmed : "\(current)\n\n\(trimmed)"
            if candidate.count > maxCharacters {
                chunks.append(current)
                current = trimmed
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func splitLongParagraph(_ paragraph: String, maxCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        let segments = paragraph
            .components(separatedBy: CharacterSet.newlines)
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return [] }
                if trimmed.count <= maxCharacters {
                    return [trimmed]
                }
                return splitSentences(in: trimmed)
                    .flatMap { sentence in splitOversizedSegment(sentence, maxCharacters: maxCharacters) }
            }

        for segment in segments {
            let candidate = current.isEmpty ? segment : "\(current)\n\(segment)"
            if candidate.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = segment
            } else {
                current = candidate
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func splitSentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            if ".!?。！？".contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            sentences.append(remainder)
        }
        return sentences
    }

    private func splitOversizedSegment(_ segment: String, maxCharacters: Int) -> [String] {
        guard segment.count > maxCharacters else { return [segment] }

        var chunks: [String] = []
        var current = ""
        for word in segment.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = current.isEmpty ? word : "\(current) \(word)"
            if candidate.count > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.flatMap { hardSplit($0, maxCharacters: maxCharacters) }
    }

    private func hardSplit(_ text: String, maxCharacters: Int) -> [String] {
        guard text.count > maxCharacters else { return [text] }
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= maxCharacters {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func ensureServer(modelURL: URL) throws -> LlamaServer {
        let desired = LlamaServer(port: 48991, pid: nil, modelPath: modelURL.path)
        if let existing = loadServerState(),
           existing.modelPath == modelURL.path,
           isProcessRunning(pid: existing.pid),
           isServerHealthy(port: existing.port) {
            return existing
        }

        stopServerIfRunning()

        if !fileManager.fileExists(atPath: serverLogURL.path) {
            fileManager.createFile(atPath: serverLogURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: serverLogURL)
        try logHandle.seekToEnd()

        let process = Process()
        process.executableURL = llamaServerURL
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",
            "--port", "\(desired.port)",
            "-c", "4096",
            "-b", "512",
            "-ub", "256",
            "-fa", "auto",
            "--parallel", "1",
            "--threads-http", "1",
            "--no-warmup"
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw error
        }

        let state = LlamaServer(port: desired.port, pid: process.processIdentifier, modelPath: modelURL.path)
        saveServerState(state)

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if isServerHealthy(port: state.port) {
                try? logHandle.close()
                return state
            }
            if !process.isRunning {
                try? logHandle.close()
                throw HelperError.processFailed("llama-server", "Server exited during startup. See \(serverLogURL.path).")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        try? logHandle.close()
        throw HelperError.processFailed("llama-server", "Timed out while loading the model. See \(serverLogURL.path).")
    }

    private func isServerHealthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                healthy = (200..<300).contains(http.statusCode)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 3)
        return healthy
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        endpoint: String,
        port: Int,
        payload: Request,
        responseType: Response.Type,
        timeout: TimeInterval
    ) throws -> Response {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(endpoint)") else {
            throw HelperError.invalidRequest("Invalid llama-server endpoint.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var response: URLResponse?
        var requestError: Error?
        URLSession.shared.dataTask(with: request) { body, urlResponse, error in
            data = body
            response = urlResponse
            requestError = error
            semaphore.signal()
        }.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeout + 5)
        if waitResult == .timedOut {
            throw HelperError.processFailed("llama-server", "Timed out after \(Int(timeout)) seconds.")
        }
        if let requestError {
            throw requestError
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw HelperError.processFailed("llama-server", "HTTP \(http.statusCode): \(body)")
        }
        guard let data else {
            throw HelperError.processFailed("llama-server", "No response body.")
        }
        return try JSONDecoder().decode(responseType, from: data)
    }

    private func loadServerState() -> LlamaServer? {
        guard let data = try? Data(contentsOf: serverStateURL) else { return nil }
        return try? JSONDecoder().decode(LlamaServer.self, from: data)
    }

    private func saveServerState(_ state: LlamaServer) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: serverStateURL, options: [.atomic])
    }

    private func stopServerIfRunning() {
        guard let state = loadServerState() else { return }
        if let pid = state.pid, isProcessRunning(pid: pid) {
            kill(pid, SIGTERM)
        }
        try? fileManager.removeItem(at: serverStateURL)
    }

    private func isProcessRunning(pid: Int32?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
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

    private func loadDownloadProgress() -> DownloadProgress? {
        guard let data = try? Data(contentsOf: downloadProgressURL) else { return nil }
        return try? JSONDecoder().decode(DownloadProgress.self, from: data)
    }

    private func writeDownloadProgress(_ progress: DownloadProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: downloadProgressURL, options: [.atomic])
    }

    private func removeDownloadProgress() {
        try? fileManager.removeItem(at: downloadProgressURL)
    }

    private func acquireDownloadLock() throws -> FileLock {
        let descriptor = open(downloadLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw HelperError.processFailed("download", "Unable to open download lock.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw HelperError.runtimeNotReady("Another model download is already running.")
        }
        return FileLock(descriptor: descriptor)
    }

    private func updateResult(checkedAt: Date, modelStatus: UpdateComponentStatus) -> UpdateCheckResult {
        UpdateCheckResult(
            checkedAt: checkedAt,
            model: modelStatus,
            runtime: runtimeUpdateStatus(),
            modelCatalog: UpdateComponentStatus(
                component: .modelCatalog,
                status: .unknown,
                summary: "Bundled catalog",
                detail: "Catalog updates are reserved for the remote models.json pass."
            ),
            prompts: UpdateComponentStatus(
                component: .prompts,
                status: .unknown,
                summary: "Bundled prompts",
                detail: "Prompt update tracking is reserved for a later pass."
            ),
            performanceProfiles: UpdateComponentStatus(
                component: .performanceProfiles,
                status: .unknown,
                summary: "Bundled profiles",
                detail: "Performance profile update tracking is reserved for a later pass."
            )
        )
    }

    private func runtimeUpdateStatus() -> UpdateComponentStatus {
        let hasRuntime = fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
            || fileManager.isExecutableFile(atPath: llamaServerURL.path)
        return UpdateComponentStatus(
            component: .runtime,
            status: hasRuntime ? .unknown : .notDownloaded,
            summary: hasRuntime ? "Installed" : "Missing",
            detail: hasRuntime
                ? "Runtime is installed; version comparison will be added in the next update-center pass."
                : "Run Prepare / Update to install the bundled llama runtime."
        )
    }

    private func compareModelMetadata(_ model: ModelCatalogEntry, local: ModelDownloadMetadata) -> UpdateComponentStatus {
        var hasComparableHeader = false

        for file in model.files {
            guard let url = URL(string: file.downloadURL) else {
                return UpdateComponentStatus(component: .model, status: .checkFailed, summary: "Check failed", detail: "Invalid model URL for \(file.fileName).")
            }
            guard let remote = remoteFileMetadata(url: url) else {
                return UpdateComponentStatus(component: .model, status: .checkFailed, summary: "Check failed", detail: "Could not read remote metadata for \(file.fileName).")
            }
            guard let localFile = local.files.first(where: { $0.fileName == file.fileName }) else {
                return UpdateComponentStatus(component: .model, status: .unknown, summary: "Installed, update state unknown", detail: "Local metadata does not include \(file.fileName).")
            }

            if let localETag = localFile.etag, let remoteETag = remote.etag, !localETag.isEmpty, !remoteETag.isEmpty {
                hasComparableHeader = true
                if localETag != remoteETag {
                    return UpdateComponentStatus(component: .model, status: .updateAvailable, summary: "Update available", detail: "\(file.fileName) has a new ETag.")
                }
            }
            if let localLastModified = localFile.lastModified, let remoteLastModified = remote.lastModified, !localLastModified.isEmpty, !remoteLastModified.isEmpty {
                hasComparableHeader = true
                if localLastModified != remoteLastModified {
                    return UpdateComponentStatus(component: .model, status: .updateAvailable, summary: "Update available", detail: "\(file.fileName) has a newer Last-Modified header.")
                }
            }
            if let localContentLength = localFile.contentLength, let remoteContentLength = remote.contentLength {
                hasComparableHeader = true
                if localContentLength != remoteContentLength {
                    return UpdateComponentStatus(component: .model, status: .updateAvailable, summary: "Update available", detail: "\(file.fileName) changed size.")
                }
            }
        }

        guard hasComparableHeader else {
            return UpdateComponentStatus(component: .model, status: .unknown, summary: "Unknown", detail: "Remote server did not return comparable headers.")
        }

        return UpdateComponentStatus(
            component: .model,
            status: .upToDate,
            summary: "Up to date",
            detail: "\(model.displayName) \(model.quant) matches remote metadata."
        )
    }

    private func saveModelMetadata(_ model: ModelCatalogEntry, remoteMetadataByFile: [String: RemoteModelFileMetadata]) {
        let files = model.files.map { file -> ModelDownloadFileMetadata in
            let localURL = modelDirectory.appendingPathComponent(file.fileName)
            let remote = remoteMetadataByFile[file.fileName]
            return ModelDownloadFileMetadata(
                fileName: file.fileName,
                downloadedBytes: Int64(fileSize(at: localURL)),
                etag: remote?.etag,
                lastModified: remote?.lastModified,
                contentLength: remote?.contentLength
            )
        }
        let metadata = ModelDownloadMetadata(
            modelID: model.id,
            downloadedAt: Date(),
            files: files
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: modelMetadataURL(for: model), options: [.atomic])
    }

    private func loadModelMetadata(for model: ModelCatalogEntry) -> ModelDownloadMetadata? {
        guard let data = try? Data(contentsOf: modelMetadataURL(for: model)) else { return nil }
        return try? JSONDecoder().decode(ModelDownloadMetadata.self, from: data)
    }

    private func remoteFileMetadata(url: URL) -> RemoteModelFileMetadata? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("TransOn Local", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var response: URLResponse?
        URLSession.shared.dataTask(with: request) { _, taskResponse, _ in
            response = taskResponse
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 20)
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            return nil
        }
        let contentLength = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        return RemoteModelFileMetadata(
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            contentLength: contentLength
        )
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
        let outputCollector = PipeCollector(pipe: stdout)
        let errorCollector = PipeCollector(pipe: stderr)
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        outputCollector.start()
        errorCollector.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw HelperError.processFailed(executable.lastPathComponent, "Timed out after \(Int(timeout)) seconds.")
        }
        process.waitUntilExit()
        outputCollector.stop()
        errorCollector.stop()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outputCollector.stringValue,
            stderr: errorCollector.stringValue
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

    private func hasDownloadedModel(_ model: ModelCatalogEntry) -> Bool {
        model.files.allSatisfy { file in
            let url = modelDirectory.appendingPathComponent(file.fileName)
            return fileManager.fileExists(atPath: url.path) && fileSize(at: url) > 1024 * 1024
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private final class FileLock {
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        guard let descriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        self.descriptor = nil
    }

    deinit {
        release()
    }
}

private struct ModelDownloadFile {
    let catalogFile: ModelCatalogFile
    let sourceURL: URL
    let destinationURL: URL
}

private struct DownloadSnapshot {
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let phase: DownloadPhase
}

private struct RemoteFileInfo {
    let size: Int64?
    let acceptsRanges: Bool
}

private struct RemoteModelFileMetadata: Codable {
    let etag: String?
    let lastModified: String?
    let contentLength: Int64?
}

private struct ModelDownloadMetadata: Codable {
    let modelID: String
    let downloadedAt: Date
    let files: [ModelDownloadFileMetadata]
}

private struct ModelDownloadFileMetadata: Codable {
    let fileName: String
    let downloadedBytes: Int64
    let etag: String?
    let lastModified: String?
    let contentLength: Int64?
}

private final class SegmentedDownloader {
    private let fileManager = FileManager.default
    private let threadCount: Int

    init(threadCount: Int) {
        self.threadCount = max(1, threadCount)
    }

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        fileName: String,
        onProgress: @escaping (DownloadSnapshot) -> Void
    ) throws -> Int64 {
        let info = try fetchRemoteInfo(sourceURL)
        onProgress(DownloadSnapshot(downloadedBytes: 0, totalBytes: info.size, phase: .preparing))

        if let size = info.size, size > 16 * 1024 * 1024, threadCount > 1 {
            do {
                return try downloadSegmented(
                    from: sourceURL,
                    to: destinationURL,
                    totalBytes: size,
                    onProgress: onProgress
                )
            } catch {
                try? fileManager.removeItem(at: partsDirectory(for: destinationURL))
            }
        }

        return try downloadSingle(
            from: sourceURL,
            to: destinationURL,
            totalBytes: info.size,
            onProgress: onProgress
        )
    }

    private func downloadSegmented(
        from sourceURL: URL,
        to destinationURL: URL,
        totalBytes: Int64,
        onProgress: @escaping (DownloadSnapshot) -> Void
    ) throws -> Int64 {
        let partDirectory = partsDirectory(for: destinationURL)
        try? fileManager.removeItem(at: partDirectory)
        try fileManager.createDirectory(at: partDirectory, withIntermediateDirectories: true)

        let partCount = min(threadCount, max(1, Int(totalBytes / (8 * 1024 * 1024))))
        let chunkSize = Int64(ceil(Double(totalBytes) / Double(partCount)))
        let curl = try resolveCurl()
        var downloads: [CurlDownloadProcess] = []

        for index in 0..<partCount {
            let start = Int64(index) * chunkSize
            let end = min(totalBytes - 1, start + chunkSize - 1)
            guard start <= end else { continue }

            let partURL = partDirectory.appendingPathComponent("part-\(index)")
            try? fileManager.removeItem(at: partURL)
            let download = try CurlDownloadProcess(
                executableURL: curl,
                sourceURL: sourceURL,
                destinationURL: partURL,
                range: start...end
            )
            downloads.append(download)
        }

        var lastChange = Date()
        var lastDownloaded: Int64 = 0
        while downloads.contains(where: { $0.isRunning }) {
            let downloaded = downloads.reduce(Int64(0)) { partial, download in
                partial + fileSize(at: download.destinationURL)
            }
            if downloaded > lastDownloaded {
                lastDownloaded = downloaded
                lastChange = Date()
            }
            onProgress(DownloadSnapshot(downloadedBytes: downloaded, totalBytes: totalBytes, phase: .downloading))

            if Date().timeIntervalSince(lastChange) > 45 {
                downloads.forEach { $0.terminate() }
                throw HelperError.processFailed("download", "Download stalled while fetching model segments.")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        for download in downloads {
            let result = download.finish()
            guard result.exitCode == 0 else {
                throw HelperError.processFailed("download", result.stderr.isEmpty ? result.stdout : result.stderr)
            }
        }

        let downloaded = downloads.reduce(Int64(0)) { partial, download in
            partial + fileSize(at: download.destinationURL)
        }
        guard downloaded == totalBytes else {
            throw HelperError.processFailed("download", "Downloaded \(downloaded) bytes, expected \(totalBytes) bytes.")
        }

        onProgress(DownloadSnapshot(downloadedBytes: totalBytes, totalBytes: totalBytes, phase: .finishing))
        let partial = destinationURL.appendingPathExtension("download")
        try? fileManager.removeItem(at: partial)
        fileManager.createFile(atPath: partial.path, contents: nil)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }

        for index in 0..<partCount {
            let partURL = partDirectory.appendingPathComponent("part-\(index)")
            let input = try FileHandle(forReadingFrom: partURL)
            defer { try? input.close() }
            while true {
                let data = input.readData(ofLength: 1024 * 1024)
                if data.isEmpty { break }
                output.write(data)
            }
        }

        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: partial, to: destinationURL)
        try? fileManager.removeItem(at: partDirectory)
        return totalBytes
    }

    private func downloadSingle(
        from sourceURL: URL,
        to destinationURL: URL,
        totalBytes: Int64?,
        onProgress: @escaping (DownloadSnapshot) -> Void
    ) throws -> Int64 {
        let partial = destinationURL.appendingPathExtension("download")
        try? fileManager.removeItem(at: partial)
        let download = try CurlDownloadProcess(
            executableURL: try resolveCurl(),
            sourceURL: sourceURL,
            destinationURL: partial,
            range: nil
        )

        var lastChange = Date()
        var lastDownloaded: Int64 = 0
        while download.isRunning {
            let downloaded = fileSize(at: partial)
            if downloaded > lastDownloaded {
                lastDownloaded = downloaded
                lastChange = Date()
            }
            onProgress(DownloadSnapshot(downloadedBytes: downloaded, totalBytes: totalBytes, phase: .downloading))

            if Date().timeIntervalSince(lastChange) > 45 {
                download.terminate()
                throw HelperError.processFailed("download", "Download stalled while fetching model file.")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let result = download.finish()
        guard result.exitCode == 0 else {
            throw HelperError.processFailed("download", result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        onProgress(DownloadSnapshot(downloadedBytes: fileSize(at: partial), totalBytes: totalBytes, phase: .finishing))

        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: partial, to: destinationURL)
        return fileSize(at: destinationURL)
    }

    private func downloadRange(
        from sourceURL: URL,
        to destinationURL: URL,
        range: ClosedRange<Int64>?,
        progress: @escaping (Int64) -> Void
    ) throws {
        try? fileManager.removeItem(at: destinationURL)
        fileManager.createFile(atPath: destinationURL.path, contents: nil)

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 120
        request.setValue("TransOn Local", forHTTPHeaderField: "User-Agent")
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }

        let output = try FileHandle(forWritingTo: destinationURL)
        let delegate = RangeDownloadDelegate(
            output: output,
            expectsPartialContent: range != nil,
            progress: progress
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
        delegate.wait()
        session.finishTasksAndInvalidate()

        if let error = delegate.error {
            throw error
        }
    }

    private func fetchRemoteInfo(_ url: URL) throws -> RemoteFileInfo {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.setValue("TransOn Local", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var response: URLResponse?
        var requestError: Error?
        URLSession.shared.dataTask(with: request) { _, taskResponse, error in
            response = taskResponse
            requestError = error
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 35)

        if let requestError {
            throw requestError
        }
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            return RemoteFileInfo(size: nil, acceptsRanges: false)
        }

        let rangesHeader = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
        let size = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        return RemoteFileInfo(size: size, acceptsRanges: rangesHeader.contains("bytes"))
    }

    private func partsDirectory(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent("\(destinationURL.lastPathComponent).parts", isDirectory: true)
    }

    private func resolveCurl() throws -> URL {
        for path in ["/usr/bin/curl", "/opt/homebrew/bin/curl", "/usr/local/bin/curl"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw HelperError.runtimeNotReady("curl is not available.")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}

private final class SharedDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64?
    private let onProgress: (DownloadSnapshot) -> Void
    private var downloadedBytes: Int64 = 0
    private var lastReport = Date.distantPast

    init(totalBytes: Int64?, onProgress: @escaping (DownloadSnapshot) -> Void) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func add(_ bytes: Int64) {
        let snapshot: DownloadSnapshot?
        lock.lock()
        downloadedBytes += bytes
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.25 {
            lastReport = now
            snapshot = DownloadSnapshot(downloadedBytes: downloadedBytes, totalBytes: totalBytes, phase: .downloading)
        } else {
            snapshot = nil
        }
        lock.unlock()
        if let snapshot {
            onProgress(snapshot)
        }
    }

    func finish() {
        lock.lock()
        let snapshot = DownloadSnapshot(downloadedBytes: downloadedBytes, totalBytes: totalBytes, phase: .finishing)
        lock.unlock()
        onProgress(snapshot)
    }
}

private final class CurlDownloadProcess: @unchecked Sendable {
    let destinationURL: URL

    private let process: Process
    private let outputCollector: PipeCollector
    private let errorCollector: PipeCollector

    init(
        executableURL: URL,
        sourceURL: URL,
        destinationURL: URL,
        range: ClosedRange<Int64>?
    ) throws {
        self.destinationURL = destinationURL
        process = Process()
        process.executableURL = executableURL

        var arguments = [
            "-L",
            "--fail",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--http1.1",
            "--connect-timeout", "30",
            "--speed-time", "30",
            "--speed-limit", "1024",
            "--silent",
            "--show-error",
            "-o", destinationURL.path
        ]
        if let range {
            arguments.insert(contentsOf: ["--range", "\(range.lowerBound)-\(range.upperBound)"], at: arguments.count - 2)
        }
        arguments.append(sourceURL.absoluteString)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        outputCollector = PipeCollector(pipe: stdout)
        errorCollector = PipeCollector(pipe: stderr)
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        outputCollector.start()
        errorCollector.start()
    }

    var isRunning: Bool {
        process.isRunning
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func finish() -> ProcessResult {
        if process.isRunning {
            process.waitUntilExit()
        }
        outputCollector.stop()
        errorCollector.stop()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: outputCollector.stringValue,
            stderr: errorCollector.stringValue
        )
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func setIfNil(_ value: Value) {
        lock.lock()
        if storedValue == nil {
            storedValue = value
        }
        lock.unlock()
    }
}

private final class RangeDownloadDelegate: NSObject, URLSessionDataDelegate {
    private let output: FileHandle
    private let expectsPartialContent: Bool
    private let progress: (Int64) -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private var responseAccepted = false
    private(set) var error: Error?

    init(output: FileHandle, expectsPartialContent: Bool, progress: @escaping (Int64) -> Void) {
        self.output = output
        self.expectsPartialContent = expectsPartialContent
        self.progress = progress
    }

    func wait() {
        semaphore.wait()
        try? output.close()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            error = HelperError.processFailed("download", "No HTTP response.")
            completionHandler(.cancel)
            return
        }

        if expectsPartialContent {
            responseAccepted = http.statusCode == 206
        } else {
            responseAccepted = (200..<300).contains(http.statusCode)
        }

        if responseAccepted {
            completionHandler(.allow)
        } else {
            error = HelperError.processFailed("download", "HTTP \(http.statusCode)")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        output.write(data)
        progress(Int64(data.count))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError taskError: Error?) {
        if let taskError, error == nil {
            error = taskError
        }
        semaphore.signal()
    }
}

private final class PipeCollector {
    private let pipe: Pipe
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        self.pipe = pipe
    }

    var stringValue: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.lock.lock()
            self?.data.append(chunk)
            self?.lock.unlock()
        }
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !remaining.isEmpty else { return }
        lock.lock()
        data.append(remaining)
        lock.unlock()
    }
}

private struct StateFile: Codable {
    var selectedModelID: String?
}

private struct LlamaServer: Codable {
    let port: Int
    let pid: Int32?
    let modelPath: String
}

private struct LlamaCompletionRequest: Codable {
    let prompt: String
    let n_predict: Int
    let temperature: Double
    let top_k: Int
    let stop: [String]
}

private struct LlamaCompletionResponse: Codable {
    let content: String
}

private struct LocalModelStatus: Codable {
    let ready: Bool
    let summary: String
    let detail: String
    let modelPath: String?
    let modelBytes: Int64
    let llamaCliPath: String?
    let downloadProgress: DownloadProgress?
}

private struct DownloadProgress: Codable {
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
}

private enum DownloadPhase: String, Codable {
    case preparing
    case downloading
    case finishing
    case complete
    case failed
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

private struct UpdateCheckResult: Codable {
    let checkedAt: Date
    let model: UpdateComponentStatus
    let runtime: UpdateComponentStatus
    let modelCatalog: UpdateComponentStatus
    let prompts: UpdateComponentStatus
    let performanceProfiles: UpdateComponentStatus
}

private struct UpdateComponentStatus: Codable {
    let component: UpdateComponent
    let status: UpdateStatus
    let summary: String
    let detail: String
}

private enum UpdateComponent: String, Codable {
    case model
    case runtime
    case modelCatalog
    case prompts
    case performanceProfiles
}

private enum UpdateStatus: String, Codable {
    case upToDate
    case updateAvailable
    case notDownloaded
    case unknown
    case checkFailed
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
    let updates: UpdateCheckResult?
    let error: String?
}

private enum HelperAction: String, Codable {
    case status
    case prepareRuntime
    case downloadModel
    case checkUpdates
    case updateModel
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
    let additionalFiles: [ModelCatalogFile]

    init(
        id: String,
        displayName: String,
        quant: String,
        sizeGB: Double,
        fileName: String,
        downloadURL: String,
        additionalFiles: [ModelCatalogFile] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.quant = quant
        self.sizeGB = sizeGB
        self.fileName = fileName
        self.downloadURL = downloadURL
        self.additionalFiles = additionalFiles
    }

    var files: [ModelCatalogFile] {
        [ModelCatalogFile(fileName: fileName, downloadURL: downloadURL)] + additionalFiles
    }
}

private struct ModelCatalogFile {
    let fileName: String
    let downloadURL: String
}

private enum ModelCatalog {
    static let models: [ModelCatalogEntry] = [
        ModelCatalogEntry(
            id: "qwen2.5-3b-instruct-q6_k",
            displayName: "Qwen2.5 3B Instruct",
            quant: "Q6_K",
            sizeGB: 2.79,
            fileName: "qwen2.5-3b-instruct-q6_k.gguf",
            downloadURL: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q6_k.gguf?download=true"
        ),
        ModelCatalogEntry(
            id: "qwen2.5-7b-instruct-q4_k_m",
            displayName: "Qwen2.5 7B Instruct",
            quant: "Q4_K_M",
            sizeGB: 4.68,
            fileName: "qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf",
            downloadURL: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf?download=true",
            additionalFiles: [
                ModelCatalogFile(
                    fileName: "qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf",
                    downloadURL: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf?download=true"
                )
            ]
        ),
        ModelCatalogEntry(
            id: "gemma-2b-translate-q8_0",
            displayName: "Gemma 2B Translate",
            quant: "Q8_0",
            sizeGB: 2.80,
            fileName: "gemma-2b-translate.Q8_0.gguf",
            downloadURL: "https://huggingface.co/mradermacher/gemma-2b-translate-GGUF/resolve/main/gemma-2b-translate.Q8_0.gguf?download=true"
        ),
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
