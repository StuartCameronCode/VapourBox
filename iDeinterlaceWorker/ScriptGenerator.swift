import Foundation

/// Generates VapourSynth scripts from templates by substituting parameters
final class ScriptGenerator {

    enum GeneratorError: Error, LocalizedError {
        case templateNotFound
        case writeError(String)

        var errorDescription: String? {
            switch self {
            case .templateNotFound:
                return "VapourSynth template file not found"
            case .writeError(let path):
                return "Failed to write script to: \(path)"
            }
        }
    }

    /// Generate a .vpy script file for the given job
    /// - Parameter job: The video job configuration
    /// - Returns: Path to the generated script file
    func generate(for job: VideoJob) throws -> String {
        let template = try loadTemplate()
        let script = substituteParameters(template: template, job: job)

        // Write to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let scriptPath = tempDir.appendingPathComponent("\(job.id.uuidString).vpy").path

        guard FileManager.default.createFile(atPath: scriptPath, contents: script.data(using: .utf8)) else {
            throw GeneratorError.writeError(scriptPath)
        }

        return scriptPath
    }

    private func loadTemplate() throws -> String {
        // Try to load from bundle resources
        if let bundlePath = Bundle.main.path(forResource: "qtgmc_template", ofType: "vpy", inDirectory: "Templates") {
            if let content = FileManager.default.contents(atPath: bundlePath),
               let template = String(data: content, encoding: .utf8) {
                return template
            }
        }

        // Fallback: look in the same directory as the executable
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let templatesDir = executableURL.deletingLastPathComponent().appendingPathComponent("Templates")
        let templatePath = templatesDir.appendingPathComponent("qtgmc_template.vpy")

        if let content = FileManager.default.contents(atPath: templatePath.path),
           let template = String(data: content, encoding: .utf8) {
            return template
        }

        // Last resort: embedded template
        return embeddedTemplate()
    }

