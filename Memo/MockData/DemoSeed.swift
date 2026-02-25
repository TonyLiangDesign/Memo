import Foundation
import SwiftData

// MARK: - DemoSeedable Protocol

/// 让每个需要演示数据的模型自管种子数据
protocol DemoSeedable {
    /// 生成演示数据并插入 context，返回已插入的实例供后续模型引用
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [Self]
}

/// 跨模型依赖传递：前序模型种子后的引用存入此处，后续模型可读取
final class DemoRefs {
    var rooms: [RoomProfile] = []
    var contacts: [CareContact] = []
    var plans: [MedicationPlan] = []
    var events: [MemoryEvent] = []
    var cards: [MemoryCard] = []
}

// MARK: - DemoSeed Orchestrator

/// One-tap demo data injection for testing
struct DemoSeed {

    /// 注入时需要清除的模型类型（不含 Room、SpatialAnchor、CareContact）
    private static let seededModelTypes: [any PersistentModel.Type] = [
        MemoryEvent.self, EpisodicMemory.self, EventLog.self,
        Foresight.self, MedicationPlan.self,
        MemoryCard.self, PracticeSession.self,
        CaregiverRecommendation.self,
    ]

    static func seed(context: ModelContext) {
        // 1. 只清除要重新注入的数据（保留 Room、SpatialAnchor、CareContact）
        for type in seededModelTypes {
            try? context.delete(model: type)
        }

        // 2. 读取已有的 Room 和 Contact 作为引用
        let refs = DemoRefs()
        refs.rooms = (try? context.fetch(FetchDescriptor<RoomProfile>())) ?? []
        refs.contacts = (try? context.fetch(FetchDescriptor<CareContact>())) ?? []

        // 3. 注入 plans + today 相关数据
        MedicationPlan.seedDemo(context: context, refs: refs)
        Foresight.seedDemo(context: context, refs: refs)
        MemoryEvent.seedDemo(context: context, refs: refs)
        EpisodicMemory.seedDemo(context: context, refs: refs)
        CaregiverRecommendation.seedDemo(context: context, refs: refs)
        MemoryCard.seedDemo(context: context, refs: refs)
        PracticeSession.seedDemo(context: context, refs: refs)

        try? context.save()

        // 4. 自动从联系人/物品/用药生成关联卡片
        DailyMemoryService().refreshCardPool(context: context)
    }
}

// MARK: - MedicationPlan Demo

extension MedicationPlan: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [MedicationPlan] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let items: [(String, Int, Int, Bool, Bool)] = [
            // (药名, 时, 分, 每日重复, 已确认)
            ("降压药",  20, 0, true,  false),
            ("阿司匹林", 8, 0, true,  true),
            ("维生素D",  12, 30, true, false),
        ]

        var plans: [MedicationPlan] = []
        for (name, hour, minute, repeats, confirmed) in items {
            let time = cal.date(bySettingHour: hour, minute: minute, second: 0, of: today)!
            let plan = MedicationPlan(
                medicationName: name,
                scheduledTime: time,
                windowMinutes: 30
            )
            plan.repeatDaily = repeats
            if confirmed {
                plan.isConfirmed = true
                plan.confirmedAt = time.addingTimeInterval(600) // 确认于计划后 10 分钟
            }
            context.insert(plan)
            plans.append(plan)
        }

        refs.plans = plans
        return plans
    }
}

// MARK: - Foresight Demo

extension Foresight: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [Foresight] {
        var foresights: [Foresight] = []
        for plan in refs.plans {
            let f = Foresight(
                content: "服用\(plan.medicationName)",
                evidence: "照护者创建的用药计划",
                startTime: plan.scheduledTime.addingTimeInterval(-1800),
                endTime: plan.scheduledTime,
                parentType: "medication_plan",
                parentID: plan.planID
            )
            context.insert(f)
            foresights.append(f)
        }
        return foresights
    }
}

// MARK: - CareContact Demo

extension CareContact: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [CareContact] {
        let data: [(String, String, String, String)] = [
            ("女儿",  "Annie",  "+64 21 123 4567", "安妮,annie,我女儿"),
            ("儿子",  "小明",   "+86 138 0000 1234", "明明,我儿子"),
            ("老伴",  "张阿姨",  "+86 139 0000 5678", "老张,张姐"),
            ("护工",  "李姐",   "+86 135 0000 9999", "小李,李护工"),
        ]
        var contacts: [CareContact] = []
        for (relation, name, phone, aliases) in data {
            let c = CareContact(relation: relation, realName: name, phoneNumber: phone, aliases: aliases)
            context.insert(c)
            contacts.append(c)
        }
        refs.contacts = contacts
        return contacts
    }
}

