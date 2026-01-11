import Foundation
import Combine

/// Manages the worker process lifecycle and communication
@MainActor
final class WorkerManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progress: ProgressInfo?
    @Published private(set) var logOutput: String = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var cancellables = Set<AnyCancellable>()

    var onProgress: ((ProgressInfo) -> Void)?
    var onLog: ((String) -> Void)?
    var onComplete: ((Result<String, Error>) -> Void)?

    enum WorkerError: Error, LocalizedError {
        case workerNotFound
        case failedToCreateConfigFile
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .workerNotFound:
                return "Worker executable not found in app bundle"
            case .failedToCreateConfigFile:
                return "Failed to create job configuration file"
            case .processFailed(let message):
                return "Worker process failed: \(message)"
            }
        }
    }

    /// Start processing a video job
    func startJob(_ job: VideoJob) throws {
        guard !isRunning else { return }

        // Find worker executable
        guard let workerURL = locateWorker() else {
            throw WorkerError.workerNotFound
        }

        // Write job config to temp file
        let configPath = try writeJobConfig(job)

        // Create process
        process = Process()
        process?.executableURL = workerURL
        process?.arguments = ["--config", configPath]

        // Set up stdout pipe for JSON messages
        stdoutPipe = Pipe()
        process?.standardOutput = stdoutPipe

        // Handle stdout asynchronously
        stdoutPipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.handleWorkerOutput(line)
                }
            }
        }

        // Set up termination handler
        process?.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        // Start the process
        isRunning = true
        logOutput = ""
        progress = nil

        try process?.run()

        appendLog("Started worker process")
    }

    /// Cancel the current job
    func cancel() {
        guard isRunning, let process = process else { return }

        appendLog("Cancelling job...")

        // Send SIGTERM for clean shutdown
        process.terminate()
    }

    private func locateWorker() -> URL? {
        // Check in app bundle
        if let workerPath = Bundle.main.path(forAuxiliaryExecutable: "iDeinterlaceWorker") {
            return URL(fileURLWithPath: workerPath)
        }

        // Check in same directory as main executable
        let mainExec = Bundle.main.executableURL
        let workerURL = mainExec?.deletingLastPathComponent().appendingPathComponent("iDeinterlaceWorker")
        if let url = workerURL, FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }

        return nil
    }

    private func writeJobConfig(_ job: VideoJob) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(job)
        let configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(job.id.uuidString)_config.json")
            .path

        guard FileManager.default.createFile(atPath: configPath, contents: data) else {
            throw WorkerError.failedToCreateConfigFile
        }

        return configPath
    }

    private func handleWorkerOutput(_ output: String) {
        // Worker sends one JSON message per line
        for line in output.components(separatedBy: .newlines) {
            guard !line.isEmpty else { continue }

            // Try to parse as JSON
            if let data = line.data(using: .utf8),
               let message = try? JSONDecoder().decode(WorkerMessage.self, from: data) {
                handleMessage(message)
            } else {
                // Not JSON, treat as plain log output
                appendLog(line)
            }
        }
    }

    private func handleMessage(_ message: WorkerMessage) {
        switch message {
        case .progress(let info):
            progress = info
            onProgress?(info)

        case .log(let logMessage):
            appendLog("[\(logMessage.level.rawValue.uppercased())] \(logMessage.message)")

        case .error(let errorMessage):
            appendLog("[ERROR] \(errorMessage)")

        case .complete(let success, let outputPath):
            if success, let path = outputPath {
                onComplete?(.success(path))
            } else {
                onComplete?(.failure(WorkerError.processFailed("Job did not complete successfully")))
            }
        }
    }

    private func handleTermination(exitCode: Int32) {
        isRunning = false

        // Clean up
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil

        if exitCode == 0 {
            appendLog("Worker completed successfully")
        } else if exitCode == 130 {
            appendLog("Worker cancelled by user")
            onComplete?(.failure(WorkerError.processFailed("Cancelled")))
        } else {
            appendLog("Worker exited with code: \(exitCode)")
            onComplete?(.failure(WorkerError.processFailed("Exit code \(exitCode)")))
        }
    }

    private func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        logOutput += line
        onLog?(line)
    }
}
