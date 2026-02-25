import SwiftUI

/// 分离模式主页 — 三大功能独立入口，大按钮设计，适合认知负担较轻的交互
struct SplitModeView: View {
    @Environment(RoleManager.self) private var roleManager
    @Environment(DailyMemoryService.self) private var dailyMemoryService

    @State private var showRecord = false
    @State private var showFind = false
    @State private var showAsk = false
    @State private var showPractice = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar with practice + role switch
                HStack {
                    Spacer()
                    Button { showPractice = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "brain.head.profile")
                                .font(.title3).foregroundStyle(.orange)
                                .padding(10)
                                .background(.white.opacity(0.15), in: Circle())
                            if dailyMemoryService.hasPendingPractice {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    Button { withAnimation { roleManager.toggleRole() } } label: {
                        Image(systemName: "heart.fill")
                            .font(.title3).foregroundStyle(.white)
                            .padding(10)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                }
                .padding(.horizontal, 20).padding(.top, 56)

                Spacer()

                VStack(spacing: 20) {
                    featureCard(
                        icon: "plus.viewfinder",
                        title: "记一记",
                        subtitle: "记录物品放置位置",
                        color: .blue
                    ) { showRecord = true }

                    featureCard(
                        icon: "location.fill",
                        title: "找一找",
                        subtitle: "找回已记录的物品",
                        color: .green
                    ) { showFind = true }

                    featureCard(
                        icon: "mic.fill",
                        title: "问一问",
                        subtitle: "语音问答记忆助手",
                        color: .purple
                    ) { showAsk = true }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .fullScreenCover(isPresented: $showRecord) { SplitRecordView() }
        .fullScreenCover(isPresented: $showFind) { SplitFindView() }
        .fullScreenCover(isPresented: $showAsk) { SplitAskView() }
        .fullScreenCover(isPresented: $showPractice) { DailyPracticeView() }
    }

    private func featureCard(
        icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold()).foregroundStyle(.white)
                    Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.title3).foregroundStyle(.white.opacity(0.5))
            }
            .padding(20)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }
}
