import Foundation
import SwiftData

/// 每日记忆练习服务 — 管理卡片池、生成每日练习、记录结果
@Observable @MainActor
final class DailyMemoryService {

    /// 今日是否有未完成的练习（用于小红点提示）
    var hasPendingPractice = true

    // MARK: - 1. 刷新卡片池

    /// 从 CareContact / SpatialAnchor / MedicationPlan 同步卡片，去重 + 清理孤儿
    func refreshCardPool(context: ModelContext) {
        let existingCards = (try? context.fetch(FetchDescriptor<MemoryCard>())) ?? []
        var sourceKeys = Set(existingCards.map { "\($0.sourceType)_\($0.sourceID)" })

        // --- CareContact → person 卡片 ---
        let contacts = (try? context.fetch(FetchDescriptor<CareContact>())) ?? []
        for contact in contacts {
            let key = "CareContact_\(contact.contactID)"
            if sourceKeys.contains(key) { continue }
            let card = MemoryCard(
                category: .person,
                question: String(localized: "你的\(contact.relation)叫什么名字？"),
                answer: contact.confirmationName,
                sourceType: "CareContact",
                sourceID: contact.contactID
            )
            context.insert(card)
            sourceKeys.insert(key)
        }

        // --- SpatialAnchor → item 卡片 ---
        let anchors = (try? context.fetch(FetchDescriptor<SpatialAnchor>())) ?? []
        let rooms = (try? context.fetch(FetchDescriptor<RoomProfile>())) ?? []
        let roomMap = Dictionary(uniqueKeysWithValues: rooms.map { ($0.roomID, $0) })

        for anchor in anchors {
            let key = "SpatialAnchor_\(anchor.anchorID)"
            if sourceKeys.contains(key) { continue }
            let roomName: String
            if let rid = anchor.roomID, let room = roomMap[rid] {
                roomName = room.displayName
            } else {
                roomName = String(localized: "未知位置")
            }
            let card = MemoryCard(
                category: .item,
                question: String(localized: "\(anchor.emoji) \(anchor.itemName)放在哪里了？"),
                answer: roomName,
                sourceType: "SpatialAnchor",
                sourceID: anchor.anchorID
            )
            context.insert(card)
            sourceKeys.insert(key)
        }

        // --- MedicationPlan → medication 卡片 ---
        let plans = (try? context.fetch(FetchDescriptor<MedicationPlan>())) ?? []
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"

        for plan in plans {
            let key = "MedicationPlan_\(plan.planID)"
            if sourceKeys.contains(key) { continue }
            let card = MemoryCard(
                category: .medication,
                question: String(localized: "\(plan.medicationName)什么时候吃？"),
                answer: String(localized: "每天 \(timeFormatter.string(from: plan.scheduledTime))"),
                sourceType: "MedicationPlan",
                sourceID: plan.planID
            )
            context.insert(card)
            sourceKeys.insert(key)
        }

        // --- 清理孤儿卡片（source 已被删除的非 custom 卡片）---
        let contactIDs = Set(contacts.map(\.contactID))
        let anchorIDs = Set(anchors.map(\.anchorID))
        let planIDs = Set(plans.map(\.planID))

        for card in existingCards {
            if card.sourceType == "custom" { continue }
            let orphan: Bool
            switch card.sourceType {
            case "CareContact": orphan = !contactIDs.contains(card.sourceID)
            case "SpatialAnchor": orphan = !anchorIDs.contains(card.sourceID)
            case "MedicationPlan": orphan = !planIDs.contains(card.sourceID)
            default: orphan = false
            }
            if orphan {
                context.delete(card)
            }
        }

        try? context.save()
    }

    // MARK: - 2. 生成每日练习

    /// 间隔重复选卡：优先 consecutiveCorrect 低 + lastPracticedAt 久远，取 3-5 张
    func generateDailySession(context: ModelContext) -> [MemoryCard] {
        refreshCardPool(context: context)

        let descriptor = FetchDescriptor<MemoryCard>(
            predicate: #Predicate { $0.isEnabled }
        )
        let allCards = (try? context.fetch(descriptor)) ?? []
        guard !allCards.isEmpty else { return [] }

        // 排序：consecutiveCorrect 升序 → lastPracticedAt 升序（nil 最优先）
        let sorted = allCards.sorted { a, b in
            if a.consecutiveCorrect != b.consecutiveCorrect {
                return a.consecutiveCorrect < b.consecutiveCorrect
            }
            switch (a.lastPracticedAt, b.lastPracticedAt) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (da?, db?): return da < db
            }
        }

        let count = min(max(3, allCards.count), 5)
        return Array(sorted.prefix(count))
    }

    // MARK: - 3. 记录结果

    /// 更新卡片统计 + 追加 session 结果
    func recordOutcome(card: MemoryCard, outcome: PracticeOutcome, session: PracticeSession, context: ModelContext) {
        // 更新卡片
        card.lastPracticedAt = Date()
        switch outcome {
        case .correct:
            card.correctCount += 1
            card.consecutiveCorrect += 1
        case .incorrect:
            card.incorrectCount += 1
            card.consecutiveCorrect = 0
        case .skipped:
            break
        }

        // 追加 session 结果
        session.resultCardIDs.append(card.cardID)
        session.resultOutcomes.append(outcome.rawValue)
        if outcome == .correct {
            session.correctCount += 1
        }

        try? context.save()
    }

    /// 完成练习 session
    func completeSession(_ session: PracticeSession, context: ModelContext) {
        session.completedAt = Date()
        try? context.save()
        checkPendingPractice(context: context)
    }

    /// 检查今日是否还有未完成练习
    func checkPendingPractice(context: ModelContext) {
        let today = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<PracticeSession>(
            predicate: #Predicate { $0.startedAt >= today && $0.completedAt != nil }
        )
        let completedToday = (try? context.fetch(descriptor))?.count ?? 0
        hasPendingPractice = completedToday == 0
    }
}
