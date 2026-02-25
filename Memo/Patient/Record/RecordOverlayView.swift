import SwiftUI
import RealityKit
import EverMemOSKit

/// 记一记功能的 overlay：根据 RecordFeature.phase 展示对应 UI（含拍照按钮）
struct RecordOverlayView: View {
    @Bindable var feature: RecordFeature
    let isStable: Bool
    let onCapture: () -> Void

    var body: some View {
        VStack {
            Spacer()
            switch feature.phase {
            case .ready:
                captureButton
            case .capturing:
                CapsuleHint(text: String(localized: "识别中…"), showSpinner: true)
            case .recognized(let r):
                VStack(spacing: 12) {
                    Text(r.emoji).font(.system(size: 56))
                    Text(r.item).font(.title2.bold()).foregroundStyle(.white)
                    Text(r.description).font(.callout).foregroundStyle(.white.opacity(0.8))
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal, 16)
            case .saving:
                CapsuleHint(text: String(localized: "正在保存空间地图…"), showSpinner: true)
            case .success:
                EmptyView()
            case .error(let msg):
                Text(msg).font(.callout.bold()).foregroundStyle(.red)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { feature.phase = .ready }
            }
        }
    }

    private var captureButton: some View {
        VStack(spacing: 16) {
            if !isStable {
                CapsuleHint(text: String(localized: "等待追踪稳定…"), showSpinner: true)
            }
            Button(action: onCapture) {
                ZStack {
                    Circle().fill(.white).frame(width: 72, height: 72)
                    Circle().stroke(.white, lineWidth: 4).frame(width: 82, height: 82)
                    Image(systemName: "plus.viewfinder")
                        .font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                }
            }
            .disabled(!isStable).opacity(isStable ? 1 : 0.4)
        }
    }
}
