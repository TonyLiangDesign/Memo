import Foundation
import SwiftData

/// Atomic fact extracted from events
/// Aligned with EverMemOS memory_type: "event_log"
@Model
final class EventLog {
    @Attribute(.unique) var logID: String
    var atomicFact: String
    var timestamp: Date
    var parentType: String
    var parentID: String
    var userID: String
    var groupID: String

    init(
        logID: String = UUID().uuidString,
        atomicFact: String,
        timestamp: Date = Date(),
        parentType: String = "memory_event",
        parentID: String = "",
        userID: String = "patient",
        groupID: String = "default"
    ) {
        self.logID = logID
        self.atomicFact = atomicFact
        self.timestamp = timestamp
        self.parentType = parentType
        self.parentID = parentID
        self.userID = userID
        self.groupID = groupID
    }
}
