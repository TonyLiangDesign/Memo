import SwiftUI
import SwiftData

/// 患者每日记忆练习 — "想一想"
struct DailyPracticeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DailyMemoryService.self) private var service
    @Environment(SpeechSynthesisService.self) private var tts

    @State private var cards: [MemoryCard] = []
    @State private var session: PracticeSession?
    @State private var currentIndex = 0
    @State private var showAnswer = false
    @State private var isFinished = false

    private var currentCard: MemoryCard? {
        guard currentIndex < cards.count else { return nil }
        return cards[currentIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isFinished {
                completionView
            } else if let card = currentCard {
                VStack(spacing: 0) {
                    topBar
                    progressDots
                        .padding(.top, 16)
                    Spacer()
                    cardView(card)
                    Spacer()
                    if showAnswer {
                        actionButtons
                    } else {
                        tapHint
                    }
                }
                .padding(.bottom, 40)
            } else {
                emptyState
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear { startSession() }
        .onDisappear { tts.stop() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title2).foregroundStyle(.white)
                    .padding(12)
                    .background(.white.opacity(0.15), in: Circle())
            }
            Spacer()
            Text("想一想")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Spacer()
            // Spacer for symmetry
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 56)
    }

    // MARK: - Progress Dots

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<cards.count, id: \.self) { i in
                Circle()
                    .fill(dotColor(for: i))
                    .frame(width: 12, height: 12)
            }
        }
    }

    private func dotColor(for index: Int) -> Color {
        guard let session else { return .white.opacity(0.3) }
        if index < session.resultOutcomes.count {
            switch session.resultOutcomes[index] {
            case "correct": return .green
            case "incorrect": return .orange
            default: return .gray
            }
        }
        return index == currentIndex ? .white : .white.opacity(0.3)
    }

    // MARK: - Card View

    private func cardView(_ card: MemoryCard) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                showAnswer = true
            }
            tts.speak(card.answer)
        } label: {
            VStack(spacing: 20) {
                if showAnswer {
                    Text(card.answer)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                } else {
                    Text(card.question)
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(40)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(showAnswer ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
            )
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
        .disabled(showAnswer)
    }

    // MARK: - Tap Hint

    private var tapHint: some View {
        Text("点击卡片查看答案")
            .font(.callout)
            .foregroundStyle(.white.opacity(0.5))
            .padding(.bottom, 20)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 24) {
            Button { record(.incorrect) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark")
                    Text("忘了")
                }
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(.orange, in: RoundedRectangle(cornerRadius: 20))
            }

            Button { record(.correct) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                    Text("记得")
                }
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(.green, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Completion View

    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "star.fill")
                .font(.system(size: 72))
                .foregroundStyle(.yellow)

            Text("练习完成！")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)

            if let session {
                Text("答对 \(session.correctCount) / \(session.cardCount) 题")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))

                encouragementText(correct: session.correctCount, total: session.cardCount)
            }

            Spacer()

            Button { dismiss() } label: {
                Text("完成")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private func encouragementText(correct: Int, total: Int) -> some View {
        let text: String
        if total == 0 {
            text = ""
        } else if correct == total {
            text = String(localized: "太棒了！全部答对！")
        } else if correct >= total / 2 {
            text = String(localized: "做得不错，继续加油！")
        } else {
            text = String(localized: "没关系，多练练就好了")
        }
        return Text(text)
            .font(.title3)
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.5))
            Text("暂无练习卡片")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.7))
            Text("请让照护者添加联系人、物品或用药计划")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
            Button { dismiss() } label: {
                Text("返回")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 16)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(.top, 20)
        }
    }

    // MARK: - Logic

    private func startSession() {
        cards = service.generateDailySession(context: modelContext)
        guard !cards.isEmpty else { return }
        let s = PracticeSession(cardCount: cards.count)
        modelContext.insert(s)
        session = s
        tts.speak(cards[0].question)
    }

    private func record(_ outcome: PracticeOutcome) {
        guard let card = currentCard, let session else { return }
        service.recordOutcome(card: card, outcome: outcome, session: session, context: modelContext)

        let nextIndex = currentIndex + 1
        if nextIndex >= cards.count {
            service.completeSession(session, context: modelContext)
            withAnimation { isFinished = true }
            tts.speak("练习完成！答对\(session.correctCount)题")
        } else {
            withAnimation {
                currentIndex = nextIndex
                showAnswer = false
            }
            tts.speak(cards[nextIndex].question)
        }
    }
}
