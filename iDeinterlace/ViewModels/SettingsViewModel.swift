import SwiftUI
import iDeinterlaceShared
import Combine

/// Settings view model - manages QTGMC and encoding parameters with persistence
@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - Published State

    @Published var qtgmcParameters: QTGMCParameters {
        didSet { saveSettings() }
    }

    @Published var encodingSettings: EncodingSettings {
        didSet { saveSettings() }
    }

    // MARK: - User Defaults Keys

    private enum Keys {
        static let qtgmcParameters = "qtgmcParameters"
        static let encodingSettings = "encodingSettings"
    }

    // MARK: - Initialization

    init() {
        // Load saved settings or use defaults
        if let data = UserDefaults.standard.data(forKey: Keys.qtgmcParameters),
           let params = try? JSONDecoder().decode(QTGMCParameters.self, from: data) {
            self.qtgmcParameters = params
        } else {
            self.qtgmcParameters = QTGMCParameters()
        }

        if let data = UserDefaults.standard.data(forKey: Keys.encodingSettings),
           let settings = try? JSONDecoder().decode(EncodingSettings.self, from: data) {
            self.encodingSettings = settings
        } else {
            self.encodingSettings = EncodingSettings()
        }
    }

    // MARK: - Actions

    func resetToDefaults() {
        qtgmcParameters = QTGMCParameters()
        encodingSettings = EncodingSettings()
    }

    func applyPreset(_ preset: QTGMCPreset) {
        qtgmcParameters = QTGMCParameters.fromPreset(preset)
    }

    // MARK: - Persistence

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(qtgmcParameters) {
            UserDefaults.standard.set(data, forKey: Keys.qtgmcParameters)
        }
        if let data = try? JSONEncoder().encode(encodingSettings) {
            UserDefaults.standard.set(data, forKey: Keys.encodingSettings)
        }
    }
}
