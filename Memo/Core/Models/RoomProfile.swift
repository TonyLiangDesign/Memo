import Foundation
import SwiftData

@Model
final class RoomProfile: Identifiable {
    @Attribute(.unique) var roomID: String
    var name: String
    var emoji: String
    var status: String  // RoomStatus rawValue — kept as String for #Predicate compatibility
    var lastScannedAt: Date?
    var featurePointCount: Int
    var lastMapSizeBytes: Int
    var relocSuccessCount: Int
    var relocFailCount: Int
    var homeKitRoomNames: [String] = []
    var createdAt: Date
    var updatedAt: Date

    var id: String { roomID }

    // MARK: - Computed

    @Transient var statusEnum: RoomStatus {
        get { RoomStatus(rawValue: status) ?? .draft }
        set { status = newValue.rawValue }
    }

    @Transient var displayName: String { "\(emoji) \(name)" }

    @Transient var isReady: Bool { statusEnum == .ready }

    @Transient var mapFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("FindItemMaps", isDirectory: true)
            .appendingPathComponent(roomID, isDirectory: true)
            .appendingPathComponent("worldMap.dat")
    }

    init(name: String, emoji: String, status: RoomStatus = .draft) {
        self.roomID = UUID().uuidString
        self.name = name
        self.emoji = emoji
        self.status = status.rawValue
        self.featurePointCount = 0
        self.lastMapSizeBytes = 0
        self.relocSuccessCount = 0
        self.relocFailCount = 0
        self.homeKitRoomNames = []
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
