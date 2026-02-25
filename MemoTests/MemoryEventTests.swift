import Testing
import Foundation
@testable import Memo

struct MemoryEventTests {

    @Test func defaultInit() {
        let event = MemoryEvent(content: "测试内容")
        #expect(event.content == "测试内容")
        #expect(event.sender == "patient")
        #expect(event.senderName == "患者")
        #expect(event.role == "user")
        #expect(event.groupID == "default")
        #expect(event.groupName == "默认")
        #expect(event.eventType == .action)
        #expect(event.syncStatus == .pendingSync)
        #expect(event.reviewStatus == .pendingReview)
        #expect(event.correctedContent == nil)
        #expect(event.correctionReason == nil)
    }

    @Test func customInit() {
        let event = MemoryEvent(
            sender: "caregiver",
            senderName: "照护者",
            role: "assistant",
            content: "吃了药",
            eventType: .medication,
            syncStatus: .synced,
            reviewStatus: .approved
        )
        #expect(event.sender == "caregiver")
        #expect(event.eventType == .medication)
        #expect(event.syncStatus == .synced)
        #expect(event.reviewStatus == .approved)
    }

    @Test func eventTypeGetSet() {
        let event = MemoryEvent(content: "test")
        #expect(event.eventType == .action)
        event.eventType = .medication
        #expect(event.eventType == .medication)
    }

    @Test func syncStatusGetSet() {
        let event = MemoryEvent(content: "test")
        #expect(event.syncStatus == .pendingSync)
        event.syncStatus = .synced
        #expect(event.syncStatus == .synced)
    }

    @Test func reviewStatusGetSet() {
        let event = MemoryEvent(content: "test")
        #expect(event.reviewStatus == .pendingReview)
        event.reviewStatus = .corrected
        #expect(event.reviewStatus == .corrected)
    }

    @Test func displayContentWithoutCorrection() {
        let event = MemoryEvent(content: "原始内容")
        #expect(event.displayContent == "原始内容")
    }

    @Test func displayContentWithCorrection() {
        let event = MemoryEvent(content: "原始内容")
        event.correctedContent = "修正后的内容"
        #expect(event.displayContent == "修正后的内容")
    }

    @Test func uniqueEventIDs() {
        let e1 = MemoryEvent(content: "a")
        let e2 = MemoryEvent(content: "b")
        #expect(e1.eventID != e2.eventID)
    }
}
