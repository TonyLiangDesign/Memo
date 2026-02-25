import Foundation
import CoreGraphics

// MARK: - Perception Events

enum PerceptionEvent: Sendable {
    case faceRecognized(FaceResult)
    case faceUnknown(confidence: Float, boundingBox: CGRect)
    case faceLost(trackingID: UUID)
    case itemRecognized(ItemResult)

    // Session lifecycle
    case sessionDisrupted(reason: String)   // AR session reset (e.g. Find loads world map)
    case sessionRecovered                    // AR tracking restored to normal
    case roomDetected(roomID: String, name: String)
    case roomDetectionFailed
}

// MARK: - Face Result

struct FaceResult: Sendable, Identifiable {
    let id: UUID
    let personID: String
    let name: String
    let relationship: String?
    let confidence: Float
    let boundingBox: CGRect
    let timestamp: Date

    init(
        id: UUID = UUID(),
        personID: String,
        name: String,
        relationship: String? = nil,
        confidence: Float,
        boundingBox: CGRect,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.personID = personID
        self.name = name
        self.relationship = relationship
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.timestamp = timestamp
    }
}

// MARK: - Item Result

struct ItemResult: Sendable {
    let itemName: String
    let emoji: String
    let confidence: Float
    let boundingBox: CGRect
    let timestamp: Date

    init(
        itemName: String,
        emoji: String,
        confidence: Float,
        boundingBox: CGRect,
        timestamp: Date = Date()
    ) {
        self.itemName = itemName
        self.emoji = emoji
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.timestamp = timestamp
    }
}
