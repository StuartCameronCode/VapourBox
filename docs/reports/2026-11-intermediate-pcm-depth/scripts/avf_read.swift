// F4: how AVFoundation (QuickTime, Final Cut Pro) reads a MOV's audio track.
// Prints the track's stream description and writes its samples, decoded by
// AVAssetReader to interleaved 32-bit signed integers, to the second argument,
// so run.sh can compare them byte for byte with ffmpeg's `-f s32le` decode.
//
//   swiftc -O avf_read.swift -o avf_read && ./avf_read in.mov out.s32
import AVFoundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let outPath = CommandLine.arguments[2]
let asset = AVURLAsset(url: url)
let done = DispatchSemaphore(value: 0)

Task {
    defer { done.signal() }
    do {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            print("no audio track"); return
        }
        for fd in try await track.load(.formatDescriptions) {
            let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee
            let id = String(bytes: withUnsafeBytes(of: a.mFormatID.bigEndian) { Array($0) }, encoding: .ascii)!
            let big = a.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
            print("format \(id), \(a.mBitsPerChannel) bits, flags 0x\(String(a.mFormatFlags, radix: 16)) " +
                  "(\(big ? "big" : "little")-endian), \(Int(a.mSampleRate)) Hz, \(a.mChannelsPerFrame) ch")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        reader.startReading()
        var data = Data()
        while let sb = output.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = Data(count: len)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            data.append(chunk)
        }
        try data.write(to: URL(fileURLWithPath: outPath))
        print("decoded \(data.count / 8) frames, reader status \(reader.status == .completed ? "completed" : "\(reader.status.rawValue)")")
    } catch {
        print("error: \(error)")
    }
}
done.wait()
