import Foundation
import iDeinterlaceShared

/// Executes the vspipe | ffmpeg pipeline for video processing
final class PipelineExecutor {
    private let reporter: ProgressReporter
    private var vspipeProcess: Process?
    private var ffmpegProcess: Process?
    private var totalFrames: Int = 0

    enum PipelineError: Error, LocalizedError {
        case vspipeNotFound
        case ffmpegNotFound
        case vspipeFailed(Int32)
        case ffmpegFailed(Int32)
        case pipeError(String)

        var errorDescription: String? {
            switch self {
            case .vspipeNotFound:
                return "vspipe executable not found"
            case .ffmpegNotFound:
                return "ffmpeg executable not found"
            case .vspipeFailed(let code):
                return "vspipe exited with code \(code)"
            case .ffmpegFailed(let code):
                return "ffmpeg exited with code \(code)"
            case .pipeError(let message):
                return "Pipeline error: \(message)"
            }
        }
    }

    init(reporter: ProgressReporter) {
        self.reporter = reporter
    }

    func execute(scriptPath: String, job: VideoJob, onCancel: @escaping () -> Bool) throws {
        let bundleResources = BundleResources()

        guard let vspipePath = bundleResources.vspipePath else {
            throw PipelineError.vspipeNotFound
        }

        guard let ffmpegPath = bundleResources.ffmpegPath else {
            throw PipelineError.ffmpegNotFound
        }

        // Set up environment for embedded Python/VapourSynth
        var env = ProcessInfo.processInfo.environment
        // Clear any conda/virtualenv variables that might interfere
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "CONDA_DEFAULT_ENV")
        env.removeValue(forKey: "VIRTUAL_ENV")

        if let pythonHome = bundleResources.pythonHome {
            env["PYTHONHOME"] = pythonHome
        }
        if let pythonPath = bundleResources.pythonPath {
            env["PYTHONPATH"] = pythonPath
        }
        if let vsPluginsPath = bundleResources.vsPluginsPath {
            env["VAPOURSYNTH_PLUGIN_PATH"] = vsPluginsPath
        }
        if let weightsPath = bundleResources.nnedi3WeightsPath {
            env["NNEDI3CL_WEIGHTS_PATH"] = weightsPath
        }

        // Create pipe between vspipe and ffmpeg
        let pipe = Pipe()

        // Set up vspipe process
        vspipeProcess = Process()
        vspipeProcess?.executableURL = URL(fileURLWithPath: vspipePath)
        vspipeProcess?.arguments = ["-c", "y4m", scriptPath, "-"]
        vspipeProcess?.environment = env
        vspipeProcess?.standardOutput = pipe
        vspipeProcess?.standardError = FileHandle.standardError

        // Capture vspipe stderr for video info
        let vspipeStderrPipe = Pipe()
        vspipeProcess?.standardError = vspipeStderrPipe

