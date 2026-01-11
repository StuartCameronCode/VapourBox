import XCTest
@testable import iDeinterlaceShared

/// Integration test that runs the full deinterlacing pipeline
/// Uses bundled dependencies from TestBundle for reproducible testing
final class DeinterlaceIntegrationTests: XCTestCase {

    /// Path to Tests directory
    private var testsPath: String {
        let fileURL = URL(fileURLWithPath: #file)
        return fileURL
            .deletingLastPathComponent() // iDeinterlaceTests
            .deletingLastPathComponent() // Tests
            .path
    }

    /// Path to TestBundle containing bundled dependencies
    private var testBundlePath: String {
        testsPath + "/TestBundle"
    }

    /// Path to test resources directory
    private var testResourcesPath: String {
        testsPath + "/TestResources"
    }

    /// Path to the test input file
    private var inputPath: String {
        testResourcesPath + "/interlaced_test.avi"
    }

    /// Path for test output
    private var outputPath: String {
        testResourcesPath + "/deinterlaced_test_output.avi"
    }

    /// Check if TestBundle is set up
    private var isTestBundleSetUp: Bool {
        FileManager.default.fileExists(atPath: testBundlePath + "/.setup-complete")
    }

    /// Path to bundled vspipe
    private var vspipePath: String {
        testBundlePath + "/Helpers/vspipe"
    }

    /// Path to bundled ffmpeg
    private var ffmpegPath: String {
        testBundlePath + "/Helpers/ffmpeg"
    }

    /// Path to the worker executable (built by Swift Package Manager)
    private var workerPath: String? {
        let possiblePaths = [
            // Debug build
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".build/debug/iDeinterlaceWorker")
                .path,
            // Release build
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(".build/release/iDeinterlaceWorker")
                .path
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    override func tearDown() {
        super.tearDown()
        // Clean up output file after test
        try? FileManager.default.removeItem(atPath: outputPath)
        // Clean up ffindex file
        try? FileManager.default.removeItem(atPath: inputPath + ".ffindex")
    }

    /// Test that the worker can deinterlace the test AVI file
    /// Produces a lossless FFV1 encoded AVI at double frame rate (50fps from 25fps interlaced)
    func testDeinterlaceAVI() throws {
        // Skip if TestBundle not set up
        guard isTestBundleSetUp else {
            throw XCTSkip("TestBundle not set up. Run: ./Scripts/setup-test-bundle.sh")
        }

        // Skip if worker not found
        guard let workerExecutable = workerPath else {
            throw XCTSkip("Worker executable not found. Build the package first with: swift build")
        }

        // Verify bundled executables exist
        guard FileManager.default.isExecutableFile(atPath: vspipePath) else {
            throw XCTSkip("Bundled vspipe not found at: \(vspipePath)")
        }
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw XCTSkip("Bundled ffmpeg not found at: \(ffmpegPath)")
        }

        // Verify input file exists
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inputPath),
            "Test input file not found at: \(inputPath)"
        )

        // Create job configuration with lossless FFV1 output
        var params = QTGMCParameters()
        params.preset = .faster  // Use faster preset for tests
        params.tff = true  // Top field first
        params.opencl = true  // Use GPU acceleration

        var encoding = EncodingSettings()
        encoding.codec = .h264  // Base codec (will be overridden)
        encoding.customFFmpegArgs = "-c:v ffv1 -level 3 -an"  // FFV1 lossless, no audio

        let job = VideoJob(
            inputPath: inputPath,
            outputPath: outputPath,
            qtgmcParameters: params,
            encodingSettings: encoding
        )

        // Write job config to temp file
        let configPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_job_\(job.id.uuidString).json")
            .path

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let configData = try encoder.encode(job)
        FileManager.default.createFile(atPath: configPath, contents: configData)

        defer {
            try? FileManager.default.removeItem(atPath: configPath)
        }

        // Start with parent's environment, then override with TestBundle paths
        var env = ProcessInfo.processInfo.environment

