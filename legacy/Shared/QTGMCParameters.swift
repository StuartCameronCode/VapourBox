import Foundation

/// All QTGMC parameters supported by the VapourSynth implementation.
/// Parameters with `nil` values use preset defaults.
public struct QTGMCParameters: Codable, Equatable, Sendable {

    // MARK: - Preset

    /// Master quality/speed preset
    public var preset: QTGMCPreset = .slower

    // MARK: - Input/Output

    /// Input type: 0=interlaced, 1=progressive, 2=progressive with combing artifacts
    public var inputType: Int = 0

    /// Top-field-first. `nil` = auto-detect (must be set for interlaced input)
    public var tff: Bool? = nil

    /// Output frame rate divisor. 1=double-rate (50i→50p), 2=single-rate (50i→25p)
    public var fpsDivisor: Int = 1

    // MARK: - Quality (Temporal Radius)

    /// Temporal radius for pre-filtering (0-2). `nil` = preset default
    public var tr0: Int? = nil

    /// Temporal radius for motion analysis (0-3). `nil` = preset default
    public var tr1: Int? = nil

    /// Temporal radius for final smoothing (0-3). `nil` = preset default
    public var tr2: Int? = nil

    /// Repair mode after TR0 smoothing (0-4). `nil` = preset default
    public var rep0: Int? = nil

    /// Repair mode after TR1 smoothing (0-4)
    public var rep1: Int = 0

    /// Repair mode after TR2 smoothing (0-4). `nil` = preset default
    public var rep2: Int? = nil

    /// Include chroma in repair
    public var repChroma: Bool = true

    // MARK: - Interpolation

    /// Edge interpolation mode: NNEDI3, EEDI3+NNEDI3, EEDI3, Bwdif, Bob
    public var ediMode: String? = nil

    /// NNEDI3 predictor neural network size (0-6). `nil` = preset default
    public var nnSize: Int? = nil

    /// NNEDI3 number of neurons (0-4). `nil` = preset default
    public var nnNeurons: Int? = nil

    /// NNEDI3 interpolation quality (1-2)
    public var ediQual: Int = 1

    /// EEDI3 maximum search distance. `nil` = preset default
    public var ediMaxD: Int? = nil

    /// Chroma interpolation method (empty string = same as luma)
    public var chromaEdi: String = ""

    // MARK: - Motion Analysis

    /// Motion analysis block size. `nil` = preset default
    public var blockSize: Int? = nil

    /// Block overlap (should be less than blockSize/2). `nil` = preset default
    public var overlap: Int? = nil

    /// Search algorithm (0-5): 0=onetime, 1=nstep, 2=log, 3=exhaustive, 4=hex, 5=umh
    public var search: Int? = nil

    /// Search parameter (meaning depends on search type). `nil` = preset default
    public var searchParam: Int? = nil

    /// Sub-pixel search accuracy (1-4). `nil` = preset default
    public var pelSearch: Int? = nil

    /// Consider chroma in motion analysis. `nil` = preset default
    public var chromaMotion: Bool? = nil

    /// Use true motion estimation
    public var trueMotion: Bool = false

    /// Motion vector cost weighting. `nil` = preset default
    public var lambda: Int? = nil

    /// Least squares adaptive distance. `nil` = preset default
    public var lsad: Int? = nil

    /// Penalty for new motion vectors. `nil` = preset default
    public var pNew: Int? = nil

    /// Penalty level. `nil` = preset default
    public var pLevel: Int? = nil

    /// Use global motion analysis
    public var globalMotion: Bool = true

    /// DCT mode for motion analysis (0-10)
    public var dct: Int = 0

    /// Sub-pixel accuracy (1=full, 2=half, 4=quarter). `nil` = preset default
    public var subPel: Int? = nil

    /// Sub-pixel interpolation method (1-2)
    public var subPelInterp: Int = 2

    // MARK: - Motion Thresholds

    /// SAD threshold for TR1 temporal smoothing
    public var thSAD1: Int = 640

    /// SAD threshold for TR2 temporal smoothing
    public var thSAD2: Int = 256

    /// Scene change detection threshold 1
    public var thSCD1: Int = 180

    /// Scene change detection threshold 2
    public var thSCD2: Int = 98

    // MARK: - Sharpening

    /// Output sharpness (0.0-2.0). `nil` = preset default
    public var sharpness: Double? = nil

    /// Sharpening mode: 0=off, 1=unmasked, 2=masked. `nil` = preset default
    public var sMode: Int? = nil

    /// Sharpness limiting mode: 0=off, 1=simple, 2=complex. `nil` = preset default
    public var slMode: Int? = nil

    /// Sharpness limiting radius. `nil` = preset default
    public var slRad: Int? = nil

    /// Sharpening overshoot
    public var sOvs: Int = 0

