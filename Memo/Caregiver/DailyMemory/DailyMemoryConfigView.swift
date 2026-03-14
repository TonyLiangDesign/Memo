import SwiftUI
import SwiftData

/// 照护者端：记忆卡片池管理
struct DailyMemoryConfigView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MemoryCard.createdAt, order: .reverse)
    private var allCards: [MemoryCard]

    @State private var showAddCard = false
    @State private var cardToToggle: MemoryCard?

    private var autoCards: [MemoryCard] {
        allCards.filter { $0.sourceType != "custom" }
    }

    private var customCards: [MemoryCard] {
        allCards.filter { $0.sourceType == "custom" }
    }

    var body: some View {
        List {
            Section {
                if autoCards.isEmpty {
                    Text(String(localized: "暂无自动生成的卡片"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(autoCards, id: \.cardID) { card in
                        cardRow(card)
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "自动生成"))
                    Spacer()
                    Text(String(localized: "\(autoCards.count) 张"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(String(localized: "根据联系人、物品和用药计划自动生成"))
            }

            Section {
                if customCards.isEmpty {
                    Text(String(localized: "暂无自定义卡片"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customCards, id: \.cardID) { card in
                        cardRow(card)
                    }
                    .onDelete(perform: deleteCustomCards)
                }
            } header: {
                HStack {
                    Text(String(localized: "自定义"))
                    Spacer()
                    Button(String(localized: "添加"), systemImage: "plus") {
                        showAddCard = true
                    }
                    .font(.caption)
                }
            }
        }
        .sheet(isPresented: $showAddCard) {
            AddMemoryCardView()
        }
        .alert(String(localized: "确认操作"), isPresented: .init(
            get: { cardToToggle != nil },
            set: { if !$0 { cardToToggle = nil } }
        )) {
            Button(String(localized: "确认")) {
                if let card = cardToToggle {
                    card.isEnabled.toggle()
                    try? modelContext.save()
                    cardToToggle = nil
                }
            }
            Button(String(localized: "取消"), role: .cancel) { cardToToggle = nil }
        } message: {
            if let card = cardToToggle {
                Text(card.isEnabled ? String(localized: "禁用后此卡片不会出现在练习中") : String(localized: "启用后此卡片将加入练习"))
            }
        }
    }

    private func cardRow(_ card: MemoryCard) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.question)
                    .font(.subheadline.bold())
                HStack(spacing: 12) {
                    Text(card.answer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if card.correctCount + card.incorrectCount > 0 {
                        let total = card.correctCount + card.incorrectCount
                        let rate = Double(card.correctCount) / Double(total)
                        Text(String(localized: "正确率 \(Int(rate * 100))%"))
                            .font(.caption2)
                            .foregroundStyle(rate >= 0.7 ? .green : .orange)
                    }
                }
            }
            Spacer()
            Button {
                cardToToggle = card
            } label: {
                Image(systemName: card.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(card.isEnabled ? .green : .gray)
            }
            .buttonStyle(.plain)
        }
    }

    private func deleteCustomCards(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(customCards[index])
        }
        try? modelContext.save()
    }
}

// MARK: - Add Custom Card

struct AddMemoryCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var question = ""
    @State private var answer = ""
    @State private var category: CardCategory = .custom

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "问题")) {
                    TextField(String(localized: "例：今天星期几？"), text: $question)
                }
                Section(String(localized: "答案")) {
                    TextField(String(localized: "例：星期三"), text: $answer)
                }
            }
            .navigationTitle(String(localized: "添加自定义卡片"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "添加")) {
                        let card = MemoryCard(
                            category: .custom,
                            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
                            answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                            sourceType: "custom"
                        )
                        modelContext.insert(card)
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