        // Set up stderr handler to capture total frames
        let stderrQueue = DispatchQueue(label: "vspipe.stderr")
        vspipeStderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                stderrQueue.async {
                    self?.parseVspipeStderr(line)
                }
                // Also forward to actual stderr
                FileHandle.standardError.write(data)
            }
        }

        // Build FFmpeg arguments
        let ffmpegArgs = buildFFmpegArgs(job: job)
        reporter.sendLog(.debug, "FFmpeg args: \(ffmpegArgs.joined(separator: " "))")

        // Set up ffmpeg process
        ffmpegProcess = Process()
        ffmpegProcess?.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpegProcess?.arguments = ffmpegArgs
        ffmpegProcess?.environment = env
        ffmpegProcess?.standardInput = pipe

        // Capture ffmpeg stderr for progress
        let ffmpegStderrPipe = Pipe()
        ffmpegProcess?.standardError = ffmpegStderrPipe

        // Parse ffmpeg progress output
        let progressQueue = DispatchQueue(label: "ffmpeg.progress")
        var lastProgressTime = Date()
        let progressInterval: TimeInterval = 0.5 // Update every 500ms

        ffmpegStderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let output = String(data: data, encoding: .utf8) {
                progressQueue.async {
                    let now = Date()
                    if now.timeIntervalSince(lastProgressTime) >= progressInterval {
                        self?.parseFFmpegProgress(output)
                        lastProgressTime = now
                    }
                }
                // Forward to stderr for log view
                FileHandle.standardError.write(data)
            }
        }

        // Start processes
        reporter.sendLog(.info, "Starting vspipe...")
        try vspipeProcess?.run()

        reporter.sendLog(.info, "Starting ffmpeg...")
        try ffmpegProcess?.run()

        // Wait for completion (with cancellation check)
        let checkInterval: TimeInterval = 0.1
        while ffmpegProcess?.isRunning == true {
            if onCancel() {
                reporter.sendLog(.info, "Cancellation requested, terminating processes...")
                vspipeProcess?.terminate()
                ffmpegProcess?.terminate()
                return
            }
            Thread.sleep(forTimeInterval: checkInterval)
        }

        // Clean up handlers
        vspipeStderrPipe.fileHandleForReading.readabilityHandler = nil
        ffmpegStderrPipe.fileHandleForReading.readabilityHandler = nil

        // Check exit codes
        vspipeProcess?.waitUntilExit()
        ffmpegProcess?.waitUntilExit()

        let vspipeExit = vspipeProcess?.terminationStatus ?? 0
        let ffmpegExit = ffmpegProcess?.terminationStatus ?? 0

        if vspipeExit != 0 && vspipeExit != SIGTERM && vspipeExit != SIGPIPE {
            throw PipelineError.vspipeFailed(vspipeExit)
        }

        if ffmpegExit != 0 && ffmpegExit != SIGTERM {
            throw PipelineError.ffmpegFailed(ffmpegExit)
        }
    }

    private func buildFFmpegArgs(job: VideoJob) -> [String] {
        var args: [String] = []
        let settings = job.encodingSettings

        // Input from pipe
        args += ["-i", "-"]

        // Progress output
        args += ["-progress", "pipe:2"]

        // Video codec
        let codecParts = settings.codec.rawValue.split(separator: " ")
        args += ["-c:v", String(codecParts[0])]

        // Additional codec options (like ProRes profile)
        if codecParts.count > 2 {
            args += [String(codecParts[1]), String(codecParts[2])]
        }

        // Quality settings
        if settings.codec.isProRes {
            // ProRes uses -profile:v which is already in the codec string
        } else {
            // H.264/H.265 use CRF
            args += ["-crf", String(settings.quality)]
            args += ["-preset", settings.encoderPreset]
        }

        // Audio handling
        if settings.audioCopy {
            args += ["-c:a", "copy"]
        } else {
            args += ["-c:a", settings.audioCodec]
            args += ["-b:a", "\(settings.audioBitrate)k"]
        }

        // Custom args
        if !settings.customFFmpegArgs.isEmpty {
            let customArgs = settings.customFFmpegArgs.split(separator: " ").map(String.init)
            args += customArgs
        }

        // Overwrite output
        args += ["-y"]

        // Output file
        args += [job.outputPath]

        return args
    }

    private func parseVspipeStderr(_ output: String) {
        // Look for INPUT_INFO line from our script
        // Format: INPUT_INFO:frames=1234,fps_num=25,fps_den=1
        if output.contains("INPUT_INFO:") {
            let parts = output.components(separatedBy: "INPUT_INFO:").last?
                .components(separatedBy: ",") ?? []

            for part in parts {
                let kv = part.components(separatedBy: "=")
                if kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "frames" {
                    if let frames = Int(kv[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                        totalFrames = frames
                        reporter.sendLog(.info, "Total frames: \(frames)")
                    }
                }
            }
        }
    }

    private func parseFFmpegProgress(_ output: String) {
        // Parse ffmpeg -progress output
        // Format: frame=123\nfps=45.0\n...

        var currentFrame = 0
        var currentFps = 0.0

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "=")
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)

            switch key {
            case "frame":
                currentFrame = Int(value) ?? 0
            case "fps":
                currentFps = Double(value) ?? 0
            default:
                break
            }
        }

        if currentFrame > 0 {
            let effectiveTotalFrames = totalFrames > 0 ? totalFrames : currentFrame
            let eta: TimeInterval
            if currentFps > 0 {
                let remainingFrames = max(0, effectiveTotalFrames - currentFrame)
                eta = Double(remainingFrames) / currentFps
            } else {
                eta = 0
            }

            let progress = ProgressInfo(
                frame: currentFrame,
                totalFrames: effectiveTotalFrames,
                fps: currentFps,
                eta: eta
            )
            reporter.sendProgress(progress)
        }
    }
}