    /// Thin line sharpening (0.0-1.0)
    public var svThin: Double = 0.0

    /// Sharpening back-blend (0-3). `nil` = preset default
    public var sbb: Int? = nil

    /// Search clip preprocessing (0-5). `nil` = preset default
    public var srchClipPP: Int? = nil

    // MARK: - Noise Processing

    /// Noise processing mode: 0=off, 1=denoise, 2=grain restore. `nil` = preset default
    public var noiseProcess: Int? = nil

    /// Easy denoise (>0 enables denoising with this strength)
    public var ezDenoise: Double? = nil

    /// Easy grain retention amount
    public var ezKeepGrain: Double? = nil

    /// Noise estimation preset: Slower, Slow, Medium, Fast, Faster
    public var noisePreset: String = "Fast"

    /// Denoiser: dfttest, fft3dfilter, knlmeanscl, bm3d. `nil` = preset default
    public var denoiser: String? = nil

    /// FFT denoiser thread count
    public var fftThreads: Int = 1

    /// Motion-compensated denoising. `nil` = preset default
    public var denoiseMC: Bool? = nil

    /// Noise temporal radius. `nil` = preset default
    public var noiseTR: Int? = nil

    /// Denoising sigma (strength). `nil` = preset default
    public var sigma: Double? = nil

    /// Apply denoising to chroma
    public var chromaNoise: Bool = false

    /// Show noise (for debugging, 0.0=off)
    public var showNoise: Double = 0.0

    /// Grain restoration amount. `nil` = preset default
    public var grainRestore: Double? = nil

    /// Noise restoration amount. `nil` = preset default
    public var noiseRestore: Double? = nil

    /// Noise deinterlacing method. `nil` = preset default
    public var noiseDeint: String? = nil

    /// Stabilize noise. `nil` = preset default
    public var stabilizeNoise: Bool? = nil

    // MARK: - Source Matching

    /// Source matching mode: 0=off, 1=simple, 2=refined, 3=double
    public var sourceMatch: Int = 0

    /// Interpolation preset for source match pass 1
    public var matchPreset: String? = nil

    /// Interpolation method for source match pass 1
    public var matchEdi: String? = nil

    /// Interpolation preset for source match pass 2
    public var matchPreset2: String? = nil

    /// Interpolation method for source match pass 2
    public var matchEdi2: String? = nil

    /// Temporal radius for source match output
    public var matchTR2: Int = 1

    /// Source match enhancement
    public var matchEnhance: Double = 0.5

    /// Lossless mode: 0=off, 1=lossless, 2=fake lossless
    public var lossless: Int = 0

    // MARK: - Advanced

    /// Add borders to help edge interpolation
    public var border: Bool = false

    /// Use precise mode. `nil` = preset default
    public var precise: Bool? = nil

    /// Force minimum temporal radius for motion vectors
    public var forceTR: Int = 0

    /// Pre-filter brightening strength
    public var str: Double = 2.0

    /// Amplitude
    public var amp: Double = 0.0625

    /// Fast motion analysis
    public var fastMA: Bool = false

    /// Extended pel search
    public var eSearchP: Bool = false

    /// Refine motion estimation
    public var refineMotion: Bool = false

    // MARK: - GPU Acceleration

    /// Use OpenCL acceleration (uses znedi3 instead of nnedi3)
    public var opencl: Bool = false

    /// OpenCL device index. `nil` = auto
    public var device: Int? = nil

    // MARK: - Initialization

    public init() {}

    /// Create parameters from a preset with default values
    public static func fromPreset(_ preset: QTGMCPreset) -> QTGMCParameters {
        var params = QTGMCParameters()
        params.preset = preset
        return params
    }
}

// MARK: - Preset Enum

/// QTGMC quality/speed presets
public enum QTGMCPreset: String, Codable, CaseIterable, Sendable {
    case placebo = "Placebo"
    case verySlow = "Very Slow"
    case slower = "Slower"
    case slow = "Slow"
    case medium = "Medium"
    case fast = "Fast"
    case faster = "Faster"
    case veryFast = "Very Fast"
    case superFast = "Super Fast"
    case ultraFast = "Ultra Fast"
    case draft = "Draft"

    /// Human-readable description
    public var description: String {
        switch self {
        case .placebo: return "Highest quality, very slow"
        case .verySlow: return "Excellent quality, slow"
        case .slower: return "Very high quality (recommended)"
        case .slow: return "High quality, moderate speed"
        case .medium: return "Good quality, faster"
        case .fast: return "Fair quality, fast"
        case .faster: return "Lower quality, very fast"
        case .veryFast: return "Basic quality, very fast"
        case .superFast: return "Minimal quality, fastest"
        case .ultraFast: return "Lowest quality (uses yadif)"
        case .draft: return "Testing only"
        }
    }
}
