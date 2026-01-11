import Foundation

/// Progress information reported by the worker process
public struct ProgressInfo: Codable, Sendable {
    /// Current frame being processed
    public let frame: Int

    /// Total frames in the video
    public let totalFrames: Int

    /// Current processing speed in frames per second
    public let fps: Double

    /// Estimated time remaining in seconds
    public let eta: TimeInterval

    /// Progress as a fraction (0.0 to 1.0)
    public var progress: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(frame) / Double(totalFrames)
    }

    /// Progress as a percentage (0 to 100)
    public var percentComplete: Int {
        Int(progress * 100)
    }

    /// Formatted ETA string (e.g., "1h 23m 45s")
    public var etaFormatted: String {
        guard eta > 0, eta.isFinite else { return "--" }

        let hours = Int(eta) / 3600
        let minutes = (Int(eta) % 3600) / 60
        let seconds = Int(eta) % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    /// Formatted FPS string
    public var fpsFormatted: String {
        guard fps > 0, fps.isFinite else { return "-- fps" }
        return String(format: "%.1f fps", fps)
    }

    public init(frame: Int, totalFrames: Int, fps: Double, eta: TimeInterval) {
        self.frame = frame
        self.totalFrames = totalFrames
        self.fps = fps
        self.eta = eta
    }
}

/// Messages sent from worker to main app via stdout
public enum WorkerMessage: Codable, Sendable {
    case progress(ProgressInfo)
    case log(LogMessage)
    case error(String)
    case complete(success: Bool, outputPath: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case frame, totalFrames, fps, eta
        case level, message
        case success, outputPath
    }

    private enum MessageType: String, Codable {
        case progress
        case log
        case error
        case complete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .progress:
            let frame = try container.decode(Int.self, forKey: .frame)
            let totalFrames = try container.decode(Int.self, forKey: .totalFrames)
            let fps = try container.decode(Double.self, forKey: .fps)
            let eta = try container.decode(TimeInterval.self, forKey: .eta)
            self = .progress(ProgressInfo(frame: frame, totalFrames: totalFrames, fps: fps, eta: eta))

        case .log:
            let level = try container.decodeIfPresent(String.self, forKey: .level) ?? "info"
            let message = try container.decode(String.self, forKey: .message)
            self = .log(LogMessage(level: LogLevel(rawValue: level) ?? .info, message: message))

        case .error:
            let message = try container.decode(String.self, forKey: .message)
            self = .error(message)

        case .complete:
            let success = try container.decode(Bool.self, forKey: .success)
            let outputPath = try container.decodeIfPresent(String.self, forKey: .outputPath)
            self = .complete(success: success, outputPath: outputPath)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .progress(let info):
            try container.encode(MessageType.progress, forKey: .type)
            try container.encode(info.frame, forKey: .frame)
            try container.encode(info.totalFrames, forKey: .totalFrames)
            try container.encode(info.fps, forKey: .fps)
            try container.encode(info.eta, forKey: .eta)

        case .log(let log):
            try container.encode(MessageType.log, forKey: .type)
            try container.encode(log.level.rawValue, forKey: .level)
            try container.encode(log.message, forKey: .message)

        case .error(let message):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(message, forKey: .message)

        case .complete(let success, let outputPath):
            try container.encode(MessageType.complete, forKey: .type)
            try container.encode(success, forKey: .success)
            try container.encodeIfPresent(outputPath, forKey: .outputPath)
        }
    }
}

/// Log message from worker
public struct LogMessage: Codable, Sendable {
    public let level: LogLevel
    public let message: String
    public let timestamp: Date

    public init(level: LogLevel, message: String, timestamp: Date = Date()) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

/// Log levels
public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Processing state machine
public enum ProcessingState: Equatable, Sendable {
    case idle
    case preparingJob
    case processing(progress: Double)
    case cancelling
    case completed(success: Bool)
    case failed(error: String)

    public var isActive: Bool {
        switch self {
        case .preparingJob, .processing, .cancelling:
            return true
        default:
            return false
        }
    }

    public var canCancel: Bool {
        switch self {
        case .preparingJob, .processing:
            return true
        default:
            return false
        }
    }
}
