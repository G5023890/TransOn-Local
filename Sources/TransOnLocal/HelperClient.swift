import Foundation

final class HelperClient {
    private let encoder = JSONEncoder()

    func status() async throws -> LocalModelStatus {
        try await perform(action: .status).status
    }

    func prepareRuntime() async throws -> LocalModelStatus {
        try await perform(action: .prepareRuntime).status
    }

    func downloadModel(modelID: String) async throws -> LocalModelStatus {
        try await perform(action: .downloadModel, modelID: modelID).status
    }

    func checkUpdates(modelID: String) async throws -> UpdateCheckResult {
        let response = try await perform(action: .checkUpdates, modelID: modelID)
        guard let updates = response.updates else {
            throw HelperClientError.helperFailure(response.error ?? "The helper returned no update status.")
        }
        return updates
    }

    func repairModelMetadata(modelID: String) async throws -> UpdateCheckResult {
        let response = try await perform(action: .repairModelMetadata, modelID: modelID)
        guard let updates = response.updates else {
            throw HelperClientError.helperFailure(response.error ?? "The helper returned no update status.")
        }
        return updates
    }

    func updateModel(modelID: String) async throws -> LocalModelStatus {
        try await perform(action: .updateModel, modelID: modelID).status
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
        try Task.checkCancellation()
        guard let helperURL else {
            throw HelperClientError.helperMissing
        }

        let request = HelperRequest(action: action, modelID: modelID, translation: translation)
        let input = try encoder.encode(request)
        let processHandle = CancellableProcess()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let response = try Self.runHelperProcess(
                            helperURL: helperURL,
                            input: input,
                            processHandle: processHandle
                        )
                        continuation.resume(returning: response)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            processHandle.cancel()
        }
    }

    private static func runHelperProcess(
        helperURL: URL,
        input: Data,
        processHandle: CancellableProcess
    ) throws -> HelperResponse {
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

        guard processHandle.set(process) else {
            throw CancellationError()
        }
        try process.run()
        processHandle.markRunning()
        outputCollector.start()
        errorCollector.start()

        stdin.fileHandleForWriting.write(input)
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        outputCollector.stop()
        errorCollector.stop()

        if processHandle.isCancelled {
            throw CancellationError()
        }

        let outputData = outputCollector.dataValue
        if outputData.isEmpty {
            let errorData = errorCollector.dataValue
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperClientError.helperFailure(message?.isEmpty == false ? message! : "The helper produced no output.")
        }

        let response = try JSONDecoder().decode(HelperResponse.self, from: outputData)
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

private final class CancellableProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var running = false
    private var cancelRequested = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested
    }

    func set(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelRequested else { return false }
        self.process = process
        return true
    }

    func markRunning() {
        let processToCancel: Process?
        lock.lock()
        running = true
        processToCancel = cancelRequested ? process : nil
        lock.unlock()
        processToCancel?.terminate()
    }

    func cancel() {
        let processToCancel: Process?
        lock.lock()
        cancelRequested = true
        processToCancel = running ? process : nil
        lock.unlock()
        processToCancel?.terminate()
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