// MARK: - RoomProfile Demo

extension RoomProfile: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [RoomProfile] {
        let data: [(String, String, RoomStatus)] = [
            ("客厅", "📺", .ready),
            ("卧室", "🛏️", .ready),
            ("厨房", "🍳", .ready),
        ]
        var rooms: [RoomProfile] = []
        for (name, emoji, status) in data {
            let room = RoomProfile(name: name, emoji: emoji, status: status)
            if status == .ready { room.lastScannedAt = Date() }
            context.insert(room)
            rooms.append(room)
        }
        refs.rooms = rooms
        return rooms
    }
}

// MARK: - SpatialAnchor Demo

extension SpatialAnchor: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [SpatialAnchor] {
        let livingRoomID = refs.rooms.first?.roomID
        let bedroomID = refs.rooms.count > 1 ? refs.rooms[1].roomID : nil
        let kitchenID = refs.rooms.count > 2 ? refs.rooms[2].roomID : nil

        let items: [(String, String, String?)] = [
            ("钥匙",  "🔑", livingRoomID),
            ("眼镜",  "👓", bedroomID),
            ("遥控器", "📱", livingRoomID),
            ("药盒",  "💊", kitchenID),
            ("手机",  "📲", bedroomID),
        ]
        var anchors: [SpatialAnchor] = []
        for (name, emoji, roomID) in items {
            let a = SpatialAnchor(
                anchorID: UUID().uuidString,
                itemName: name, emoji: emoji,
                posX: 0, posY: 0, posZ: 0,
                rotX: 0, rotY: 0, rotZ: 0, rotW: 1,
                confidence: 0.95, mappingStatus: "mapped",
                roomID: roomID
            )
            context.insert(a)
            anchors.append(a)
        }
        return anchors
    }
}

// MARK: - MemoryEvent Demo

extension MemoryEvent: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [MemoryEvent] {
        let data: [(String, MemoryEventType, ReviewStatus, TimeInterval, String?)] = [
            // (内容, 类型, 审核状态, 距现在秒数, 更正内容)
            ("从冰箱拿了水果",       .action,     .pendingReview, -1200,  nil),
            ("去公园散步了半小时",    .action,     .pendingReview, -3600,  nil),
            ("吃了早饭",            .action,     .approved,      -7200,  nil),
            ("吃了降压药",          .medication, .approved,      -10800, nil),
            ("我女儿叫什么名字？",   .query,      .pendingReview, -600,   nil),
            ("刚才把钥匙放桌上了",   .action,     .corrected,     -5400,  "把钥匙放在客厅茶几上了"),
            ("今天星期几？",        .query,      .pendingReview, -900,   nil),
        ]

        var events: [MemoryEvent] = []
        for (content, type, review, offset, correction) in data {
            let event = MemoryEvent(
                deviceTime: Date().addingTimeInterval(offset),
                content: content,
                eventType: type,
                reviewStatus: review
            )
            if let correction {
                event.correctedContent = correction
                event.correctionReason = "位置描述不够具体"
            }
            context.insert(event)

            let log = EventLog(
                atomicFact: correction ?? content,
                parentType: "memory_event",
                parentID: event.eventID
            )
            context.insert(log)
            events.append(event)
        }
        refs.events = events
        return events
    }
}

// MARK: - EpisodicMemory Demo

extension EpisodicMemory: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [EpisodicMemory] {
        let items: [(String, String, String)] = [
            ("上午散步", "患者上午去公园散步了半小时，回来后心情不错", "散步,公园,运动"),
            ("午餐时光", "患者中午和护工一起吃了午饭，胃口比昨天好", "午餐,饮食,护工"),
        ]
        let eventIDs = refs.events.map(\.eventID)
        var memories: [EpisodicMemory] = []
        for (i, (subject, summary, participants)) in items.enumerated() {
            let linkedIDs = eventIDs.indices.contains(i) ? eventIDs[i] : ""
            let em = EpisodicMemory(
                subject: subject,
                summary: summary,
                participants: participants,
                memcellEventIDList: linkedIDs,
                createdAt: Date().addingTimeInterval(Double(-3600 * (i + 1)))
            )
            context.insert(em)
            memories.append(em)
        }
        return memories
    }
}

// MARK: - CaregiverRecommendation Demo

extension CaregiverRecommendation: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [CaregiverRecommendation] {
        let eventIDs = refs.events.map(\.eventID)

