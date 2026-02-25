import Foundation
import SwiftData

/// Medication plan — UI state for tracking medication schedules
@Model
final class MedicationPlan {
    @Attribute(.unique) var planID: String
    var medicationName: String
    var scheduledTime: Date
    var windowMinutes: Int
    var isConfirmed: Bool
    var confirmedAt: Date?
    var repeatDaily: Bool
    var createdBy: String
    var createdAt: Date

    init(
        planID: String = UUID().uuidString,
        medicationName: String,
        scheduledTime: Date,
        windowMinutes: Int = 30,
        isConfirmed: Bool = false,
        confirmedAt: Date? = nil,
        repeatDaily: Bool = true,
        createdBy: String = "caregiver",
        createdAt: Date = Date()
    ) {
        self.planID = planID
        self.medicationName = medicationName
        self.scheduledTime = scheduledTime
        self.windowMinutes = windowMinutes
        self.isConfirmed = isConfirmed
        self.confirmedAt = confirmedAt
        self.repeatDaily = repeatDaily
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}
