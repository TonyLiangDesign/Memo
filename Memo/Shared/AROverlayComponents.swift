import SwiftUI

/// 胶囊提示：带可选 spinner 的半透明胶囊条
struct CapsuleHint: View {
    let text: String
    var showSpinner: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if showSpinner { ProgressView().tint(.white) }
            Text(text).font(.callout.bold()).foregroundStyle(.white)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

/// 保存成功全屏覆盖层
struct SuccessOverlay: View {
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80)).foregroundStyle(.green)
            Text("已保存「\(name)」").font(.largeTitle.bold()).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.6))
    }
}

/// AR 追踪状态指示：圆点 + 状态文字
struct TrackingStatusBadge: View {
    let manager: FindItemManager

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(manager.trackingState.color).frame(width: 8, height: 8)
            Text(manager.statusMessage).font(.caption.bold()).foregroundStyle(.white).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.5), in: Capsule())
    }
}
