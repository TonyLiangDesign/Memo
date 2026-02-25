import Testing
import Foundation
@testable import Memo

struct ModelInitTests {

    // MARK: - EventLog

    @Test func eventLogDefaults() {
        let log = EventLog(atomicFact: "拿了水果")
        #expect(log.atomicFact == "拿了水果")
        #expect(log.parentType == "memory_event")
        #expect(log.parentID == "")
        #expect(log.userID == "patient")
        #expect(log.groupID == "default")
        #expect(!log.logID.isEmpty)
    }

    @Test func eventLogCustomInit() {
        let log = EventLog(
            atomicFact: "吃了药",
            parentType: "medication_plan",
            parentID: "plan-123",
            userID: "caregiver",
            groupID: "group-1"
        )
        #expect(log.parentType == "medication_plan")
        #expect(log.parentID == "plan-123")
        #expect(log.userID == "caregiver")
        #expect(log.groupID == "group-1")
    }

    // MARK: - MedicationPlan

    @Test func medicationPlanDefaults() {
        let now = Date()
        let plan = MedicationPlan(medicationName: "降压药", scheduledTime: now)
        #expect(plan.medicationName == "降压药")
        #expect(plan.windowMinutes == 30)
        #expect(plan.isConfirmed == false)
        #expect(plan.confirmedAt == nil)
        #expect(plan.repeatDaily == true)
        #expect(plan.createdBy == "caregiver")
        #expect(!plan.planID.isEmpty)
    }

    // MARK: - EpisodicMemory

    @Test func episodicMemoryDefaults() {
        let em = EpisodicMemory(subject: "散步", summary: "去公园散步了")
        #expect(em.subject == "散步")
        #expect(em.summary == "去公园散步了")
        #expect(em.episode == "")
        #expect(em.participants == "")
        #expect(em.memcellEventIDList == "")
        #expect(!em.memoryID.isEmpty)
    }

    // MARK: - Foresight

    @Test func foresightDefaults() {
        let start = Date()
        let end = start.addingTimeInterval(1800)
        let f = Foresight(content: "服用降压药", startTime: start, endTime: end)
        #expect(f.content == "服用降压药")
        #expect(f.evidence == "")
        #expect(f.durationDays == 1)
        #expect(f.parentType == "medication_plan")
        #expect(f.parentID == "")
        #expect(!f.foresightID.isEmpty)
    }
}
