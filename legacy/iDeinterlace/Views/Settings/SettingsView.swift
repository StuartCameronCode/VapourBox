import SwiftUI
import iDeinterlaceShared

/// Main settings view (shown in Settings menu)
struct SettingsView: View {
    var body: some View {
        Text("Use Settings button in main window to configure QTGMC parameters.")
            .padding()
            .frame(width: 400)
    }
}

/// Settings sheet shown from main window
struct SettingsSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Preset Selection
                PresetSection(viewModel: viewModel)

                // Input/Output
                InputOutputSection(viewModel: viewModel)

                // Quality
                QualitySection(viewModel: viewModel)

                // Interpolation
                InterpolationSection(viewModel: viewModel)

                // Motion Analysis
                MotionSection(viewModel: viewModel)

                // Sharpening
                SharpeningSection(viewModel: viewModel)

                // Noise Processing
                NoiseSection(viewModel: viewModel)

                // Source Matching
                SourceMatchSection(viewModel: viewModel)

                // Encoding
                EncodingSection(viewModel: viewModel)
            }
            .formStyle(.grouped)
            .navigationTitle("QTGMC Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        viewModel.resetToDefaults()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 600, idealHeight: 800)
    }
}

// MARK: - Preset Section

private struct PresetSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Preset") {
            Picker("Quality Preset", selection: $viewModel.qtgmcParameters.preset) {
                ForEach(QTGMCPreset.allCases, id: \.self) { preset in
                    VStack(alignment: .leading) {
                        Text(preset.rawValue)
                        Text(preset.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .tag(preset)
                }
            }
            .pickerStyle(.menu)

            Text("Higher quality presets are slower but produce better results.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Input/Output Section

private struct InputOutputSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Input / Output") {
            Picker("Field Order", selection: Binding(
                get: { viewModel.qtgmcParameters.tff },
                set: { viewModel.qtgmcParameters.tff = $0 }
            )) {
                Text("Auto-detect").tag(nil as Bool?)
                Text("Top Field First (TFF)").tag(true as Bool?)
                Text("Bottom Field First (BFF)").tag(false as Bool?)
            }
            .pickerStyle(.segmented)

            Picker("Output Frame Rate", selection: $viewModel.qtgmcParameters.fpsDivisor) {
                Text("Double rate (e.g., 50i → 50p)").tag(1)
                Text("Single rate (e.g., 50i → 25p)").tag(2)
            }

            Picker("Input Type", selection: $viewModel.qtgmcParameters.inputType) {
                Text("Interlaced (normal)").tag(0)
                Text("Progressive").tag(1)
                Text("Progressive with combing").tag(2)
            }
        }
    }
}

// MARK: - Quality Section

private struct QualitySection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Quality (Temporal Smoothing)") {
            OptionalIntStepper(
                "TR0 (Pre-filtering)",
                value: $viewModel.qtgmcParameters.tr0,
                range: 0...2,
                help: "Temporal radius for pre-cleaning. Higher = better quality, slower."
            )

            OptionalIntStepper(
                "TR1 (Motion Analysis)",
                value: $viewModel.qtgmcParameters.tr1,
                range: 0...3,
                help: "Temporal radius for motion analysis."
            )

            OptionalIntStepper(
                "TR2 (Final Smoothing)",
                value: $viewModel.qtgmcParameters.tr2,
                range: 0...3,
                help: "Temporal radius for final output smoothing."
            )

            Divider()

            OptionalIntStepper(
                "Rep0 (Repair after TR0)",
                value: $viewModel.qtgmcParameters.rep0,
                range: 0...4
            )

            Stepper("Rep1: \(viewModel.qtgmcParameters.rep1)", value: $viewModel.qtgmcParameters.rep1, in: 0...4)

            OptionalIntStepper(
                "Rep2 (Repair after TR2)",
                value: $viewModel.qtgmcParameters.rep2,
                range: 0...4
            )

            Toggle("Include Chroma in Repair", isOn: $viewModel.qtgmcParameters.repChroma)
        }
    }
}

// MARK: - Interpolation Section