/// Locates bundled dependencies - always uses bundled versions, never system installed
struct BundleResources {
    private let bundle = Bundle.main

    /// Find TestBundle directory for development (walks up from executable to find project root)
    private var testBundlePath: String? {
        guard let execURL = bundle.executableURL else { return nil }

        var dir = execURL.deletingLastPathComponent()
        for _ in 0..<10 {
            let testBundle = dir.appendingPathComponent("Tests/TestBundle")
            let marker = testBundle.appendingPathComponent(".setup-complete")
            if FileManager.default.fileExists(atPath: marker.path) {
                return testBundle.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    var pythonHome: String? {
        // Check app bundle (distributed app)
        if let bundledPath = bundle.privateFrameworksURL?
            .appendingPathComponent("Python.framework/Versions/3.11")
            .path,
           FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }

        // Check TestBundle (development)
        if let testBundle = testBundlePath {
            let pythonPath = "\(testBundle)/Frameworks/Python.framework/Versions/3.14"
            if FileManager.default.fileExists(atPath: pythonPath) {
                return pythonPath
            }
        }

        return nil
    }

    var pythonPath: String? {
        // Additional Python path for packages (havsfunc, mvsfunc, etc.)
        if let testBundle = testBundlePath {
            let packagesPath = "\(testBundle)/PythonPackages"
            if FileManager.default.fileExists(atPath: packagesPath) {
                if let home = pythonHome {
                    return "\(packagesPath):\(home)/lib/python3.14/site-packages"
                }
                return packagesPath
            }
        }
        return nil
    }

    var vspipePath: String? {
        // Check app bundle helpers
        if let path = bundle.path(forAuxiliaryExecutable: "vspipe") {
            return path
        }

        // Check Contents/Helpers in app bundle
        let vspipeHelpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers/vspipe").path
        if FileManager.default.isExecutableFile(atPath: vspipeHelpers) {
            return vspipeHelpers
        }

        // Check TestBundle (development) - use wrapper script which sets up environment
        if let testBundle = testBundlePath {
            let vspipePath = "\(testBundle)/Helpers/vspipe"
            if FileManager.default.isExecutableFile(atPath: vspipePath) {
                return vspipePath
            }
        }

        return nil
    }

    var ffmpegPath: String? {
        // Check app bundle helpers
        if let path = bundle.path(forAuxiliaryExecutable: "ffmpeg") {
            return path
        }

        // Check Contents/Helpers in app bundle
        let ffmpegHelpers = bundle.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path
        if FileManager.default.isExecutableFile(atPath: ffmpegHelpers) {
            return ffmpegHelpers
        }

        // Check TestBundle (development)
        if let testBundle = testBundlePath {
            let ffmpegPath = "\(testBundle)/Helpers/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: ffmpegPath) {
                return ffmpegPath
            }
        }

        return nil
    }

    var vsPluginsPath: String? {
        // Check app bundle plugins
        if let bundledPath = bundle.builtInPlugInsURL?.appendingPathComponent("VapourSynth").path,
           FileManager.default.fileExists(atPath: bundledPath) {
            return bundledPath
        }

        // Check TestBundle (development)
        if let testBundle = testBundlePath {
            let pluginsPath = "\(testBundle)/PlugIns/VapourSynth"
            if FileManager.default.fileExists(atPath: pluginsPath) {
                return pluginsPath
            }
        }

        return nil
    }

    var nnedi3WeightsPath: String? {
        // Check app bundle resources
        if let resourcePath = bundle.resourcePath {
            let weightsPath = "\(resourcePath)/NNEDI3CL/nnedi3_weights.bin"
            if FileManager.default.fileExists(atPath: weightsPath) {
                return weightsPath
            }
        }

        // Check TestBundle (development)
        if let testBundle = testBundlePath {
            let weightsPath = "\(testBundle)/Resources/NNEDI3CL/nnedi3_weights.bin"
            if FileManager.default.fileExists(atPath: weightsPath) {
                return weightsPath
            }
        }

        return nil
    }
}
