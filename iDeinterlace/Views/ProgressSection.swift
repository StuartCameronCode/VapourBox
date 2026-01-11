import SwiftUI

/// Progress display during video processing
struct ProgressSection: View {
    let progress: ProgressInfo?
    let state: ProcessingState

    var body: some View {
        VStack(spacing: 12) {
            // Progress bar
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)

            // Stats row
            HStack {
                // Frame count
                if let progress = progress {
                    Text("Frame \(progress.frame) / \(progress.totalFrames)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // FPS
                if let progress = progress, progress.fps > 0 {
                    Label {
                        Text(progress.fpsFormatted)
                    } icon: {
                        Image(systemName: "speedometer")
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                // ETA
                if let progress = progress, progress.eta > 0 {
                    Label {
                        Text(progress.etaFormatted)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .foregroundColor(.secondary)
                }
            }
            .font(.caption)

            // Status text
            Text(statusText)
                .font(.caption)
                .foregroundColor(statusColor)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.1))
        )
    }

    private var progressValue: Double {
        if let progress = progress {
            return progress.progress
        }
        switch state {
        case .processing(let p):
            return p
        default:
            return 0
        }
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "Ready"
        case .preparingJob:
            return "Preparing job..."
        case .processing:
            if let p = progress {
                return "Processing: \(p.percentComplete)%"
            }
            return "Processing..."
        case .cancelling:
            return "Cancelling..."
        case .completed(let success):
            return success ? "Completed successfully" : "Completed with errors"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    private var statusColor: Color {
        switch state {
        case .failed:
            return .red
        case .completed(let success):
            return success ? .green : .orange
        case .cancelling:
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Preview

#Preview("Processing") {
    ProgressSection(
        progress: ProgressInfo(frame: 1234, totalFrames: 5000, fps: 45.2, eta: 83),
        state: .processing(progress: 0.247)
    )
    .padding()
}

#Preview("Preparing") {
    ProgressSection(
        progress: nil,
        state: .preparingJob
    )
    .padding()
}
