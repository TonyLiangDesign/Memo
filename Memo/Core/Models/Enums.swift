import Foundation

// MARK: - Sync Status

enum SyncStatus: String, Codable {
    case pendingSync
    case syncing
    case synced
    case failed
}

// MARK: - Review Status

enum ReviewStatus: String, Codable {
    case pendingReview
    case approved
    case corrected
    case deleted
}

// MARK: - Actor Role

enum ActorRole: String, Codable, CaseIterable {
    case patient
    case caregiver
}

// MARK: - Memory Event Type

enum MemoryEventType: String, Codable {
    case action          // "我做了…"
    case medication      // 用药确认
    case query           // 查询类
}