private struct InterpolationSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    private let ediModes = ["", "NNEDI3", "EEDI3+NNEDI3", "EEDI3", "Bwdif", "Bob"]

    var body: some View {
        Section("Interpolation") {
            Picker("EDI Mode", selection: Binding(
                get: { viewModel.qtgmcParameters.ediMode ?? "" },
                set: { viewModel.qtgmcParameters.ediMode = $0.isEmpty ? nil : $0 }
            )) {
                Text("Preset Default").tag("")
                ForEach(ediModes.dropFirst(), id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }

            OptionalIntStepper(
                "NNSize (Neural net area)",
                value: $viewModel.qtgmcParameters.nnSize,
                range: 0...6,
                help: "NNEDI3 predictor area size. Larger = slower, better quality."
            )

            OptionalIntStepper(
                "NNeurons",
                value: $viewModel.qtgmcParameters.nnNeurons,
                range: 0...4,
                help: "Number of neurons in NNEDI3."
            )

            Stepper("EDI Quality: \(viewModel.qtgmcParameters.ediQual)", value: $viewModel.qtgmcParameters.ediQual, in: 1...2)

            OptionalIntStepper(
                "EDI MaxD",
                value: $viewModel.qtgmcParameters.ediMaxD,
                range: 1...24,
                help: "Maximum search distance for EEDI3."
            )
        }
    }
}

// MARK: - Motion Section

private struct MotionSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Motion Analysis") {
            OptionalIntStepper(
                "Block Size",
                value: $viewModel.qtgmcParameters.blockSize,
                range: 4...32,
                help: "Size of blocks for motion analysis."
            )

            OptionalIntStepper(
                "Overlap",
                value: $viewModel.qtgmcParameters.overlap,
                range: 0...16,
                help: "Block overlap (should be < blockSize/2)."
            )

            OptionalIntStepper(
                "Search Algorithm",
                value: $viewModel.qtgmcParameters.search,
                range: 0...5,
                help: "0=onetime, 3=exhaustive, 4=hex, 5=umh"
            )

            OptionalIntStepper(
                "Search Param",
                value: $viewModel.qtgmcParameters.searchParam,
                range: 1...16
            )

            Divider()

            Stepper("ThSAD1: \(viewModel.qtgmcParameters.thSAD1)", value: $viewModel.qtgmcParameters.thSAD1, in: 0...2000)
            Stepper("ThSAD2: \(viewModel.qtgmcParameters.thSAD2)", value: $viewModel.qtgmcParameters.thSAD2, in: 0...1000)

            Toggle("Chroma Motion", isOn: Binding(
                get: { viewModel.qtgmcParameters.chromaMotion ?? true },
                set: { viewModel.qtgmcParameters.chromaMotion = $0 }
            ))

            Toggle("True Motion", isOn: $viewModel.qtgmcParameters.trueMotion)
            Toggle("Global Motion", isOn: $viewModel.qtgmcParameters.globalMotion)
        }
    }
}

// MARK: - Sharpening Section

private struct SharpeningSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Sharpening") {
            OptionalDoubleStepper(
                "Sharpness",
                value: $viewModel.qtgmcParameters.sharpness,
                range: 0...2,
                step: 0.1,
                help: "Output sharpness. 0 = no sharpening."
            )

            OptionalIntStepper(
                "Sharpening Mode",
                value: $viewModel.qtgmcParameters.sMode,
                range: 0...2,
                help: "0=off, 1=unmasked, 2=masked"
            )

            OptionalIntStepper(
                "Sharpness Limit Mode",
                value: $viewModel.qtgmcParameters.slMode,
                range: 0...2,
                help: "0=off, 1=simple, 2=complex"
            )

            OptionalIntStepper(
                "Sharpness Limit Radius",
                value: $viewModel.qtgmcParameters.slRad,
                range: 1...3
            )
        }
    }
}

// MARK: - Noise Section

