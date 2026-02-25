import Foundation
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "StateStore")

/// Central state store for perception pipeline results.
/// Consumed by UI overlays and ChatViewModel for context-aware responses.
@Observable @MainActor
final class PerceptionStateStore {

    // MARK: - State

    /// Currently visible faces keyed by tracking ID.
    var visibleFaces: [UUID: FaceResult] = [:]

    /// Recently seen people (auto-expires after TTL).
    private(set) var recentPeople: [FaceResult] = []

    /// Current room detection state.
    var currentRoomID: String?
    var currentRoomName: String?

    /// Whether the AR session is disrupted (e.g. world map reload).
    var isSessionDisrupted: Bool = false

    /// Summary string for ChatViewModel context injection.
    var contextSummary: String?

    /// Callback triggered when a new face is recognized (for TTS announcement).
    var onFaceAnnouncement: ((FaceResult) -> Void)?

    // MARK: - Config

    private let ttl: TimeInterval = 30

    // MARK: - Event Handling

    func handle(_ event: PerceptionEvent) {
        logger.info("[Event] \(String(describing: event))")

        switch event {
        case .faceRecognized(let result):
            visibleFaces[result.id] = result
            appendRecent(result)
            updateContextSummary()
            onFaceAnnouncement?(result)
            logger.info("[State] visibleFaces=\(self.visibleFaces.count), recent=\(self.recentPeople.count)")

        case .faceUnknown:
            break

        case .faceLost(let trackingID):
            visibleFaces.removeValue(forKey: trackingID)
            updateContextSummary()
            logger.info("[State] faceLost trackID=\(trackingID.uuidString.prefix(8)), remaining=\(self.visibleFaces.count)")

        case .itemRecognized:
            break

        case .sessionDisrupted:
            isSessionDisrupted = true
            visibleFaces.removeAll()
            updateContextSummary()
            logger.info("[State] Session disrupted, cleared \(self.visibleFaces.count) faces")

        case .sessionRecovered:
            isSessionDisrupted = false
            logger.info("[State] Session recovered")

        case .roomDetected(let roomID, let name):
            currentRoomID = roomID
            currentRoomName = name
            updateContextSummary()
            logger.info("[State] Room detected: \(name) (id=\(roomID))")

        case .roomDetectionFailed:
            currentRoomID = nil
            currentRoomName = nil
            updateContextSummary()
            logger.info("[State] Room detection failed")
        }

        pruneExpired()
    }

    func reset() {
        visibleFaces.removeAll()
        recentPeople.removeAll()
        contextSummary = nil
        currentRoomID = nil
        currentRoomName = nil
        isSessionDisrupted = false
    }

    // MARK: - Private

    private func appendRecent(_ result: FaceResult) {
        recentPeople.removeAll { $0.personID == result.personID }
        recentPeople.append(result)
    }

    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        recentPeople.removeAll { $0.timestamp < cutoff }
    }

    private func updateContextSummary() {
        var parts: [String] = []

        if let roomName = currentRoomName {
            parts.append(String(localized: "当前在：\(roomName)"))
        }

        if !visibleFaces.isEmpty {
            let names = visibleFaces.values.map { face in
                if let rel = face.relationship {
                    return "\(rel)（\(face.name)）"
                }
                return face.name
            }
            parts.append(String(localized: "看到：") + names.joined(separator: String(localized: "、")))
        }

        let newSummary = parts.isEmpty ? nil : parts.joined(separator: "；")
        if newSummary != contextSummary {
            logger.info("[Context] \(newSummary ?? "(nil)")")
        }
        contextSummary = newSummary
    }
}
