import Testing
import Foundation
@testable import Memo

struct RecordFeatureTests {

    @MainActor
    @Test func initialPhaseIsReady() {
        let feature = RecordFeature()
        #expect(feature.phase == .ready)
    }

    @MainActor
    @Test func phaseCanBeSetToError() {
        let feature = RecordFeature()
        feature.phase = .error("test error")
        #expect(feature.phase == .error("test error"))
    }

    @MainActor
    @Test func phaseCanBeResetToReady() {
        let feature = RecordFeature()
        feature.phase = .error("some error")
        feature.phase = .ready
        #expect(feature.phase == .ready)
    }

    @MainActor
    @Test func phaseCapturingTransition() {
        let feature = RecordFeature()
        feature.phase = .capturing
        #expect(feature.phase == .capturing)
    }

    @MainActor
    @Test func phaseSavingTransition() {
        let feature = RecordFeature()
        feature.phase = .saving
        #expect(feature.phase == .saving)
    }

    @MainActor
    @Test func phaseSuccessCarriesName() {
        let feature = RecordFeature()
        feature.phase = .success("钥匙")
        if case .success(let name) = feature.phase {
            #expect(name == "钥匙")
        } else {
            Issue.record("Expected .success phase")
        }
    }

    @MainActor
    @Test func phaseEquality() {
        #expect(RecordFeature.Phase.ready == RecordFeature.Phase.ready)
        #expect(RecordFeature.Phase.capturing == RecordFeature.Phase.capturing)
        #expect(RecordFeature.Phase.saving == RecordFeature.Phase.saving)
        #expect(RecordFeature.Phase.error("a") == RecordFeature.Phase.error("a"))
        #expect(RecordFeature.Phase.error("a") != RecordFeature.Phase.error("b"))
        #expect(RecordFeature.Phase.success("x") == RecordFeature.Phase.success("x"))
        #expect(RecordFeature.Phase.success("x") != RecordFeature.Phase.success("y"))
        #expect(RecordFeature.Phase.ready != RecordFeature.Phase.capturing)
    }
}
