import SwiftUI
import SwiftData

struct RecommendationsView: View {
    enum Tab: String, CaseIterable {
        case recommendations = "建议"
        case cards = "卡片"
        case history = "历史"

        var localizedString: String {
            switch self {
            case .recommendations: return String(localized: "建议")
            case .cards: return String(localized: "卡片")
            case .history: return String(localized: "历史")
            }
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(APIKeyStore.self) private var apiKeyStore

    @Query(sort: \CaregiverRecommendation.detectedAt, order: .reverse)
    private var allRecommendations: [CaregiverRecommendation]

    private var recommendations: [CaregiverRecommendation] {
        allRecommendations.filter { $0.status == .pending }
    }

    @State private var selectedTab: Tab = .recommendations
    @State private var isLoading = false
    @State private var selectedRec: CaregiverRecommendation?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.localizedString).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch selectedTab {
                case .recommendations:
                    recommendationsContent
                case .cards:
                    DailyMemoryConfigView()
                case .history:
                    PracticeHistoryView()
                }
            }
            .navigationTitle(String(localized: "每日回忆"))
            .roleSwitchToolbar()
            .toolbar {
                if selectedTab == .recommendations {
                    ToolbarItem(placement: .primaryAction) {
                        Button(String(localized: "刷新"), systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                        .disabled(isLoading)
                    }
                }
            }
            .sheet(item: $selectedRec) { rec in
                RecommendationDetailView(recommendation: rec)
            }
            .alert(String(localized: "错误"), isPresented: .constant(errorMessage != nil)) {
                Button(String(localized: "确定")) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var recommendationsContent: some View {
        Group {
            if recommendations.isEmpty {
                emptyState
            } else {
                recommendationList
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "暂无建议"),
            systemImage: "checkmark.circle",
            description: Text(String(localized: "今天没有需要关注的事项"))
        )
    }

    private var recommendationList: some View {
        List {
            ForEach(recommendations) { rec in
                RecommendationRow(recommendation: rec)
                    .onTapGesture {
                        selectedRec = rec
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(String(localized: "忽略"), systemImage: "xmark") {
                            dismiss(rec)
                        }
                        .tint(.gray)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button(String(localized: "接受"), systemImage: "checkmark") {
                            accept(rec)
                        }
                        .tint(.green)
                    }
            }
        }
    }

    private func refresh() async {
        isLoading = true
        errorMessage = nil

        // RecommendationEngine removed - feature disabled
        errorMessage = String(localized: "建议生成功能暂时不可用")
        isLoading = false
    }

    private func accept(_ rec: CaregiverRecommendation) {
        rec.status = .accepted
        rec.acceptedAt = Date()
        try? modelContext.save()
    }

    private func dismiss(_ rec: CaregiverRecommendation) {
        rec.status = .dismissed
        rec.dismissedAt = Date()
        try? modelContext.save()
    }
}

struct RecommendationRow: View {
    let recommendation: CaregiverRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CapsuleBadge(value: recommendation.priority)
                Text(recommendation.title)
                    .font(.headline)
                Spacer()
            }
            Text(recommendation.context)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
