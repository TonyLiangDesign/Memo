import Foundation
import SwiftData

/// 记忆卡片 — 用于每日间隔重复练习
@Model
final class MemoryCard {
    @Attribute(.unique) var cardID: String
    var category: CardCategory
    var question: String
    var answer: String
    var sourceType: String   // "CareContact" / "SpatialAnchor" / "MedicationPlan" / "custom"
    var sourceID: String     // 来源记录 ID，custom 为空
    var isEnabled: Bool
    var lastPracticedAt: Date?
    var correctCount: Int
    var incorrectCount: Int
    var consecutiveCorrect: Int
    var createdAt: Date

    init(
        cardID: String = UUID().uuidString,
        category: CardCategory,
        question: String,
        answer: String,
        sourceType: String,
        sourceID: String = "",
        isEnabled: Bool = true
    ) {
        self.cardID = cardID
        self.category = category
        self.question = question
        self.answer = answer
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.isEnabled = isEnabled
        self.lastPracticedAt = nil
        self.correctCount = 0
        self.incorrectCount = 0
        self.consecutiveCorrect = 0
        self.createdAt = Date()
    }
}

// MARK: - Card Category

enum CardCategory: String, Codable, CaseIterable {
    case person
    case item
    case medication
    case custom
}

// MARK: - Practice Outcome

enum PracticeOutcome: String, Codable {
    case correct
    case incorrect
    case skipped
}
