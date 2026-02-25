import SwiftUI

/// 找一找功能的距离引导 overlay：距离数字 + guidance 文字
struct FindDistanceOverlay: View {
    let manager: FindItemManager?
    let selectedItem: SpatialAnchor?

    var body: some View {
        VStack {
            Spacer()
            if let mgr = manager, let dist = mgr.distanceToTarget {
                VStack(spacing: 8) {
                    if let item = selectedItem {
                        Text(item.displayName).font(.title2.bold()).foregroundStyle(.white)
                    }
                    Text(String(format: String(localized: "距离：%.1f 米"), dist))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(mgr.distanceGuidance).font(.title3.bold())
                        .foregroundStyle(dist < 0.5 ? .green : .yellow)
                }
                .padding(24)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            } else if selectedItem != nil {
                CapsuleHint(text: manager?.statusMessage ?? String(localized: "搜索中..."), showSpinner: true)
            }
        }
    }
}
