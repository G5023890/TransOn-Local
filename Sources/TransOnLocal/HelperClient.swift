import Foundation

final class HelperClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func status() async throws -> LocalModelStatus {
        try await perform(action: .status).status
    }

    func prepareRuntime() async throws -> LocalModelStatus {
        try await perform(action: .prepareRuntime).status
    }

    func downloadModel(modelID: String) async throws -> LocalModelStatus {
        try await perform(action: .downloadModel, modelID: modelID).status
    }

    func clearCache() async throws -> LocalModelStatus {
        try await perform(action: .clearCache).status
    }

    func translate(request: TranslationRequest, modelID: String) async throws -> TranslationResult {
        let response = try await perform(action: .translate, modelID: modelID, translation: request)
        guard let result = response.result else {
            throw HelperClientError.helperFailure(response.error ?? "The helper returned no translation.")
        }
        return result
    }

    private func perform(action: HelperAction, modelID: String? = nil, translation: TranslationRequest? = nil) async throws -> HelperResponse {
        guard let helperURL else {
            throw HelperClientError.helperMissing
        }

        let request = HelperRequest(action: action, modelID: modelID, translation: translation)
        let input = try encoder.encode(request)

        let process = Process()
        process.executableURL = helperURL

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let outputCollector = PipeCollector(pipe: stdout)
        let errorCollector = PipeCollector(pipe: stderr)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        outputCollector.start()
        errorCollector.start()

        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        outputCollector.stop()
        errorCollector.stop()

        let outputData = outputCollector.dataValue
        if outputData.isEmpty {
            let errorData = errorCollector.dataValue
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperClientError.helperFailure(message?.isEmpty == false ? message! : "The helper produced no output.")
        }

        let response = try decoder.decode(HelperResponse.self, from: outputData)
        guard response.ok else {
            throw HelperClientError.helperFailure(response.error ?? response.status.detail)
        }
        return response
    }

    private var helperURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        let direct = bundleURL.appendingPathComponent("Contents/MacOS/TransOnLocalHelper")
        if FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }

        let debug = bundleURL.deletingLastPathComponent().appendingPathComponent("TransOnLocalHelper")
        if FileManager.default.isExecutableFile(atPath: debug.path) {
            return debug
        }

        return nil
    }
}

private final class PipeCollector {
    private let pipe: Pipe
    private let lock = NSLock()
    private var data = Data()

    init(pipe: Pipe) {
        self.pipe = pipe
    }

    var dataValue: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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

enum HelperClientError: LocalizedError {
    case helperMissing
    case helperFailure(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "TransOnLocalHelper is missing from the app bundle."
        case .helperFailure(let message):
            return message
        }
    }
}