        let items: [(RecommendationType, RecommendationPriority, Float,
                      String, String, String,
                      RecommendationEvidenceType, RecommendationTimeWindow)] = [
            (.repeatedQuestion, .high, 0.85,
             "患者今天重复询问「今天星期几」",
             "今天 9:30、10:15 共 2 次询问相同问题",
             "建议：\n1. 在显眼位置放置日历或白板\n2. 将此信息加入每日回顾\n3. 如持续重复，建议就医评估",
             .eventLog, .today),

            (.missedRoutine, .high, 0.9,
             "今天 20:00 的降压药可能未服用",
             "计划时间 20:00，当前未找到确认记录",
             "建议：\n1. 温和提醒患者服药\n2. 如已服用，请在 App 中补记录\n3. 考虑设置更明显的提醒方式",
             .medication, .today),

            (.memoryReinforcement, .medium, 0.7,
             "患者持续无法回忆「你住在哪个城市」",
             "该卡片已答错 4 次，连续正确 0 次",
             "建议：\n1. 在日常对话中更频繁地提及相关信息\n2. 在家中放置视觉提示（照片、标签）\n3. 考虑调整练习难度或更换问法",
             .memoryEvent, .thisWeek),

            (.emotionalDistress, .medium, 0.65,
             "患者今天表现出困扰情绪",
             "在 1 次交互中检测到负面情绪关键词",
             "建议：\n1. 找时间温和询问感受\n2. 检查是否有未满足的需求\n3. 如持续，考虑专业心理支持",
             .eventLog, .today),

            (.socialIsolation, .low, 0.5,
             "患者本周与家人联系较少",
             "本周仅记录 1 次与家人相关的活动",
             "建议：\n1. 安排一次视频通话\n2. 回顾家庭照片\n3. 鼓励参加社区活动",
             .eventLog, .thisWeek),
        ]

        var recs: [CaregiverRecommendation] = []
        for (type, priority, confidence, title, ctx, suggestion, evType, window) in items {
            let evidenceID = eventIDs.isEmpty ? UUID().uuidString : eventIDs[recs.count % eventIDs.count]
            let rec = CaregiverRecommendation(
                id: UUID().uuidString,
                type: type,
                priority: priority,
                confidence: confidence,
                title: title,
                context: ctx,
                suggestion: suggestion,
                evidenceIDs: [evidenceID],
                evidenceType: evType,
                detectedAt: Date().addingTimeInterval(Double(-300 * recs.count)),
                timeWindow: window,
                status: .pending
            )
            context.insert(rec)
            recs.append(rec)
        }
        return recs
    }
}

// MARK: - MemoryCard Demo

extension MemoryCard: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [MemoryCard] {
        let cardsData: [(String, String, Int, Int, Int)] = [
            // (问题, 答案, 正确次数, 错误次数, 连续正确)
            ("今天是星期几？",     "请看日历",  3, 1, 2),
            ("你住在哪个城市？",   "奥克兰",   1, 4, 0),
            ("你家的门牌号是多少？", "42号",    0, 0, 0),
            ("你的医生叫什么？",   "王医生",   2, 2, 1),
        ]

        var cards: [MemoryCard] = []
        for (question, answer, correct, incorrect, consecutive) in cardsData {
            let card = MemoryCard(category: .custom, question: question, answer: answer, sourceType: "custom")
            card.correctCount = correct
            card.incorrectCount = incorrect
            card.consecutiveCorrect = consecutive
            if correct + incorrect > 0 {
                card.lastPracticedAt = Date().addingTimeInterval(Double(-86400 * cards.count))
            }
            context.insert(card)
            cards.append(card)
        }
        refs.cards = cards
        return cards
    }
}

// MARK: - PracticeSession Demo

extension PracticeSession: DemoSeedable {
    @discardableResult
    static func seedDemo(context: ModelContext, refs: DemoRefs) -> [PracticeSession] {
        let cardIDs = refs.cards.map(\.cardID)
        guard cardIDs.count >= 3 else { return [] }

        let sessionsData: [(Int, Int, [String])] = [
            // (距今天数, 正确数, outcomes)
            (1, 2, ["correct", "incorrect", "correct"]),
            (2, 1, ["correct", "incorrect", "incorrect"]),
            (3, 3, ["correct", "correct", "correct"]),
            (5, 1, ["incorrect", "correct", "incorrect"]),
        ]

        var sessions: [PracticeSession] = []
        for (daysAgo, correctCount, outcomes) in sessionsData {
            let offset = TimeInterval(-daysAgo * 86400)
            let session = PracticeSession(startedAt: Date().addingTimeInterval(offset))
            session.cardCount = outcomes.count
            session.correctCount = correctCount
            session.completedAt = Date().addingTimeInterval(offset + 300)
            session.resultCardIDs = Array(cardIDs.prefix(outcomes.count))
            session.resultOutcomes = outcomes
            context.insert(session)
            sessions.append(session)
        }
        return sessions
    }
}