    private func substituteParameters(template: String, job: VideoJob) -> String {
        var script = template
        let params = job.qtgmcParameters

        // Input path (escape backslashes for Python)
        let escapedInput = job.inputPath.replacingOccurrences(of: "\\", with: "\\\\")
        script = script.replacingOccurrences(of: "{{INPUT_PATH}}", with: escapedInput)

        // Preset (required)
        script = script.replacingOccurrences(of: "{{PRESET}}", with: params.preset.rawValue)

        // Process optional parameters using mustache-like syntax
        // {{#PARAM}}...{{/PARAM}} blocks are included only if param is set

        script = processOptionalBool("TFF", value: params.tff, in: script)
        script = processOptionalInt("INPUT_TYPE", value: params.inputType != 0 ? params.inputType : nil, in: script)
        script = processOptionalInt("FPS_DIVISOR", value: params.fpsDivisor != 1 ? params.fpsDivisor : nil, in: script)

        // Quality parameters
        script = processOptionalInt("TR0", value: params.tr0, in: script)
        script = processOptionalInt("TR1", value: params.tr1, in: script)
        script = processOptionalInt("TR2", value: params.tr2, in: script)
        script = processOptionalInt("REP0", value: params.rep0, in: script)
        script = processOptionalInt("REP1", value: params.rep1 != 0 ? params.rep1 : nil, in: script)
        script = processOptionalInt("REP2", value: params.rep2, in: script)
        script = processOptionalBool("REP_CHROMA", value: !params.repChroma ? false : nil, in: script)

        // Interpolation
        script = processOptionalString("EDI_MODE", value: params.ediMode, in: script)
        script = processOptionalInt("NN_SIZE", value: params.nnSize, in: script)
        script = processOptionalInt("NN_NEURONS", value: params.nnNeurons, in: script)
        script = processOptionalInt("EDI_QUAL", value: params.ediQual != 1 ? params.ediQual : nil, in: script)
        script = processOptionalInt("EDI_MAX_D", value: params.ediMaxD, in: script)
        script = processOptionalString("CHROMA_EDI", value: params.chromaEdi.isEmpty ? nil : params.chromaEdi, in: script)

        // Motion analysis
        script = processOptionalInt("BLOCK_SIZE", value: params.blockSize, in: script)
        script = processOptionalInt("OVERLAP", value: params.overlap, in: script)
        script = processOptionalInt("SEARCH", value: params.search, in: script)
        script = processOptionalInt("SEARCH_PARAM", value: params.searchParam, in: script)
        script = processOptionalInt("PEL_SEARCH", value: params.pelSearch, in: script)
        script = processOptionalBool("CHROMA_MOTION", value: params.chromaMotion, in: script)
        script = processOptionalBool("TRUE_MOTION", value: params.trueMotion ? true : nil, in: script)
        script = processOptionalInt("LAMBDA", value: params.lambda, in: script)
        script = processOptionalInt("LSAD", value: params.lsad, in: script)
        script = processOptionalInt("P_NEW", value: params.pNew, in: script)
        script = processOptionalInt("P_LEVEL", value: params.pLevel, in: script)
        script = processOptionalBool("GLOBAL_MOTION", value: !params.globalMotion ? false : nil, in: script)
        script = processOptionalInt("DCT", value: params.dct != 0 ? params.dct : nil, in: script)
        script = processOptionalInt("SUB_PEL", value: params.subPel, in: script)
        script = processOptionalInt("SUB_PEL_INTERP", value: params.subPelInterp != 2 ? params.subPelInterp : nil, in: script)

        // Thresholds
        script = processOptionalInt("TH_SAD1", value: params.thSAD1 != 640 ? params.thSAD1 : nil, in: script)
        script = processOptionalInt("TH_SAD2", value: params.thSAD2 != 256 ? params.thSAD2 : nil, in: script)
        script = processOptionalInt("TH_SCD1", value: params.thSCD1 != 180 ? params.thSCD1 : nil, in: script)
        script = processOptionalInt("TH_SCD2", value: params.thSCD2 != 98 ? params.thSCD2 : nil, in: script)

        // Sharpening
        script = processOptionalDouble("SHARPNESS", value: params.sharpness, in: script)
        script = processOptionalInt("S_MODE", value: params.sMode, in: script)
        script = processOptionalInt("SL_MODE", value: params.slMode, in: script)
        script = processOptionalInt("SL_RAD", value: params.slRad, in: script)
        script = processOptionalInt("S_OVS", value: params.sOvs != 0 ? params.sOvs : nil, in: script)
        script = processOptionalDouble("SV_THIN", value: params.svThin != 0 ? params.svThin : nil, in: script)
        script = processOptionalInt("SBB", value: params.sbb, in: script)
        script = processOptionalInt("SRCH_CLIP_PP", value: params.srchClipPP, in: script)

        // Noise processing
        script = processOptionalInt("NOISE_PROCESS", value: params.noiseProcess, in: script)
        script = processOptionalDouble("EZ_DENOISE", value: params.ezDenoise, in: script)
        script = processOptionalDouble("EZ_KEEP_GRAIN", value: params.ezKeepGrain, in: script)
        script = processOptionalString("NOISE_PRESET", value: params.noisePreset != "Fast" ? params.noisePreset : nil, in: script)
        script = processOptionalString("DENOISER", value: params.denoiser, in: script)
        script = processOptionalInt("FFT_THREADS", value: params.fftThreads != 1 ? params.fftThreads : nil, in: script)
        script = processOptionalBool("DENOISE_MC", value: params.denoiseMC, in: script)
        script = processOptionalInt("NOISE_TR", value: params.noiseTR, in: script)
        script = processOptionalDouble("SIGMA", value: params.sigma, in: script)
        script = processOptionalBool("CHROMA_NOISE", value: params.chromaNoise ? true : nil, in: script)
        script = processOptionalDouble("SHOW_NOISE", value: params.showNoise != 0 ? params.showNoise : nil, in: script)
        script = processOptionalDouble("GRAIN_RESTORE", value: params.grainRestore, in: script)
        script = processOptionalDouble("NOISE_RESTORE", value: params.noiseRestore, in: script)
        script = processOptionalString("NOISE_DEINT", value: params.noiseDeint, in: script)
        script = processOptionalBool("STABILIZE_NOISE", value: params.stabilizeNoise, in: script)

        // Source matching
        script = processOptionalInt("SOURCE_MATCH", value: params.sourceMatch != 0 ? params.sourceMatch : nil, in: script)
        script = processOptionalString("MATCH_PRESET", value: params.matchPreset, in: script)
        script = processOptionalString("MATCH_EDI", value: params.matchEdi, in: script)
        script = processOptionalString("MATCH_PRESET2", value: params.matchPreset2, in: script)
        script = processOptionalString("MATCH_EDI2", value: params.matchEdi2, in: script)
        script = processOptionalInt("MATCH_TR2", value: params.matchTR2 != 1 ? params.matchTR2 : nil, in: script)
        script = processOptionalDouble("MATCH_ENHANCE", value: params.matchEnhance != 0.5 ? params.matchEnhance : nil, in: script)
        script = processOptionalInt("LOSSLESS", value: params.lossless != 0 ? params.lossless : nil, in: script)

        // Advanced
        script = processOptionalBool("BORDER", value: params.border ? true : nil, in: script)
        script = processOptionalBool("PRECISE", value: params.precise, in: script)
        script = processOptionalInt("FORCE_TR", value: params.forceTR != 0 ? params.forceTR : nil, in: script)

        // GPU
        script = processOptionalBool("OPENCL", value: params.opencl ? true : nil, in: script)
        script = processOptionalInt("DEVICE", value: params.device, in: script)

        return script
    }

