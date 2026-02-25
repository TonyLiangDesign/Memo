import Foundation

/// Manages the patient interface mode — combined (AR + all features) or split (separate feature pages).
@Observable
final class PatientModeManager {
    enum Mode: String, CaseIterable {
        case combined
        case split
    }

    var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: key) }
    }

    private let defaults: UserDefaults
    private let key = "patientInterfaceMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: key),
           let restored = Mode(rawValue: saved) {
            mode = restored
        } else {
            mode = .combined
        }
    }
}
