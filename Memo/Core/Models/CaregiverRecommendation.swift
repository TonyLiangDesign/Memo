import Foundation
import SwiftData

@Model
final class CaregiverRecommendation {
    @Attribute(.unique) var id: String
    var type: RecommendationType
    var priority: RecommendationPriority
    var confidence: Float

    var title: String
    var context: String
    var suggestion: String

    var evidenceIDs: [String]
    var evidenceType: RecommendationEvidenceType

    var detectedAt: Date
    var timeWindow: RecommendationTimeWindow
    var status: RecommendationStatus

    var acceptedAt: Date?
    var dismissedAt: Date?
    var dismissReason: String?
    var caregiverNotes: String?

    init(id: String, type: RecommendationType, priority: RecommendationPriority, confidence: Float,
         title: String, context: String, suggestion: String,
         evidenceIDs: [String], evidenceType: RecommendationEvidenceType,
         detectedAt: Date, timeWindow: RecommendationTimeWindow, status: RecommendationStatus) {
        self.id = id
        self.type = type
        self.priority = priority
        self.confidence = confidence
        self.title = title
        self.context = context
        self.suggestion = suggestion
        self.evidenceIDs = evidenceIDs
        self.evidenceType = evidenceType
        self.detectedAt = detectedAt
        self.timeWindow = timeWindow
        self.status = status
    }
}

enum RecommendationType: String, Codable {
    case repeatedQuestion
    case missedRoutine
    case emotionalDistress
    case memoryReinforcement
    case spatialConfusion
    case socialIsolation
}

enum RecommendationPriority: String, Codable, Comparable {
    case high, medium, low

    static func < (lhs: RecommendationPriority, rhs: RecommendationPriority) -> Bool {
        let order: [RecommendationPriority] = [.high, .medium, .low]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

enum RecommendationTimeWindow: String, Codable {
    case today, thisWeek, thisMonth
}

enum RecommendationStatus: String, Codable {
    case pending, accepted, dismissed, snoozed
}

enum RecommendationEvidenceType: String, Codable {
    case memoryEvent, eventLog, medication, foresight, spatial
}
