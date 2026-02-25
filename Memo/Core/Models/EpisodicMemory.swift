import Foundation
import SwiftData

/// Episodic memory — narrative summary derived from events
/// Aligned with EverMemOS memory_type: "episodic_memory"
@Model
final class EpisodicMemory {
    @Attribute(.unique) var memoryID: String
    var subject: String
    var summary: String
    var episode: String
    var participants: String  // comma-separated
    var memcellEventIDList: String  // comma-separated event IDs
    var createdAt: Date

    init(
        memoryID: String = UUID().uuidString,
        subject: String,
        summary: String,
        episode: String = "",
        participants: String = "",
        memcellEventIDList: String = "",
        createdAt: Date = Date()
    ) {
        self.memoryID = memoryID
        self.subject = subject
        self.summary = summary
        self.episode = episode
        self.participants = participants
        self.memcellEventIDList = memcellEventIDList
        self.createdAt = createdAt
    }
}
