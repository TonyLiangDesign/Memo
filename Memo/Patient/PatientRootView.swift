import SwiftUI

/// Routes between combined (LiveModeView) and split (SplitModeView) patient interfaces.
struct PatientRootView: View {
    @Environment(PatientModeManager.self) private var modeManager

    var body: some View {
        switch modeManager.mode {
        case .combined:
            LiveModeView()
        case .split:
            SplitModeView()
        }
    }
}
