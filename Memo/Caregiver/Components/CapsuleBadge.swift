import SwiftUI

/// 枚举 → badge 显示文案 + 颜色的统一协议
protocol BadgeDisplayable {
    var badgeText: String { get }
    var badgeColor: Color { get }
}

/// 通用胶囊标签 — 统一 priority / status / room status 等 badge 样式
struct CapsuleBadge<T: BadgeDisplayable>: View {
    let value: T

    var body: some View {
        Text(value.badgeText)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(value.badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(value.badgeColor)
    }
}

// MARK: - ReviewStatus

extension ReviewStatus: BadgeDisplayable {
    var badgeText: String {
        switch self {
        case .pendingReview: String(localized: "待审核")
        case .approved: String(localized: "已批准")
        case .corrected: String(localized: "已纠错")
        case .deleted: String(localized: "已删除")
        }
    }

    var badgeColor: Color {
        switch self {
        case .pendingReview: .orange
        case .approved: .green
        case .corrected: .blue
        case .deleted: .red
        }
    }
}

// MARK: - RoomStatus

extension RoomStatus: BadgeDisplayable {
    var badgeText: String {
        switch self {
        case .draft: String(localized: "未扫描")
        case .ready: String(localized: "可用")
        case .needsRescan: String(localized: "需重扫")
        }
    }

    var badgeColor: Color {
        switch self {
        case .draft: .gray
        case .ready: .green
        case .needsRescan: .orange
        }
    }
}

// MARK: - RecommendationPriority

extension RecommendationPriority: BadgeDisplayable {
    var badgeText: String {
        switch self {
        case .high: String(localized: "重要")
        case .medium: String(localized: "一般")
        case .low: String(localized: "提示")
        }
    }

    var badgeColor: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .blue
        }
    }
}