    private func processOptionalInt(_ name: String, value: Int?, in script: String) -> String {
        let startTag = "{{#\(name)}}"
        let endTag = "{{/\(name)}}"
        let placeholder = "{{\(name)}}"

        if let value = value {
            // Include the block with substituted value
            var result = script.replacingOccurrences(of: startTag, with: "")
            result = result.replacingOccurrences(of: endTag, with: "")
            result = result.replacingOccurrences(of: placeholder, with: String(value))
            return result
        } else {
            // Remove the entire block
            return removeBlock(startTag: startTag, endTag: endTag, in: script)
        }
    }

    private func processOptionalDouble(_ name: String, value: Double?, in script: String) -> String {
        let startTag = "{{#\(name)}}"
        let endTag = "{{/\(name)}}"
        let placeholder = "{{\(name)}}"

        if let value = value {
            var result = script.replacingOccurrences(of: startTag, with: "")
            result = result.replacingOccurrences(of: endTag, with: "")
            result = result.replacingOccurrences(of: placeholder, with: String(format: "%.4g", value))
            return result
        } else {
            return removeBlock(startTag: startTag, endTag: endTag, in: script)
        }
    }

    private func processOptionalBool(_ name: String, value: Bool?, in script: String) -> String {
        let startTag = "{{#\(name)}}"
        let endTag = "{{/\(name)}}"
        let placeholder = "{{\(name)}}"

        if let value = value {
            var result = script.replacingOccurrences(of: startTag, with: "")
            result = result.replacingOccurrences(of: endTag, with: "")
            result = result.replacingOccurrences(of: placeholder, with: value ? "True" : "False")
            return result
        } else {
            return removeBlock(startTag: startTag, endTag: endTag, in: script)
        }
    }

    private func processOptionalString(_ name: String, value: String?, in script: String) -> String {
        let startTag = "{{#\(name)}}"
        let endTag = "{{/\(name)}}"
        let placeholder = "{{\(name)}}"

        if let value = value {
            var result = script.replacingOccurrences(of: startTag, with: "")
            result = result.replacingOccurrences(of: endTag, with: "")
            result = result.replacingOccurrences(of: placeholder, with: value)
            return result
        } else {
            return removeBlock(startTag: startTag, endTag: endTag, in: script)
        }
    }

    private func removeBlock(startTag: String, endTag: String, in script: String) -> String {
        var result = script
        while let startRange = result.range(of: startTag),
              let endRange = result.range(of: endTag, range: startRange.upperBound..<result.endIndex) {
            // Remove from start tag through end tag (including the line)
            let fullRange = startRange.lowerBound..<endRange.upperBound
            // Try to remove the whole line including newline
            var removeRange = fullRange
            if let lineEnd = result.range(of: "\n", range: endRange.upperBound..<result.endIndex) {
                removeRange = startRange.lowerBound..<lineEnd.upperBound
            }
            result.removeSubrange(removeRange)
        }
        return result
    }

    /// Embedded fallback template
    private func embeddedTemplate() -> String {
        """
        import vapoursynth as vs
        import havsfunc as haf

        core = vs.core
        clip = core.ffms2.Source(source=r"{{INPUT_PATH}}")

        import sys
        print(f"INPUT_INFO:frames={clip.num_frames},fps_num={clip.fps.numerator},fps_den={clip.fps.denominator}", file=sys.stderr)

        clip = haf.QTGMC(
            clip,
            Preset="{{PRESET}}",
        {{#TFF}}
            TFF={{TFF}},
        {{/TFF}}
        {{#FPS_DIVISOR}}
            FPSDivisor={{FPS_DIVISOR}},
        {{/FPS_DIVISOR}}
        )

        clip.set_output()
        """
    }
}
