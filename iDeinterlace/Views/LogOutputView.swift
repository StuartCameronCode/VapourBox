import SwiftUI
import iDeinterlaceShared

/// Expandable log output section
struct LogSection: View {
    let log: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(
            isExpanded: $isExpanded,
            content: {
                LogOutputView(log: log)
            },
            label: {
                HStack {
                    Text("Log Output")
                        .font(.headline)
                    Spacer()
                    if !log.isEmpty {
                        Text("\(lineCount) lines")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        )
    }

    private var lineCount: Int {
        log.components(separatedBy: .newlines).count
    }
}

/// Scrollable log output view
struct LogOutputView: View {
    let log: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.isEmpty ? "No output yet..." : log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logBottom")
            }
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .onChange(of: log) { _ in
                withAnimation {
                    proxy.scrollTo("logBottom", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("With Log") {
    LogSection(log: """
        [10:30:15] Started worker process
        [10:30:15] Input: /Users/test/video.mov
        [10:30:15] Output: /Users/test/video_deinterlaced.mp4
        [10:30:16] [INFO] Starting QTGMC processing...
        [10:30:16] [INFO] Total frames: 5000
        [10:30:17] Processing frame 100/5000
        [10:30:18] Processing frame 200/5000
        """)
    .padding()
}

#Preview("Empty") {
    LogSection(log: "")
        .padding()
}
