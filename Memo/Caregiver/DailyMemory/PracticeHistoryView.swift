import SwiftUI
import SwiftData

/// 照护者端：练习历史记录
struct PracticeHistoryView: View {
    @Query(sort: \PracticeSession.startedAt, order: .reverse)
    private var sessions: [PracticeSession]

    @Query private var allCards: [MemoryCard]

    /// cardID → MemoryCard 快速查找
    private var cardMap: [String: MemoryCard] {
        Dictionary(uniqueKeysWithValues: allCards.map { ($0.cardID, $0) })
    }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "暂无练习记录",
                    systemImage: "clock",
                    description: Text("患者完成练习后会在这里显示")
                )
            } else {
                ForEach(sessions, id: \.sessionID) { session in
                    sessionRow(session)
                }
            }
        }
        // navigationTitle 由父视图统一管理
    }

    private func sessionRow(_ session: PracticeSession) -> some View {
        DisclosureGroup {
            ForEach(Array(zip(session.resultCardIDs, session.resultOutcomes).enumerated()), id: \.offset) { _, pair in
                let card = cardMap[pair.0]
                HStack {
                    Image(systemName: outcomeIcon(pair.1))
                        .foregroundStyle(outcomeColor(pair.1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card?.question ?? "已删除的卡片")
                            .font(.subheadline)
                        if let answer = card?.answer {
                            Text(answer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(outcomeLabel(pair.1))
                        .font(.caption.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(outcomeColor(pair.1).opacity(0.15), in: Capsule())
                        .foregroundStyle(outcomeColor(pair.1))
                }
                .padding(.vertical, 2)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formatDate(session.startedAt))
                        .font(.subheadline.bold())
                    HStack(spacing: 8) {
                        Text("\(session.cardCount) 题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if session.completedAt != nil {
                            let rate = session.cardCount > 0
                                ? Double(session.correctCount) / Double(session.cardCount)
                                : 0
                            Text("正确率 \(Int(rate * 100))%")
                                .font(.caption)
                                .foregroundStyle(rate >= 0.7 ? .green : .orange)
                        } else {
                            Text("未完成")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                Spacer()
                Text("\(session.correctCount)/\(session.cardCount)")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private func outcomeIcon(_ outcome: String) -> String {
        switch outcome {
        case "correct": return "checkmark.circle.fill"
        case "incorrect": return "xmark.circle.fill"
        default: return "minus.circle.fill"
        }
    }

    private func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "correct": return .green
        case "incorrect": return .orange
        default: return .gray
        }
    }

    private func outcomeLabel(_ outcome: String) -> String {
        switch outcome {
        case "correct": return String(localized: "记得")
        case "incorrect": return String(localized: "忘了")
        default: return "跳过"
        }
    }
}
