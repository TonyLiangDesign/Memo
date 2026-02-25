import Foundation
import SwiftData

/// Unified event model aligned with EverMemOS POST /memories
/// Fields map: eventID→message_id, deviceTime→create_time, sender, content, groupID→group_id
@Model
final class MemoryEvent {
    @Attribute(.unique) var eventID: String
    var deviceTime: Date
    var sender: String
    var senderName: String
    var role: String
    var content: String
    var groupID: String
    var groupName: String
    var eventType: MemoryEventType
    var syncStatus: SyncStatus
    var reviewStatus: ReviewStatus
    var correctedContent: String?
    var correctionReason: String?

    init(
        eventID: String = UUID().uuidString,
        deviceTime: Date = Date(),
        sender: String = "patient",
        senderName: String = "患者",
        role: String = "user",
        content: String,
        groupID: String = "default",
        groupName: String = "默认",
        eventType: MemoryEventType = .action,
        syncStatus: SyncStatus = .pendingSync,
        reviewStatus: ReviewStatus = .pendingReview
    ) {
        self.eventID = eventID
        self.deviceTime = deviceTime
        self.sender = sender
        self.senderName = senderName
        self.role = role
        self.content = content
        self.groupID = groupID
        self.groupName = groupName
        self.eventType = eventType
        self.syncStatus = syncStatus
        self.reviewStatus = reviewStatus
    }
}

extension MemoryEvent {
    /// Display content: corrected version if available, otherwise original
    var displayContent: String {
        correctedContent ?? content
    }
}
