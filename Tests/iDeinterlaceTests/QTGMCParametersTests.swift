import XCTest
@testable import iDeinterlaceShared

final class QTGMCParametersTests: XCTestCase {

    func testDefaultInitialization() {
        let params = QTGMCParameters()

        XCTAssertEqual(params.preset, .slower)
        XCTAssertEqual(params.inputType, 0)
        XCTAssertNil(params.tff)
        XCTAssertEqual(params.fpsDivisor, 1)
        XCTAssertEqual(params.rep1, 0)
        XCTAssertTrue(params.repChroma)
    }

    func testPresetFactory() {
        let params = QTGMCParameters.fromPreset(.fast)

        XCTAssertEqual(params.preset, .fast)
    }

    func testJSONEncodeDecode() throws {
        var original = QTGMCParameters()
        original.preset = .slow
        original.tff = true
        original.fpsDivisor = 2
        original.sharpness = 0.5

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(QTGMCParameters.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    func testOptionalParametersEncoding() throws {
        var params = QTGMCParameters()
        params.tr0 = 2
        params.tr1 = nil
        params.sharpness = 1.0

        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"tr0\":2"))
        XCTAssertTrue(json.contains("\"sharpness\":1"))
    }
}

final class VideoJobTests: XCTestCase {

    func testJobCreation() {
        let job = VideoJob(
            inputPath: "/input/video.mov",
            outputPath: "/output/video.mp4"
        )

        XCTAssertEqual(job.inputPath, "/input/video.mov")
        XCTAssertEqual(job.outputPath, "/output/video.mp4")
        XCTAssertEqual(job.qtgmcParameters.preset, .slower)
    }

    func testJobJSONRoundTrip() throws {
        let job = VideoJob(
            inputPath: "/test/input.mov",
            outputPath: "/test/output.mp4",
            qtgmcParameters: QTGMCParameters.fromPreset(.medium),
            encodingSettings: EncodingSettings()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(job)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VideoJob.self, from: data)

        XCTAssertEqual(job.id, decoded.id)
        XCTAssertEqual(job.inputPath, decoded.inputPath)
        XCTAssertEqual(job.outputPath, decoded.outputPath)
    }
}

final class ProgressInfoTests: XCTestCase {

    func testProgressCalculation() {
        let progress = ProgressInfo(frame: 250, totalFrames: 1000, fps: 50.0, eta: 15.0)

        XCTAssertEqual(progress.progress, 0.25)
        XCTAssertEqual(progress.percentComplete, 25)
    }

    func testETAFormatting() {
        // Seconds only
        var progress = ProgressInfo(frame: 0, totalFrames: 100, fps: 10, eta: 45)
        XCTAssertEqual(progress.etaFormatted, "45s")

        // Minutes and seconds
        progress = ProgressInfo(frame: 0, totalFrames: 100, fps: 10, eta: 125)
        XCTAssertEqual(progress.etaFormatted, "2m 05s")

        // Hours, minutes, seconds
        progress = ProgressInfo(frame: 0, totalFrames: 100, fps: 10, eta: 3725)
        XCTAssertEqual(progress.etaFormatted, "1h 02m 05s")
    }

    func testFPSFormatting() {
        let progress = ProgressInfo(frame: 100, totalFrames: 1000, fps: 45.67, eta: 20)
        XCTAssertEqual(progress.fpsFormatted, "45.7 fps")
    }
}
