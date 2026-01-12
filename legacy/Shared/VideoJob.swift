import Foundation

/// Represents a complete video processing job
public struct VideoJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public var inputPath: String
    public var outputPath: String
    public var qtgmcParameters: QTGMCParameters
    public var encodingSettings: EncodingSettings

    /// Detected field order from input video (may differ from qtgmcParameters.tff override)
    public var detectedFieldOrder: FieldOrder?

    /// Total frame count of input video
    public var totalFrames: Int?

    /// Input video frame rate
    public var inputFrameRate: Double?

    public init(
        id: UUID = UUID(),
        inputPath: String,
        outputPath: String,
        qtgmcParameters: QTGMCParameters = QTGMCParameters(),
        encodingSettings: EncodingSettings = EncodingSettings()
    ) {
        self.id = id
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.qtgmcParameters = qtgmcParameters
        self.encodingSettings = encodingSettings
    }
}

/// Video encoding settings for FFmpeg output
public struct EncodingSettings: Codable, Equatable, Sendable {
    /// Output video codec
    public var codec: VideoCodec = .h264

    /// Encoder preset (speed/quality tradeoff)
    public var encoderPreset: String = "medium"

    /// Quality setting (CRF for H.264/H.265, quality level for ProRes)
    public var quality: Int = 18

    /// Copy audio stream without re-encoding
    public var audioCopy: Bool = true

    /// Audio codec if not copying
    public var audioCodec: String = "aac"

    /// Audio bitrate in kbps (if re-encoding)
    public var audioBitrate: Int = 192

    /// Additional FFmpeg arguments
    public var customFFmpegArgs: String = ""

    /// Output container format
    public var container: ContainerFormat = .mp4

    public init() {}
}

/// Supported video codecs
public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264 = "libx264"
    case h265 = "libx265"
    case proresProxy = "prores_ks -profile:v 0"
    case proresLT = "prores_ks -profile:v 1"
    case prores422 = "prores_ks -profile:v 2"
    case proresHQ = "prores_ks -profile:v 3"

    public var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .h265: return "H.265 (HEVC)"
        case .proresProxy: return "ProRes Proxy"
        case .proresLT: return "ProRes LT"
        case .prores422: return "ProRes 422"
        case .proresHQ: return "ProRes 422 HQ"
        }
    }

    public var isProRes: Bool {
        switch self {
        case .proresProxy, .proresLT, .prores422, .proresHQ:
            return true
        default:
            return false
        }
    }

    /// Suitable container format for this codec
    public var preferredContainer: ContainerFormat {
        isProRes ? .mov : .mp4
    }
}

/// Output container formats
public enum ContainerFormat: String, Codable, CaseIterable, Sendable {
    case mp4 = "mp4"
    case mov = "mov"
    case mkv = "mkv"

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "QuickTime MOV"
        case .mkv: return "Matroska MKV"
        }
    }
}

/// Video field order
public enum FieldOrder: String, Codable, Sendable {
    case topFieldFirst = "tff"
    case bottomFieldFirst = "bff"
    case progressive = "progressive"
    case unknown = "unknown"

    public var displayName: String {
        switch self {
        case .topFieldFirst: return "Top Field First (TFF)"
        case .bottomFieldFirst: return "Bottom Field First (BFF)"
        case .progressive: return "Progressive"
        case .unknown: return "Unknown"
        }
    }

    /// Convert to QTGMC TFF parameter value
    public var tffValue: Bool? {
        switch self {
        case .topFieldFirst: return true
        case .bottomFieldFirst: return false
        default: return nil
        }
    }
}
