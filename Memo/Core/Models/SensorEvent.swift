import Foundation
import SwiftData

@Model
final class SensorEvent {
    @Attribute(.unique) var eventID: String
    var sensorID: String
    var sensorType: String
    var roomName: String
    var eventType: String
    var timestamp: Date
    var uploadStatus: UploadStatus

    init(
        eventID: String = UUID().uuidString,
        sensorID: String,
        sensorType: String,
        roomName: String,
        eventType: String,
        timestamp: Date = Date(),
        uploadStatus: UploadStatus = .pending
    ) {
        self.eventID = eventID
        self.sensorID = sensorID
        self.sensorType = sensorType
        self.roomName = roomName
        self.eventType = eventType
        self.timestamp = timestamp
        self.uploadStatus = uploadStatus
    }
}

enum UploadStatus: String, Codable {
    case pending
    case uploaded
    case failed
}
