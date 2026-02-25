import Foundation
import SwiftData

/// 每次练习的记录
@Model
final class PracticeSession {
    @Attribute(.unique) var sessionID: String
    var startedAt: Date
    var completedAt: Date?
    var cardCount: Int
    var correctCount: Int
    var resultCardIDs: [String]
    var resultOutcomes: [String]   // PracticeOutcome rawValue 并行数组

    init(
        sessionID: String = UUID().uuidString,
        startedAt: Date = Date(),
        cardCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.completedAt = nil
        self.cardCount = cardCount
        self.correctCount = 0
        self.resultCardIDs = []
        self.resultOutcomes = []
    }
}
