import Foundation
import SwiftData
import EverMemOSKit

@Observable @MainActor
final class RecommendationEngine {
    private let client: EverMemOSClient
    private let userID: String

    init(client: EverMemOSClient, userID: String) {
        self.client = client
        self.userID = userID
    }

    // 主入口：生成今日建议
    func generateRecommendations(context: ModelContext) async throws -> [CaregiverRecommendation] {
        // 1. 从 EverMemOS 拉取最近记忆
        let memories = try await fetchRecentMemories()

        // 2. 运行检测器
        var recommendations: [CaregiverRecommendation] = []
        recommendations += await detectRepeatedQuestions(memories)
        recommendations += await detectMissedRoutines(memories, context)
        recommendations += await detectEmotionalDistress(memories)
        recommendations += detectMemoryPracticePatterns(context)

        // 3. 去重 + 排序 + 限制数量
        let deduplicated = deduplicateRecommendations(recommendations)
        let sorted = deduplicated.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.confidence > b.confidence
        }
        let final = Array(sorted.prefix(5))

        // 4. 持久化
        for rec in final {
            context.insert(rec)
        }
        try? context.save()

        return final
    }

    // 拉取最近 7 天的记忆
    private func fetchRecentMemories() async throws -> MemorySnapshot {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 86400)
        let isoFormatter = ISO8601DateFormatter()

        var eventQuery = FetchMemoriesBuilder()
        eventQuery.userId = userID
        eventQuery.memoryType = .eventLog
        eventQuery.startTime = isoFormatter.string(from: sevenDaysAgo)
        eventQuery.pageSize = 100
        eventQuery.page = 1

        var all: [FlexibleMemory] = []
        var currentPage = 1
        while currentPage <= 10 {
            eventQuery.page = currentPage
            let result = try await client.fetchMemories(eventQuery)
            all.append(contentsOf: result.memories)
            if all.count >= result.totalCount || result.memories.isEmpty {
                break
            }
            currentPage += 1
        }
        return MemorySnapshot(events: all)
    }

    // 去重
    private func deduplicateRecommendations(_ recs: [CaregiverRecommendation]) -> [CaregiverRecommendation] {
        var seen: Set<String> = []
        return recs.filter { rec in
            let key = "\(rec.type.rawValue)_\(rec.evidenceIDs.sorted().joined())"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}

struct MemorySnapshot {
    let events: [FlexibleMemory]
}

// MARK: - 检测器实现

extension RecommendationEngine {
    // 检测器 1: 重复提问
    func detectRepeatedQuestions(_ memories: MemorySnapshot) async -> [CaregiverRecommendation] {
        var recommendations: [CaregiverRecommendation] = []
        let today = Calendar.current.startOfDay(for: Date())

        // 提取今天的问题
        let questions = memories.events.filter { event in
            guard let timestamp = event.timestamp,
                  let date = ISO8601DateFormatter().date(from: timestamp) else { return false }
            return date >= today && (event.atomicFact?.contains("?") ?? false)
        }

        // 对每个问题搜索相似的
        for question in questions {
            guard let content = question.atomicFact else { continue }

            var searchQuery = SearchMemoriesBuilder()
            searchQuery.userId = userID
            searchQuery.query = content
            searchQuery.retrieveMethod = .vector
            searchQuery.topK = 10
            searchQuery.startTime = ISO8601DateFormatter().string(from: today)

            guard let results = try? await client.searchMemories(searchQuery) else { continue }

            let repeated = results.memories.filter {
                $0.id != question.id &&
                $0.memoryType == "event_log" &&
                ($0.atomicFact?.contains("?") ?? false)
            }

            if repeated.count >= 2 {
                let rec = CaregiverRecommendation(
                    id: UUID().uuidString,
                    type: .repeatedQuestion,
                    priority: repeated.count >= 4 ? .high : .medium,
                    confidence: min(1.0, Float(repeated.count) / 5.0),
                    title: "患者今天重复询问「\(extractTopic(content))」",
                    context: formatRepeatedContext(question, repeated),
                    suggestion: """
                    建议：
                    1. 在显眼位置放置提示卡片
                    2. 考虑将此信息加入每日回顾
                    3. 如持续重复，建议就医评估
                    """,
                    evidenceIDs: [question.id ?? ""] + repeated.compactMap { $0.id },
                    evidenceType: .eventLog,
                    detectedAt: Date(),
                    timeWindow: .today,
                    status: .pending
                )
                recommendations.append(rec)
            }
        }

        return recommendations
    }

    private func extractTopic(_ content: String) -> String {
        content
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "在哪", with: "")
            .replacingOccurrences(of: "什么时候", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func formatRepeatedContext(_ original: FlexibleMemory, _ similar: [FlexibleMemory]) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        let times = ([original] + similar)
            .compactMap { $0.timestamp }
            .compactMap { ISO8601DateFormatter().date(from: $0) }
            .sorted()
            .map { formatter.string(from: $0) }

        return "今天 \(times.joined(separator: "、")) 共 \(times.count) 次询问"
    }

    // 检测器 2: 遗漏日常
    func detectMissedRoutines(_ memories: MemorySnapshot, _ context: ModelContext) async -> [CaregiverRecommendation] {
        var recommendations: [CaregiverRecommendation] = []
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let descriptor = FetchDescriptor<MedicationPlan>(
            predicate: #Predicate { plan in
                plan.scheduledTime >= today && plan.scheduledTime < tomorrow
            }
        )
        guard let plans = try? context.fetch(descriptor) else { return [] }

        for plan in plans {
            let deadline = plan.scheduledTime.addingTimeInterval(30 * 60)
            if Date() < deadline { continue }

            // 搜索确认记录
            var searchQuery = SearchMemoriesBuilder()
            searchQuery.userId = userID
            searchQuery.query = "服用 \(plan.medicationName)"
            searchQuery.retrieveMethod = .keyword
            searchQuery.startTime = ISO8601DateFormatter().string(from: plan.scheduledTime)
            searchQuery.endTime = ISO8601DateFormatter().string(from: deadline)

            let results = try? await client.searchMemories(searchQuery)
            let confirmed = results?.memories.contains {
                $0.atomicFact?.contains("服用") ?? false
            } ?? false

            if !confirmed {
                let overdue = Date().timeIntervalSince(plan.scheduledTime) / 3600
                let rec = CaregiverRecommendation(
                    id: UUID().uuidString,
                    type: .missedRoutine,
                    priority: .high,
                    confidence: max(0.5, 1.0 - Float(overdue) / 4.0),
                    title: "今天 \(formatTime(plan.scheduledTime)) 的\(plan.medicationName)可能未服用",
                    context: "计划时间 \(formatTime(plan.scheduledTime))，当前未找到确认记录",
                    suggestion: """
                    建议：
                    1. 温和提醒患者
                    2. 如已服用，请在 App 中补记录
                    3. 考虑设置更明显的提醒方式
                    """,
                    evidenceIDs: [plan.id.hashValue.description],
                    evidenceType: .medication,
                    detectedAt: Date(),
                    timeWindow: .today,
                    status: .pending
                )
                recommendations.append(rec)
            }
        }

        return recommendations
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // 检测器 3a: 记忆练习模式（连续答错 → memoryReinforcement 建议）
    func detectMemoryPracticePatterns(_ context: ModelContext) -> [CaregiverRecommendation] {
        var recommendations: [CaregiverRecommendation] = []

        // 查找连续答错 >= 3 次的卡片
        let descriptor = FetchDescriptor<MemoryCard>(
            predicate: #Predicate { $0.isEnabled && $0.incorrectCount >= 3 && $0.consecutiveCorrect == 0 }
        )
        guard let troubleCards = try? context.fetch(descriptor) else { return [] }

        for card in troubleCards {
            let rec = CaregiverRecommendation(
                id: UUID().uuidString,
                type: .memoryReinforcement,
                priority: card.incorrectCount >= 5 ? .high : .medium,
                confidence: min(1.0, Float(card.incorrectCount) / 6.0),
                title: "患者持续无法回忆「\(card.question.prefix(15))…」",
                context: "该卡片已答错 \(card.incorrectCount) 次，连续正确 0 次",
                suggestion: """
                建议：
                1. 在日常对话中更频繁地提及相关信息
                2. 在家中放置视觉提示（照片、标签）
                3. 考虑调整练习难度或更换问法
                """,
                evidenceIDs: [card.cardID],
                evidenceType: .memoryEvent,
                detectedAt: Date(),
                timeWindow: .thisWeek,
                status: .pending
            )
            recommendations.append(rec)
        }

        return recommendations
    }

    // 检测器 3b: 情绪困扰
    func detectEmotionalDistress(_ memories: MemorySnapshot) async -> [CaregiverRecommendation] {
        var recommendations: [CaregiverRecommendation] = []
        let today = Calendar.current.startOfDay(for: Date())

        let distressKeywords = ["困扰", "难过", "害怕", "担心", "不安", "痛苦", "焦虑"]
        let distressEvents = memories.events.filter { event in
            guard let timestamp = event.timestamp,
                  let date = ISO8601DateFormatter().date(from: timestamp),
                  date >= today,
                  let content = event.atomicFact else { return false }
            return distressKeywords.contains { content.contains($0) }
        }

        if !distressEvents.isEmpty {
            let rec = CaregiverRecommendation(
                id: UUID().uuidString,
                type: .emotionalDistress,
                priority: .high,
                confidence: 0.8,
                title: "患者今天表现出困扰情绪",
                context: "在 \(distressEvents.count) 次交互中检测到负面情绪",
                suggestion: """
                建议：
                1. 找时间温和询问感受
                2. 检查是否有未满足的需求
                3. 如持续，考虑专业心理支持
                """,
                evidenceIDs: distressEvents.compactMap { $0.id },
                evidenceType: .eventLog,
                detectedAt: Date(),
                timeWindow: .today,
                status: .pending
            )
            recommendations.append(rec)
        }

        return recommendations
    }
}

