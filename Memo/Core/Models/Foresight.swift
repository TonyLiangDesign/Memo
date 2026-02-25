import Foundation
import SwiftData

/// Forward-looking reminder, aligned with EverMemOS memory_type: "foresight"
/// Used for medication reminders — startTime/endTime define the time window
@Model
final class Foresight {
    @Attribute(.unique) var foresightID: String
    var content: String
    var evidence: String
    var startTime: Date
    var endTime: Date
    var durationDays: Int
    var parentType: String
    var parentID: String
    var createdAt: Date

    init(
        foresightID: String = UUID().uuidString,
        content: String,
        evidence: String = "",
        startTime: Date,
        endTime: Date,
        durationDays: Int = 1,
        parentType: String = "medication_plan",
        parentID: String = "",
        createdAt: Date = Date()
    ) {
        self.foresightID = foresightID
        self.content = content
        self.evidence = evidence
        self.startTime = startTime
        self.endTime = endTime
        self.durationDays = durationDays
        self.parentType = parentType
        self.parentID = parentID
        self.createdAt = createdAt
    }
}
