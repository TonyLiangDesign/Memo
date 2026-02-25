import Foundation
import SwiftData

@Model
final class SpatialAnchor {
    @Attribute(.unique) var anchorID: String
    var itemName: String
    var emoji: String
    var posX: Float
    var posY: Float
    var posZ: Float
    var rotX: Float
    var rotY: Float
    var rotZ: Float
    var rotW: Float
    var confidence: Float
    var mappingStatus: String
    var roomID: String?  // nil = 未分配/旧数据
    var savedAt: Date
    var lastUpdatedAt: Date

    var displayName: String { "\(emoji) \(itemName)" }

    init(anchorID: String, itemName: String, emoji: String,
         posX: Float, posY: Float, posZ: Float,
         rotX: Float, rotY: Float, rotZ: Float, rotW: Float,
         confidence: Float, mappingStatus: String, roomID: String? = nil) {
        self.anchorID = anchorID
        self.itemName = itemName
        self.emoji = emoji
        self.posX = posX; self.posY = posY; self.posZ = posZ
        self.rotX = rotX; self.rotY = rotY; self.rotZ = rotZ; self.rotW = rotW
        self.confidence = confidence
        self.mappingStatus = mappingStatus
        self.roomID = roomID
        self.savedAt = Date()
        self.lastUpdatedAt = Date()
    }
}
