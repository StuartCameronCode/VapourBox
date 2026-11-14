// Whether AVFoundation (QuickTime, Safari, Final Cut) can decode a file at all:
// reads every video frame through AVAssetReader and prints how many came back,
// the first frame's size, and the mean luma of row 100 (to tell real pictures
// from blank ones). macOS only.
//   swiftc -O -o decode decode.swift && ./decode FILE...
import AVFoundation
import CoreVideo

let sem = DispatchSemaphore(value: 0)
Task {
  for p in CommandLine.arguments.dropFirst() {
    let name = (p as NSString).lastPathComponent
    let asset = AVURLAsset(url: URL(fileURLWithPath: p))
    do {
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        print(name, "no video track"); continue
      }
      let reader = try AVAssetReader(asset: asset)
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      ])
      reader.add(out)
      guard reader.startReading() else {
        print(name, "startReading failed:", reader.error.map { "\($0)" } ?? "?"); continue
      }
      var frames = 0
      var info = ""
      while let sb = out.copyNextSampleBuffer() {
        if frames == 0, let pb = CMSampleBufferGetImageBuffer(sb) {
          CVPixelBufferLockBaseAddress(pb, .readOnly)
          let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
          let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
          let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
          var sum = 0
          for x in 0..<w { sum += Int(base[100 * stride + x]) }
          CVPixelBufferUnlockBaseAddress(pb, .readOnly)
          info = "\(w)x\(h) row100-mean=\(sum / w)"
        }
        frames += 1
      }
      let status = reader.status == .completed ? "completed" : "status=\(reader.status.rawValue) \(reader.error.map { "\($0)" } ?? "")"
      print(name, "frames=\(frames)", info, status)
    } catch {
      print(name, "error", error)
    }
  }
  sem.signal()
}
sem.wait()
