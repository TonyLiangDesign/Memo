import SwiftUI

struct SplashView: View {
    @State private var showPoweredBy = false
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                if !showPoweredBy {
                    AppIconView(size: 120)
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 24) {
                        VStack(spacing: 4) {
                            Text("Powered by")
                                .font(.subheadline)
                                .foregroundStyle(.black)
                            Text("EverMemOS")
                                .font(.title2.bold())
                                .foregroundStyle(.black)
                        }

                        Image("evermemos-logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 50)
                    }
                    .transition(.opacity)
                }

                Spacer()
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).delay(1)) {
                showPoweredBy = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                withAnimation {
                    isPresented = false
                }
            }
        }
    }
}
