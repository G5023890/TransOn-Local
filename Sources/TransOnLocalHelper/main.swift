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
    private var serverStateURL: URL { rootDirectory.appendingPathComponent("server.json") }
    private var serverLogURL: URL { rootDirectory.appendingPathComponent("llama-server.log") }
    private var llamaCliURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-cli") }
    private var llamaCompletionURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-completion") }
    private var llamaServerURL: URL { llamaDirectory.appendingPathComponent("build/bin/llama-server") }
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
        let hasModel = fileManager.fileExists(atPath: modelURL.path)
        let ready = hasRuntime && hasModel

        let summary: String
        let detail: String
        if ready {
            summary = "GemmaX2 GGUF ready"
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
            llamaCliPath: hasRuntime ? (fileManager.isExecutableFile(atPath: llamaServerURL.path) ? llamaServerURL.path : llamaCompletionURL.path) : nil
        )
    }

    func prepareRuntime() throws {
        ensureRootDirectories()
        try installBundledRuntimeIfNeeded(force: true)
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
        try installBundledRuntimeIfNeeded()

        guard let model = ModelCatalog.model(id: modelID) else {
            throw HelperError.invalidRequest("Unknown model: \(modelID)")
        }
        guard fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
                || fileManager.isExecutableFile(atPath: llamaServerURL.path) else {
            throw HelperError.runtimeNotReady("llama runtime is not installed. Run Prepare / Update again.")
        }

        let modelURL = modelDirectory.appendingPathComponent(model.fileName)
        guard fileManager.fileExists(atPath: modelURL.path) else {
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
        modelURL: URL
    ) throws -> String {
        let prompt = """
        Translate chunk \(chunkNumber) of \(chunkCount) from \(sourceLanguage) to \(targetLanguage).
        Translate the entire text below.
        Preserve Markdown structure and paragraph breaks.
        Do not summarize, shorten, omit, explain, or add commentary.

        Text:
        \(text)

        \(targetLanguage):
        """

        let predictionLimit = predictionLimit(for: text)
        let contextLimit = contextLimit(for: prompt, predictionLimit: predictionLimit)
        let result = try runProcess(
            llamaCompletionURL,
            arguments: [
                "-m", modelURL.path,
                "-p", prompt,
                "-n", "\(predictionLimit)",
                "-c", "\(contextLimit)",
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
        if combinedOutput.localizedCaseInsensitiveContains("prompt is too long") {
            throw HelperError.runtimeNotReady("The selected text is too long for the current local context window. Select a shorter passage and try again.")
        }

        guard result.exitCode == 0 else {
            throw HelperError.processFailed("llama-completion", result.stderr.isEmpty ? result.stdout : result.stderr)
        }

        let translated = cleanTranslation(result.stdout)
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
        server: LlamaServer
    ) throws -> String {
        let prompt = translationPrompt(
            text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            chunkNumber: chunkNumber,
            chunkCount: chunkCount
        )
        let response = try postJSON(
            endpoint: "/completion",
            port: server.port,
            payload: LlamaCompletionRequest(
                prompt: prompt,
                n_predict: predictionLimit(for: text),
                temperature: 0,
                top_k: 1,
                stop: ["<end_of_turn>", "<eos>", "</s>"]
            ),
            responseType: LlamaCompletionResponse.self,
            timeout: 900
        )

        let translated = cleanTranslation(response.content)
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
        chunkCount: Int
    ) -> String {
        """
        Translate chunk \(chunkNumber) of \(chunkCount) from \(sourceLanguage) to \(targetLanguage).
        Translate the entire text below.
        Preserve Markdown structure and paragraph breaks.
        Do not summarize, shorten, omit, explain, or add commentary.

        Text:
        \(text)

        \(targetLanguage):
        """
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
        let runtimeReady = fileManager.isExecutableFile(atPath: llamaCliURL.path)
            && fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
            && (!bundledHasServer || fileManager.isExecutableFile(atPath: llamaServerURL.path))
        if runtimeReady && !force {
            return
        }

        guard let bundledLlamaBinDirectory else {
            throw HelperError.runtimeNotReady("Bundled llama runtime is missing from the app. Reinstall TransOn Local.")
        }

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

        guard fileManager.isExecutableFile(atPath: llamaCliURL.path),
              (fileManager.isExecutableFile(atPath: llamaCompletionURL.path)
               || fileManager.isExecutableFile(atPath: llamaServerURL.path)) else {
            throw HelperError.runtimeNotReady("Bundled llama runtime could not be installed.")
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
        min(4096, max(768, Int(Double(text.count) * 1.4) + 768))
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
            "-b", "256",
            "-ub", "128",
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
