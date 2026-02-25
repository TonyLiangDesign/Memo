import SwiftUI

/// Backward-compatible alias — now delegates to CapsuleBadge
typealias ReviewStatusBadge = CapsuleBadge<ReviewStatus>

extension CapsuleBadge where T == ReviewStatus {
    init(status: ReviewStatus) {
        self.init(value: status)
    }
}
