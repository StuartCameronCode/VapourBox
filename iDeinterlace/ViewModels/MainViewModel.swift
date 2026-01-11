import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Main window view model - manages state and coordinates processing
@MainActor
final class MainViewModel: ObservableObject {
    // MARK: - Published State

    @Published var inputFileURL: URL?
    @Published var outputFileURL: URL?
    @Published var detectedFieldOrder: FieldOrder?
    @Published var videoInfo: FieldOrderDetector.VideoInfo?

    @Published var processingState: ProcessingState = .idle
    @Published var progress: ProgressInfo?
    @Published var logOutput: String = ""

    @Published var showSettings = false
    @Published var showError = false
    @Published var errorMessage = ""

    // MARK: - Dependencies

    let settingsViewModel: SettingsViewModel
    private let workerManager = WorkerManager()
    private let fieldOrderDetector = FieldOrderDetector()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    var canStartProcessing: Bool {
        inputFileURL != nil && outputFileURL != nil && !processingState.isActive
    }

    var inputFileName: String {
        inputFileURL?.lastPathComponent ?? "No file selected"
    }

    var outputFileName: String {
        outputFileURL?.lastPathComponent ?? "No output selected"
    }

    // MARK: - Initialization

    init() {
        self.settingsViewModel = SettingsViewModel()

        // Bind worker manager updates
        workerManager.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.progress = progress
                if let p = progress {
                    self?.processingState = .processing(progress: p.progress)
                }
            }
            .store(in: &cancellables)

        workerManager.$logOutput
            .receive(on: DispatchQueue.main)
            .assign(to: &$logOutput)

        workerManager.onComplete = { [weak self] result in
            Task { @MainActor in
                self?.handleCompletion(result)
            }
        }
    }

    // MARK: - File Handling

    /// Handle file drop from drag and drop
    func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Check for file URL
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, error in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                Task { @MainActor in
                    await self?.setInputFile(url)
                }
            }
            return true
        }

        return false
    }

    /// Set input file and auto-generate output path
    func setInputFile(_ url: URL) async {
        inputFileURL = url

        // Auto-generate output filename
        let outputName = url.deletingPathExtension().lastPathComponent + "_deinterlaced"
        let outputExtension = settingsViewModel.encodingSettings.container.fileExtension
        outputFileURL = url.deletingLastPathComponent()
            .appendingPathComponent(outputName)
            .appendingPathExtension(outputExtension)

        // Detect field order
        await detectFieldOrder(from: url)
    }

    /// Open file picker for input
    func selectInputFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.message = "Select a video file to deinterlace"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await setInputFile(url)
            }
        }
    }

    /// Open file picker for output
    func selectOutputFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.canCreateDirectories = true
        panel.message = "Choose output location"

        if let inputURL = inputFileURL {
            let outputName = inputURL.deletingPathExtension().lastPathComponent + "_deinterlaced"
            panel.nameFieldStringValue = outputName + "." + settingsViewModel.encodingSettings.container.fileExtension
            panel.directoryURL = inputURL.deletingLastPathComponent()
        }

        if panel.runModal() == .OK, let url = panel.url {
            outputFileURL = url
        }
    }

    private func detectFieldOrder(from url: URL) async {
        do {
            let info = try await fieldOrderDetector.detect(from: url.path)
            videoInfo = info
            detectedFieldOrder = info.fieldOrder

            // Auto-set TFF if not already set
            if settingsViewModel.qtgmcParameters.tff == nil {
                settingsViewModel.qtgmcParameters.tff = info.fieldOrder.tffValue
            }
        } catch {
            // Field order detection failed - user will need to set manually
            detectedFieldOrder = .unknown
        }
    }

    // MARK: - Processing

    func startProcessing() {
        guard canStartProcessing,
              let inputURL = inputFileURL,
              let outputURL = outputFileURL else {
            return
        }

        // Ensure TFF is set
        guard settingsViewModel.qtgmcParameters.tff != nil else {
            showError(message: "Please select field order (TFF or BFF) in Settings before processing.")
            return
        }

        processingState = .preparingJob
        progress = nil
        logOutput = ""

        // Create job
        var job = VideoJob(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            qtgmcParameters: settingsViewModel.qtgmcParameters,
            encodingSettings: settingsViewModel.encodingSettings
        )

        job.totalFrames = videoInfo?.totalFrames
        job.inputFrameRate = videoInfo?.frameRate
        job.detectedFieldOrder = detectedFieldOrder

        // Start worker
        do {
            try workerManager.startJob(job)
            processingState = .processing(progress: 0)
        } catch {
            showError(message: error.localizedDescription)
            processingState = .failed(error: error.localizedDescription)
        }
    }

    func cancelProcessing() {
        guard processingState.canCancel else { return }

        processingState = .cancelling
        workerManager.cancel()
    }

    private func handleCompletion(_ result: Result<String, Error>) {
        switch result {
        case .success(let outputPath):
            processingState = .completed(success: true)
            // Could show success notification here

        case .failure(let error):
            if error.localizedDescription.contains("Cancelled") {
                processingState = .idle
            } else {
                processingState = .failed(error: error.localizedDescription)
                showError(message: error.localizedDescription)
            }
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Drop Delegate

extension MainViewModel: DropDelegate {
    nonisolated func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.movie, .video, .fileURL])
    }

    nonisolated func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        Task { @MainActor in
            _ = handleFileDrop(providers)
        }
        return true
    }
}
