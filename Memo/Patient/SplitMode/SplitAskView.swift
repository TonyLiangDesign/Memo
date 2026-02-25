import SwiftUI

/// 分离模式 — 问一问：全屏语音对话界面，无 AR
struct SplitAskView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var chatViewModel: ChatViewModel?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                ChatOverlay(viewModel: $chatViewModel)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .padding(10)
                    .background(.white.opacity(0.15), in: Circle())
            }
            Spacer()
            Text("问一问").font(.headline).foregroundStyle(.white.opacity(0.8))
            Spacer()
            // Invisible balance spacer
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 20).padding(.top, 56)
    }
}
