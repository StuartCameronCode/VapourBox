import Foundation
import iDeinterlaceShared

/// iDeinterlace Worker Process
/// Executes VapourSynth QTGMC scripts and pipes to FFmpeg for encoding.
/// Communicates with the main app via JSON messages on stdout.

let worker = WorkerApp()
let exitCode = worker.run()
exit(Int32(exitCode))
