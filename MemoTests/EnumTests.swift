import Testing
import Foundation
@testable import Memo

struct EnumTests {

    // MARK: - SyncStatus

    @Test func syncStatusRawValues() {
        #expect(SyncStatus.pendingSync.rawValue == "pendingSync")
        #expect(SyncStatus.syncing.rawValue == "syncing")
        #expect(SyncStatus.synced.rawValue == "synced")
        #expect(SyncStatus.failed.rawValue == "failed")
    }

    @Test func syncStatusFromRawValue() {
        #expect(SyncStatus(rawValue: "pendingSync") == .pendingSync)
        #expect(SyncStatus(rawValue: "synced") == .synced)
        #expect(SyncStatus(rawValue: "invalid") == nil)
    }

    @Test func syncStatusCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for status in [SyncStatus.pendingSync, .syncing, .synced, .failed] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(SyncStatus.self, from: data)
            #expect(decoded == status)
        }
    }

    // MARK: - ReviewStatus

    @Test func reviewStatusRawValues() {
        #expect(ReviewStatus.pendingReview.rawValue == "pendingReview")
        #expect(ReviewStatus.approved.rawValue == "approved")
        #expect(ReviewStatus.corrected.rawValue == "corrected")
        #expect(ReviewStatus.deleted.rawValue == "deleted")
    }

    @Test func reviewStatusFromRawValue() {
        #expect(ReviewStatus(rawValue: "approved") == .approved)
        #expect(ReviewStatus(rawValue: "bogus") == nil)
    }

    // MARK: - ActorRole

    @Test func actorRoleCases() {
        let all = ActorRole.allCases
        #expect(all.count == 2)
        #expect(all.contains(.patient))
        #expect(all.contains(.caregiver))
    }

    @Test func actorRoleRawValues() {
        #expect(ActorRole.patient.rawValue == "patient")
        #expect(ActorRole.caregiver.rawValue == "caregiver")
    }

    // MARK: - MemoryEventType

    @Test func memoryEventTypeRawValues() {
        #expect(MemoryEventType.action.rawValue == "action")
        #expect(MemoryEventType.medication.rawValue == "medication")
        #expect(MemoryEventType.query.rawValue == "query")
    }

    @Test func memoryEventTypeFromRawValue() {
        #expect(MemoryEventType(rawValue: "action") == .action)
        #expect(MemoryEventType(rawValue: "medication") == .medication)
        #expect(MemoryEventType(rawValue: "nope") == nil)
    }
}
