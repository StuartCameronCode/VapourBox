import Foundation

/// Detects field order from video file metadata using ffprobe
actor FieldOrderDetector {

    enum DetectionError: Error, LocalizedError {
        case ffprobeNotFound
        case probeExecutionFailed(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .ffprobeNotFound:
                return "ffprobe not found"
            case .probeExecutionFailed(let message):
                return "ffprobe failed: \(message)"
            case .parseError:
                return "Failed to parse video metadata"
            }
        }
    }

    struct VideoInfo {
        let fieldOrder: FieldOrder
        let totalFrames: Int?
        let frameRate: Double?
        let duration: TimeInterval?
        let width: Int?
        let height: Int?
    }

    /// Detect video properties including field order
    func detect(from filePath: String) async throws -> VideoInfo {
        guard let ffprobePath = findFFprobe() else {
            throw DetectionError.ffprobeNotFound
        }

        let output = try await runFFprobe(
            path: ffprobePath,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-select_streams", "v:0",
                filePath
            ]
        )

        return try parseFFprobeOutput(output)
    }

    private func findFFprobe() -> String? {
        // Check bundle helpers
        let bundle = Bundle.main
        if let path = bundle.path(forAuxiliaryExecutable: "ffprobe") {
            return path
        }

        // Check alongside ffmpeg
        if let ffmpegPath = bundle.path(forAuxiliaryExecutable: "ffmpeg") {
            let ffprobePath = URL(fileURLWithPath: ffmpegPath)
                .deletingLastPathComponent()
                .appendingPathComponent("ffprobe")
                .path
            if FileManager.default.isExecutableFile(atPath: ffprobePath) {
                return ffprobePath
            }
        }

        // Check PATH
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?
            .components(separatedBy: ":") ?? []

        for dir in pathDirs {
            let fullPath = (dir as NSString).appendingPathComponent("ffprobe")
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
    }

    private func runFFprobe(path: String, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DetectionError.probeExecutionFailed("Exit code \(process.terminationStatus)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw DetectionError.parseError
        }

        return output
    }

    private func parseFFprobeOutput(_ jsonString: String) throws -> VideoInfo {
        guard let data = jsonString.data(using: .utf8) else {
            throw DetectionError.parseError
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let streams = json?["streams"] as? [[String: Any]],
              let videoStream = streams.first else {
            throw DetectionError.parseError
        }

        // Parse field order
        let fieldOrder: FieldOrder
        if let fieldOrderStr = videoStream["field_order"] as? String {
            switch fieldOrderStr.lowercased() {
            case "tt", "tb", "tff":
                fieldOrder = .topFieldFirst
            case "bb", "bt", "bff":
                fieldOrder = .bottomFieldFirst
            case "progressive":
                fieldOrder = .progressive
            default:
                fieldOrder = .unknown
            }
        } else {
            // Check for interlaced flag
            if let codecName = videoStream["codec_name"] as? String,
               codecName.contains("interlace") {
                fieldOrder = .unknown // Interlaced but unknown order
            } else {
                fieldOrder = .progressive
            }
        }

        // Parse frame count
        var totalFrames: Int?
        if let nbFrames = videoStream["nb_frames"] as? String {
            totalFrames = Int(nbFrames)
        }

        // Parse frame rate
        var frameRate: Double?
        if let rFrameRate = videoStream["r_frame_rate"] as? String {
            let parts = rFrameRate.split(separator: "/")
            if parts.count == 2,
               let num = Double(parts[0]),
               let den = Double(parts[1]),
               den > 0 {
                frameRate = num / den
            }
        }

        // Parse duration
        var duration: TimeInterval?
        if let format = json?["format"] as? [String: Any],
           let durationStr = format["duration"] as? String {
            duration = TimeInterval(durationStr)
        }

        // Parse dimensions
        let width = videoStream["width"] as? Int
        let height = videoStream["height"] as? Int

        return VideoInfo(
            fieldOrder: fieldOrder,
            totalFrames: totalFrames,
            frameRate: frameRate,
            duration: duration,
            width: width,
            height: height
        )
    }
}
