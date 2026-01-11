import SwiftUI
import iDeinterlaceShared

/// Main application window
struct MainWindowView: View {
    @StateObject private var viewModel = MainViewModel()

    var body: some View {
        VStack(spacing: 20) {
            // Input file section
            InputSection(viewModel: viewModel)

            Divider()

            // Output file section
            OutputSection(viewModel: viewModel)

            Divider()

            // Field order indicator
            FieldOrderSection(viewModel: viewModel)

            Spacer()

            // Progress section (shown during processing)
            if viewModel.processingState.isActive {
                ProgressSection(
                    progress: viewModel.progress,
                    state: viewModel.processingState
                )
            }

            // Action buttons
            ActionButtons(viewModel: viewModel)

            // Expandable log output
            LogSection(log: viewModel.logOutput)
        }
        .padding()
        .frame(minWidth: 550, minHeight: 500)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheet(viewModel: viewModel.settingsViewModel)
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage)
        }
    }
}

// MARK: - Input Section

private struct InputSection: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input Video")
                .font(.headline)

            DropZoneView(
                fileURL: viewModel.inputFileURL,
                onDrop: { providers in
                    viewModel.handleFileDrop(providers)
                },
                onClickBrowse: {
                    viewModel.selectInputFile()
                }
            )
            .frame(height: 120)

            HStack {
                if let url = viewModel.inputFileURL {
                    Image(systemName: "film")
                        .foregroundColor(.secondary)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change...") {
                        viewModel.selectInputFile()
                    }
                } else {
                    Button("Select Video File...") {
                        viewModel.selectInputFile()
                    }
                }
            }
        }
    }
}

// MARK: - Output Section

private struct OutputSection: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)

            HStack {
                if let url = viewModel.outputFileURL {
                    Image(systemName: "doc")
                        .foregroundColor(.secondary)
                    Text(url.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("Output location will be auto-generated")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Browse...") {
                    viewModel.selectOutputFile()
                }
                .disabled(viewModel.inputFileURL == nil)
            }
        }
    }
}

// MARK: - Field Order Section

private struct FieldOrderSection: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        HStack {
            Text("Field Order:")
                .foregroundColor(.secondary)

            if let detected = viewModel.detectedFieldOrder {
                Label {
                    Text(detected.displayName)
                } icon: {
                    Image(systemName: fieldOrderIcon(for: detected))
                        .foregroundColor(fieldOrderColor(for: detected))
                }
            } else if viewModel.inputFileURL != nil {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Detecting...")
                    .foregroundColor(.secondary)
            } else {
                Text("--")
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Settings...") {
                viewModel.showSettings = true
            }
        }
    }

    private func fieldOrderIcon(for order: FieldOrder) -> String {
        switch order {
        case .topFieldFirst: return "arrow.up.square"
        case .bottomFieldFirst: return "arrow.down.square"
        case .progressive: return "rectangle.checkered"
        case .unknown: return "questionmark.circle"
        }
    }

    private func fieldOrderColor(for order: FieldOrder) -> Color {
        switch order {
        case .topFieldFirst, .bottomFieldFirst: return .green
        case .progressive: return .blue
        case .unknown: return .orange
        }
    }
}

// MARK: - Action Buttons

private struct ActionButtons: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        HStack {
            Spacer()

            if viewModel.processingState.canCancel {
                Button("Cancel") {
                    viewModel.cancelProcessing()
                }
                .keyboardShortcut(.escape)
            }

            Button(action: {
                viewModel.startProcessing()
            }) {
                HStack {
                    if case .preparingJob = viewModel.processingState {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                    Text("Go")
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStartProcessing)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

// MARK: - Preview

#Preview {
    MainWindowView()
}
