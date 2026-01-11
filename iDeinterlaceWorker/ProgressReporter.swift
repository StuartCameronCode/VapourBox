import Foundation

/// Reports progress and messages from worker to main app via JSON on stdout
final class ProgressReporter {
    private let encoder: JSONEncoder
    private let outputLock = NSLock()

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [] // Compact JSON, one line per message
    }

    /// Send progress update
    func sendProgress(_ progress: ProgressInfo) {
        send(.progress(progress))
    }

    /// Send log message
    func sendLog(_ level: LogLevel, _ message: String) {
        send(.log(LogMessage(level: level, message: message)))
    }

    /// Send error message
    func sendError(_ message: String) {
        send(.error(message))
    }

    /// Send completion message
    func sendComplete(success: Bool, outputPath: String?) {
        send(.complete(success: success, outputPath: outputPath))
    }

    private func send(_ message: WorkerMessage) {
        outputLock.lock()
        defer { outputLock.unlock() }

        do {
            let data = try encoder.encode(message)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            // If we can't encode the message, write raw error to stderr
            fputs("Failed to encode worker message: \(error)\n", stderr)
        }
    }
}