        // Clear any conflicting conda/python settings
        env.removeValue(forKey: "CONDA_PREFIX")
        env.removeValue(forKey: "CONDA_DEFAULT_ENV")
        env.removeValue(forKey: "CONDA_EXE")
        env.removeValue(forKey: "CONDA_PYTHON_EXE")
        env.removeValue(forKey: "CONDA_SHLVL")
        env.removeValue(forKey: "CONDA_PROMPT_MODIFIER")

        // Python environment from TestBundle
        let pythonHome = testBundlePath + "/Frameworks/Python.framework/Versions/3.14"
        let pythonPath = testBundlePath + "/PythonPackages:" + pythonHome + "/lib/python3.14/site-packages"

        env["PYTHONHOME"] = pythonHome
        env["PYTHONPATH"] = pythonPath
        env["VAPOURSYNTH_PLUGIN_PATH"] = testBundlePath + "/PlugIns/VapourSynth"
        env["DYLD_LIBRARY_PATH"] = testBundlePath + "/lib"
        env["NNEDI3CL_WEIGHTS_PATH"] = testBundlePath + "/Resources/NNEDI3CL/nnedi3_weights.bin"

        // PATH with bundled executables first
        env["PATH"] = testBundlePath + "/Helpers:/usr/local/bin:/usr/bin:/bin"

        // Run the worker
        let process = Process()
        process.executableURL = URL(fileURLWithPath: workerExecutable)
        process.arguments = ["--config", configPath]
        process.environment = env

        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Run with timeout
        let expectation = XCTestExpectation(description: "Worker completes")

        process.terminationHandler = { _ in
            expectation.fulfill()
        }

        try process.run()

        // Wait up to 5 minutes for deinterlacing
        let result = XCTWaiter.wait(for: [expectation], timeout: 300)

        if result == .timedOut {
            process.terminate()
            XCTFail("Worker timed out after 5 minutes")
            return
        }

        // Check exit code
        let exitCode = process.terminationStatus

        // Read output for debugging
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""

        if exitCode != 0 {
            print("Worker stdout:\n\(stdout)")
            print("Worker stderr:\n\(stderr)")
            XCTFail("Worker exited with code \(exitCode)")
            return
        }

        // Verify output file was created
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputPath),
            "Output file was not created at: \(outputPath)"
        )

        // Verify output file is not empty
        let attrs = try FileManager.default.attributesOfItem(atPath: outputPath)
        let fileSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Output file is empty")

        // Use bundled ffprobe (or system one) to verify frame rate doubled
        let ffprobePath = testBundlePath + "/Helpers/ffprobe"
        let probePath = FileManager.default.isExecutableFile(atPath: ffprobePath)
            ? ffprobePath
            : "/opt/homebrew/bin/ffprobe"

        let probeProcess = Process()
        probeProcess.executableURL = URL(fileURLWithPath: probePath)
        probeProcess.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=r_frame_rate,nb_frames",
            "-of", "csv=p=0",
            outputPath
        ]

        let probePipe = Pipe()
        probeProcess.standardOutput = probePipe
        probeProcess.standardError = FileHandle.nullDevice

        try probeProcess.run()
        probeProcess.waitUntilExit()

        let probeData = probePipe.fileHandleForReading.readDataToEndOfFile()
        let probeOutput = String(data: probeData, encoding: .utf8) ?? ""

        print("FFprobe output: \(probeOutput)")

        // Parse frame rate - should be ~50fps (double the 25fps input)
        let parts = probeOutput.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ",")
        if parts.count >= 1 {
            let fpsStr = parts[0]
            let fpsParts = fpsStr.components(separatedBy: "/")
            if fpsParts.count == 2,
               let num = Double(fpsParts[0]),
               let den = Double(fpsParts[1]) {
                let fps = num / den
                XCTAssertGreaterThan(fps, 45, "Frame rate should be ~50fps, got \(fps)")
                XCTAssertLessThan(fps, 55, "Frame rate should be ~50fps, got \(fps)")
            }
        }

        print("Deinterlacing test passed! Output: \(outputPath)")
    }
}
