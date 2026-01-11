import SwiftUI
import AppKit
import iDeinterlaceShared
import UniformTypeIdentifiers

/// Drag and drop zone for video files
struct DropZoneView: View {
    let fileURL: URL?
    let onFileDropped: (URL) -> Void
    var onClickBrowse: (() -> Void)?

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
        .contentShape(Rectangle())
        .onTapGesture {
            onClickBrowse?()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Try to get file URLs from the dragging pasteboard directly
        let pasteboard = NSPasteboard(name: .drag)

        // Read file URLs from pasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let url = urls.first {
            onFileDropped(url)
            return true
        }

        // Fallback: try to read as filenames
        if let filenames = pasteboard.propertyList(forType: .fileURL) as? String,
           let url = URL(string: filenames) {
            onFileDropped(url)
            return true
        }

        // Second fallback: try NSFilenamesPboardType
        if let filenames = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
           let firstFile = filenames.first {
            let url = URL(fileURLWithPath: firstFile)
            onFileDropped(url)
            return true
        }

        return false
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
    DropZoneView(fileURL: nil, onFileDropped: { _ in })
        .frame(height: 150)
        .padding()
}

#Preview("With File") {
    DropZoneView(
        fileURL: URL(fileURLWithPath: "/Users/test/Videos/sample_video.mov"),
        onFileDropped: { _ in }
    )
    .frame(height: 150)
    .padding()
}