private struct NoiseSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    private let denoisers = ["", "dfttest", "fft3dfilter", "knlmeanscl", "bm3d"]
    private let noisePresets = ["Slower", "Slow", "Medium", "Fast", "Faster"]

    var body: some View {
        Section("Noise Processing") {
            OptionalIntStepper(
                "Noise Process",
                value: $viewModel.qtgmcParameters.noiseProcess,
                range: 0...2,
                help: "0=off, 1=denoise, 2=keep grain"
            )

            Picker("Denoiser", selection: Binding(
                get: { viewModel.qtgmcParameters.denoiser ?? "" },
                set: { viewModel.qtgmcParameters.denoiser = $0.isEmpty ? nil : $0 }
            )) {
                Text("Preset Default").tag("")
                ForEach(denoisers.dropFirst(), id: \.self) { d in
                    Text(d).tag(d)
                }
            }

            Picker("Noise Preset", selection: $viewModel.qtgmcParameters.noisePreset) {
                ForEach(noisePresets, id: \.self) { p in
                    Text(p).tag(p)
                }
            }

            OptionalDoubleStepper(
                "EZ Denoise",
                value: $viewModel.qtgmcParameters.ezDenoise,
                range: 0...10,
                step: 0.5,
                help: ">0 enables easy denoising mode"
            )

            OptionalDoubleStepper(
                "EZ Keep Grain",
                value: $viewModel.qtgmcParameters.ezKeepGrain,
                range: 0...1,
                step: 0.1
            )

            Toggle("Chroma Noise", isOn: $viewModel.qtgmcParameters.chromaNoise)
        }
    }
}

// MARK: - Source Match Section

private struct SourceMatchSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Source Matching") {
            Picker("Source Match", selection: $viewModel.qtgmcParameters.sourceMatch) {
                Text("Off").tag(0)
                Text("Simple").tag(1)
                Text("Refined").tag(2)
                Text("Double").tag(3)
            }

            if viewModel.qtgmcParameters.sourceMatch > 0 {
                Text("Source matching improves fidelity but is slower.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Picker("Lossless Mode", selection: $viewModel.qtgmcParameters.lossless) {
                Text("Off").tag(0)
                Text("Lossless").tag(1)
                Text("Fake Lossless").tag(2)
            }
        }
    }
}

// MARK: - Encoding Section

private struct EncodingSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Encoding") {
            Picker("Video Codec", selection: $viewModel.encodingSettings.codec) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in
                    Text(codec.displayName).tag(codec)
                }
            }

            if !viewModel.encodingSettings.codec.isProRes {
                Stepper("Quality (CRF): \(viewModel.encodingSettings.quality)",
                       value: $viewModel.encodingSettings.quality, in: 0...51)

                Picker("Encoder Preset", selection: $viewModel.encodingSettings.encoderPreset) {
                    ForEach(["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"], id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
            }

            Picker("Container", selection: $viewModel.encodingSettings.container) {
                ForEach(ContainerFormat.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }

            Divider()

            Toggle("Copy Audio (no re-encode)", isOn: $viewModel.encodingSettings.audioCopy)

            if !viewModel.encodingSettings.audioCopy {
                Stepper("Audio Bitrate: \(viewModel.encodingSettings.audioBitrate) kbps",
                       value: $viewModel.encodingSettings.audioBitrate, in: 64...320, step: 32)
            }
        }
    }
}

// MARK: - Helper Views

/// Stepper for optional Int values
private struct OptionalIntStepper: View {
    let title: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    var help: String?

    init(_ title: String, value: Binding<Int?>, range: ClosedRange<Int>, help: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)

                Spacer()

                if let v = value {
                    Stepper("\(v)", value: Binding(
                        get: { v },
                        set: { value = $0 }
                    ), in: range)
                    .frame(width: 100)

                    Button("Auto") {
                        value = nil
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Auto")
                        .foregroundColor(.secondary)

                    Stepper("", value: Binding(
                        get: { range.lowerBound },
                        set: { value = $0 }
                    ), in: range)
                    .frame(width: 100)
                    .labelsHidden()
                }
            }

            if let help = help {
                Text(help)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Stepper for optional Double values
private struct OptionalDoubleStepper: View {
    let title: String
    @Binding var value: Double?
    let range: ClosedRange<Double>
    let step: Double
    var help: String?

    init(_ title: String, value: Binding<Double?>, range: ClosedRange<Double>, step: Double = 0.1, help: String? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.step = step
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)

                Spacer()

                if let v = value {
                    Text(String(format: "%.2f", v))
                        .frame(width: 50)
                        .monospacedDigit()

                    Stepper("", value: Binding(
                        get: { v },
                        set: { value = $0 }
                    ), in: range, step: step)
                    .labelsHidden()

                    Button("Auto") {
                        value = nil
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text("Auto")
                        .foregroundColor(.secondary)

                    Stepper("", value: Binding(
                        get: { range.lowerBound },
                        set: { value = $0 }
                    ), in: range, step: step)
                    .labelsHidden()
                }
            }

            if let help = help {
                Text(help)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsSheet(viewModel: SettingsViewModel())
}
