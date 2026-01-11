import SwiftUI
import UniformTypeIdentifiers

/// Drag and drop zone for video files
struct DropZoneView: View {
    let fileURL: URL?
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(backgroundColor)
                )

            if let url = fileURL {
                // File loaded state
                VStack(spacing: 8) {
                    Image(systemName: "film.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.accentColor)

                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding()
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)

                    Text("Drop video file here")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text("or click to browse")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onDrop(of: [.fileURL, .movie, .video], isTargeted: $isTargeted) { providers in
            onDrop(providers)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private var backgroundColor: Color {
        if isTargeted {
            return Color.accentColor.opacity(0.1)
        } else if fileURL != nil {
            return Color.secondary.opacity(0.05)
        } else {
            return Color.clear
        }
    }
}

// MARK: - Preview

#Preview("Empty") {
    DropZoneView(fileURL: nil, onDrop: { _ in true })
        .frame(height: 150)
        .padding()
}

#Preview("With File") {
    DropZoneView(
        fileURL: URL(fileURLWithPath: "/Users/test/Videos/sample_video.mov"),
        onDrop: { _ in true }
    )
    .frame(height: 150)
    .padding()
}
