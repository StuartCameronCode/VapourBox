// AVFoundation's view of each file: kCMFormatDescriptionExtension_FieldCount
// and FieldDetail, which QuickTime and Final Cut read. macOS only.
//   swiftc -O -o fields fields.swift && ./fields FILE...
import AVFoundation
import CoreMedia
let sem = DispatchSemaphore(value: 0)
Task {
  for p in CommandLine.arguments.dropFirst() {
    let a = AVURLAsset(url: URL(fileURLWithPath: p))
    do {
      let t = try await a.loadTracks(withMediaType: .video)
      guard let tr = t.first else { print(p, "no video"); continue }
      let fds = try await tr.load(.formatDescriptions)
      for fd in fds {
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let fc = ext[kCMFormatDescriptionExtension_FieldCount as String] ?? "nil"
        let fdt = ext[kCMFormatDescriptionExtension_FieldDetail as String] ?? "nil"
        print(p, "codec=\(CMFormatDescriptionGetMediaSubType(fd))", "FieldCount=\(fc)", "FieldDetail=\(fdt)")
      }
    } catch { print(p, "error", error) }
  }
  sem.signal()
}
sem.wait()
