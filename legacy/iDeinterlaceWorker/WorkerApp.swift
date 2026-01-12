import Foundation
import iDeinterlaceShared

/// Main worker application logic
final class WorkerApp {
    private let reporter = ProgressReporter()
    private var vspipeProcess: Process?
    private var ffmpegProcess: Process?
    private var cancelled = false

    func run() -> Int {
        // Set up signal handlers for clean cancellation
        setupSignalHandlers()

        // Parse command line arguments
        guard let configPath = parseArguments() else {
            reporter.sendError("Usage: iDeinterlaceWorker --config <path/to/job.json>")
            return 1
        }

        // Load job configuration
        guard let job = loadJob(from: configPath) else {
            reporter.sendError("Failed to load job configuration from: \(configPath)")
            return 1
        }

        reporter.sendLog(.info, "Starting job: \(job.id)")
        reporter.sendLog(.info, "Input: \(job.inputPath)")
        reporter.sendLog(.info, "Output: \(job.outputPath)")

        // Generate VapourSynth script
        let scriptGenerator = ScriptGenerator()
        let scriptPath: String
        do {
            scriptPath = try scriptGenerator.generate(for: job)
            reporter.sendLog(.info, "Generated script: \(scriptPath)")
        } catch {
            reporter.sendError("Failed to generate script: \(error.localizedDescription)")
            return 1
        }

        // Execute the pipeline
        let executor = PipelineExecutor(reporter: reporter)
        do {
            try executor.execute(
                scriptPath: scriptPath,
                job: job,
                onCancel: { [weak self] in self?.cancelled ?? false }
            )

            if cancelled {
                reporter.sendLog(.warning, "Job cancelled by user")
                cleanup(scriptPath: scriptPath, outputPath: job.outputPath)
                return 130 // Standard cancellation exit code
            }

            reporter.sendComplete(success: true, outputPath: job.outputPath)
            cleanup(scriptPath: scriptPath, outputPath: nil)
            return 0

        } catch {
            reporter.sendError("Pipeline execution failed: \(error.localizedDescription)")
            cleanup(scriptPath: scriptPath, outputPath: job.outputPath)
            return 1
        }
    }

    private func parseArguments() -> String? {
        let args = CommandLine.arguments
        guard let configIndex = args.firstIndex(of: "--config"),
              configIndex + 1 < args.count else {
            return nil
        }
        return args[configIndex + 1]
    }

    private func loadJob(from path: String) -> VideoJob? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(VideoJob.self, from: data)
        } catch {
            reporter.sendLog(.error, "JSON decode error: \(error)")
            return nil
        }
    }

    private func setupSignalHandlers() {
        // Handle SIGTERM (sent by main app on cancel)
        signal(SIGTERM) { _ in
            // Signal handlers must be simple - just set a flag
            // The actual cleanup happens in the main thread
        }

        signal(SIGINT) { _ in
            // Handle Ctrl+C
        }

        // Set up a dispatch source for cleaner signal handling
        let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTermSource.setEventHandler { [weak self] in
            self?.handleCancellation()
        }
        sigTermSource.resume()

        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler { [weak self] in
            self?.handleCancellation()
        }
        sigIntSource.resume()

        // Ignore SIGPIPE (broken pipe)
        signal(SIGPIPE, SIG_IGN)
    }

    private func handleCancellation() {
        cancelled = true
        reporter.sendLog(.info, "Received cancellation signal")

        // Terminate child processes
        vspipeProcess?.terminate()
        ffmpegProcess?.terminate()
    }

    private func cleanup(scriptPath: String, outputPath: String?) {
        // Remove temporary script file
        try? FileManager.default.removeItem(atPath: scriptPath)

        // Remove partial output file if job failed/cancelled
        if let outputPath = outputPath {
            try? FileManager.default.removeItem(atPath: outputPath)
        }
    }
}
