import Testing
import Foundation
@testable import Memo

struct PatientModeManagerTests {

    private func freshManager() -> PatientModeManager {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return PatientModeManager(defaults: suite)
    }

    @Test func defaultModeIsCombined() {
        let manager = freshManager()
        #expect(manager.mode == .combined)
    }

    @Test func switchToSplit() {
        let manager = freshManager()
        manager.mode = .split
        #expect(manager.mode == .split)
    }

    @Test func switchBackToCombined() {
        let manager = freshManager()
        manager.mode = .split
        manager.mode = .combined
        #expect(manager.mode == .combined)
    }

    @Test func persistenceViaUserDefaults() {
        let suite = UserDefaults(suiteName: "test-persist-\(UUID().uuidString)")!
        let m1 = PatientModeManager(defaults: suite)
        m1.mode = .split

        let m2 = PatientModeManager(defaults: suite)
        #expect(m2.mode == .split)
    }

    @Test func persistenceCombined() {
        let suite = UserDefaults(suiteName: "test-persist-combined-\(UUID().uuidString)")!
        let m1 = PatientModeManager(defaults: suite)
        // Default is combined, switch to split then back
        m1.mode = .split
        m1.mode = .combined

        let m2 = PatientModeManager(defaults: suite)
        #expect(m2.mode == .combined)
    }

    @Test func rawValueRoundTrip() {
        #expect(PatientModeManager.Mode(rawValue: "combined") == .combined)
        #expect(PatientModeManager.Mode(rawValue: "split") == .split)
        #expect(PatientModeManager.Mode(rawValue: "invalid") == nil)
    }
}
