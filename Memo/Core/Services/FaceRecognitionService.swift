import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "FaceRecognition")

// MARK: - Face Match

struct FaceMatch: Sendable {
    let boundingBox: CGRect
    let contactID: String?    // nil = unknown
    let name: String?
    let relationship: String?
    let similarity: Float
}

// MARK: - Detected Face (UI-facing)

struct DetectedFace: Identifiable, Sendable {
    let id: UUID
    let boundingBox: CGRect
    let matchedContactID: String?
    let matchedName: String?
    let relationship: String?
    let confidence: Float
}

// MARK: - Tracked Face (cross-frame tracking)

private struct TrackedFace {
    let trackingID: UUID
    var lastBoundingBox: CGRect
    var lastEmbedding: [Float]?
    var matchedContactID: String?
    var matchedName: String?
    var matchedRelationship: String?
    var consecutiveHits: Int = 0
    var consecutiveUnknowns: Int = 0
    var lastSeenTimestamp: TimeInterval
    var matchSimilarity: Float = 0
}

// MARK: - Recognition Actor (background inference)

private actor RecognitionActor {
    let embeddingService: FaceEmbeddingService
    var registeredEmbeddings: [(contactID: String, name: String,
                                relationship: String?, embedding: [Float])] = []

    init(embeddingService: FaceEmbeddingService) {
        self.embeddingService = embeddingService
    }

    func loadEmbeddings(_ entries: [(contactID: String, name: String,
                                     relationship: String?, embedding: [Float])]) {
        registeredEmbeddings = entries
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) async -> [FaceMatch] {
        guard embeddingService.isAvailable else {
            // Detection-only mode: detect faces but can't identify
            guard let detections = try? await embeddingService.detectFaces(in: pixelBuffer, orientation: orientation) else {
                return []
            }
            return detections.map { det in
                FaceMatch(boundingBox: det.boundingBox, contactID: nil,
                         name: nil, relationship: nil, similarity: 0)
            }
        }

        // Full pipeline: detect + embed + match ALL faces
        guard let results = try? await embeddingService.generateEmbeddings(from: pixelBuffer, orientation: orientation),
              !results.isEmpty else {
            return []
        }

        logger.info("🔍 [Match] Detected \(results.count) faces, comparing against \(self.registeredEmbeddings.count) registered")

        return results.map { result in
            logger.info("🔍 [Match] Face embedding dim=\(result.embedding.count)")
            var bestMatch: (contactID: String, name: String, relationship: String?, similarity: Float)?
            for reg in self.registeredEmbeddings {
                let sim = FaceEmbeddingService.cosineSimilarity(result.embedding, reg.embedding)
                logger.info("🔍 [Match] vs \(reg.name): sim=\(String(format: "%.6f", sim))")
                if let current = bestMatch {
                    if sim > current.similarity {
                        bestMatch = (reg.contactID, reg.name, reg.relationship, sim)
                    }
                } else {
                    bestMatch = (reg.contactID, reg.name, reg.relationship, sim)
                }
            }

            if let match = bestMatch {
                logger.info("✅ [Match] Best: \(match.name) sim=\(String(format: "%.6f", match.similarity))")
                return FaceMatch(
                    boundingBox: result.boundingBox,
                    contactID: match.contactID,
                    name: match.name,
                    relationship: match.relationship,
                    similarity: match.similarity
                )
            }

            logger.info("❌ [Match] No match found")
            return FaceMatch(
                boundingBox: result.boundingBox, contactID: nil,
                name: nil, relationship: nil, similarity: 0
            )
        }
    }
}

// MARK: - Face Recognition Service

@Observable @MainActor
final class FaceRecognitionService: FrameConsumer {

    // MARK: - FrameConsumer Protocol

    let consumerID: String = "face-recognition"
    var desiredFrameRate: Double { 1.0 / detectionInterval }  // ~2fps

    // MARK: - Config

    let detectionInterval: TimeInterval = 0.5     // ~2fps
    let highThreshold: Float = 0.55               // Above → confirmed match
    let lowThreshold: Float = 0.35                // Below → confirmed unknown
    let debounceCount: Int = 2                    // Consecutive frames to confirm
    let cooldownInterval: TimeInterval = 300      // Same person cooldown (5 min)
    let trackingTTL: TimeInterval = 1.5           // Remove untracked faces after this

    // MARK: - State (UI observable)

    var isRunning = false
    private(set) var isPaused = false
    var detectedFaces: [DetectedFace] = []

    // MARK: - Internal

    private let recognitionActor: RecognitionActor
    private var trackedFaces: [UUID: TrackedFace] = [:]
    private var cooldownMap: [String: Date] = [:]

    // MARK: - Dependencies

    private let faceDataStore: FaceDataStore
    private let stateStore: PerceptionStateStore

    // MARK: - Init

    init(
        embeddingService: FaceEmbeddingService,
        faceDataStore: FaceDataStore,
        stateStore: PerceptionStateStore
    ) {
        self.faceDataStore = faceDataStore
        self.stateStore = stateStore
        self.recognitionActor = RecognitionActor(embeddingService: embeddingService)
    }

    // MARK: - Lifecycle

    func loadRegisteredFaces(contacts: [CareContact]) {
        let allEmbeddings = faceDataStore.loadAllEmbeddings()
        logger.info("🔍 [Load] Found \(allEmbeddings.count) embeddings in storage")

        var entries: [(contactID: String, name: String, relationship: String?, embedding: [Float])] = []
        for (contactID, embedding) in allEmbeddings {
            if let contact = contacts.first(where: { $0.contactID == contactID }), contact.faceEnrolled {
                logger.info("🔍 [Load] Contact: \(contact.realName) (\(contact.relation)) - embedding dim=\(embedding.count)")
                entries.append((
                    contactID: contactID,
                    name: contact.realName,
                    relationship: contact.relation.isEmpty ? nil : contact.relation,
                    embedding: embedding
                ))
            } else {
                logger.warning("🔍 [Load] Skipping contactID=\(contactID) - not enrolled or not found")
            }
        }

        Task {
            await recognitionActor.loadEmbeddings(entries)
            logger.info("✅ [Load] Loaded \(entries.count) registered face embeddings")
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        logger.info("FaceRecognitionService started")
    }

    func stop() {
        isRunning = false
        isPaused = true
        trackedFaces.removeAll()
        detectedFaces.removeAll()
        cooldownMap.removeAll()
        logger.info("FaceRecognitionService stopped")
    }

    // MARK: - FrameConsumer

    /// Frame counter for periodic stats logging
    private var frameCount: Int = 0

    func processFrame(_ frame: FrameInput) async {
        guard !isPaused else { return }
        frameCount += 1
        let matches = await recognitionActor.processFrame(frame.pixelBuffer, orientation: frame.imageOrientation)

        // Log every frame's detection result (every 10 frames to avoid spam)
        if frameCount % 10 == 0 || !matches.isEmpty {
            let matchDesc = matches.map { m in
                "\(m.name ?? "unknown")(sim=\(String(format: "%.3f", m.similarity)), box=\(String(format: "%.2f,%.2f", m.boundingBox.midX, m.boundingBox.midY)))"
            }
            logger.info("[Frame#\(self.frameCount)] faces=\(matches.count) matches=\(matchDesc) tracked=\(self.trackedFaces.count)")
        }

        updateTracking(matches: matches, timestamp: frame.timestamp)
    }

    /// Bypass cooldown (for "who is visible" queries).
    func bypassCooldown() {
        cooldownMap.removeAll()
        logger.info("Cooldown bypassed — next detection will trigger immediately")
    }

    // MARK: - One-Shot Snapshot

    /// Analyze a single frame and return all face matches (no debounce/cooldown/tracking).
    func recognizeSnapshot(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) async -> [FaceMatch] {
        await recognitionActor.processFrame(pixelBuffer, orientation: orientation)
    }

    func pause() {
        isPaused = true
        for (id, tracked) in trackedFaces where tracked.matchedContactID != nil {
            stateStore.handle(.faceLost(trackingID: id))
        }
        trackedFaces.removeAll()
        detectedFaces.removeAll()
        logger.info("FaceRecognitionService paused")
    }

    func resume() {
        isPaused = false
        logger.info("FaceRecognitionService resumed")
    }

    // MARK: - Tracking Logic

    private func updateTracking(matches: [FaceMatch], timestamp: TimeInterval) {
        // 1. Associate matches with tracked faces via IoU
        var usedTrackIDs = Set<UUID>()

        for match in matches {
            var bestTrackID: UUID?
            var bestIoU: CGFloat = 0

            for (id, tracked) in trackedFaces {
                guard !usedTrackIDs.contains(id) else { continue }
                let iou = Self.computeIoU(match.boundingBox, tracked.lastBoundingBox)
                if iou > bestIoU {
                    bestIoU = iou
                    bestTrackID = id
                }
            }

            if bestIoU > 0.3, let trackID = bestTrackID {
                // Update existing tracked face
                usedTrackIDs.insert(trackID)
                var tracked = trackedFaces[trackID]!
                tracked.lastBoundingBox = match.boundingBox
                tracked.lastSeenTimestamp = timestamp

                if let contactID = match.contactID, match.similarity > highThreshold {
                    if tracked.matchedContactID == contactID {
                        tracked.consecutiveHits += 1
                    } else {
                        tracked.matchedContactID = contactID
                        tracked.matchedName = match.name
                        tracked.matchedRelationship = match.relationship
                        tracked.consecutiveHits = 1
                        tracked.consecutiveUnknowns = 0
                    }
                    tracked.matchSimilarity = match.similarity
                } else {
                    tracked.consecutiveUnknowns += 1
                    if tracked.consecutiveUnknowns >= 3 {
                        tracked.matchedContactID = nil
                        tracked.matchedName = nil
                        tracked.matchedRelationship = nil
                        tracked.consecutiveHits = 0
                    }
                }

                trackedFaces[trackID] = tracked

                // Debounce check
                if tracked.consecutiveHits >= debounceCount,
                   let contactID = tracked.matchedContactID {
                    emitRecognition(tracked: tracked, contactID: contactID)
                }
            } else {
                // New face
                let newID = UUID()
                logger.info("[Tracking] New face trackID=\(newID.uuidString.prefix(8)), contact=\(match.contactID ?? "nil"), sim=\(String(format: "%.3f", match.similarity))")
                trackedFaces[newID] = TrackedFace(
                    trackingID: newID,
                    lastBoundingBox: match.boundingBox,
                    matchedContactID: match.contactID,
                    matchedName: match.name,
                    matchedRelationship: match.relationship,
                    consecutiveHits: (match.contactID != nil && match.similarity > highThreshold) ? 1 : 0,
                    lastSeenTimestamp: timestamp,
                    matchSimilarity: match.similarity
                )
            }
        }

        // 2. TTL cleanup: remove faces not seen recently
        let expiredIDs = trackedFaces.filter { timestamp - $0.value.lastSeenTimestamp > trackingTTL }.map(\.key)
        for id in expiredIDs {
            if let tracked = trackedFaces[id] {
                logger.info("[Tracking] Face expired trackID=\(id.uuidString.prefix(8)), contact=\(tracked.matchedContactID ?? "nil")")
                if tracked.matchedContactID != nil {
                    stateStore.handle(.faceLost(trackingID: id))
                }
            }
            trackedFaces.removeValue(forKey: id)
        }

        // 3. Update UI-facing state
        detectedFaces = trackedFaces.values.map { tracked in
            DetectedFace(
                id: tracked.trackingID,
                boundingBox: tracked.lastBoundingBox,
                matchedContactID: tracked.matchedContactID,
                matchedName: tracked.matchedName,
                relationship: tracked.matchedRelationship,
                confidence: tracked.matchSimilarity
            )
        }
    }

    private func emitRecognition(tracked: TrackedFace, contactID: String) {
        // Cooldown check
        if let lastTime = cooldownMap[contactID],
           Date().timeIntervalSince(lastTime) < cooldownInterval {
            logger.debug("[Emit] Skipped \(tracked.matchedName ?? contactID) — cooldown (\(String(format: "%.0f", Date().timeIntervalSince(lastTime)))s / \(self.cooldownInterval)s)")
            return
        }

        logger.info("[Emit] ✅ Recognized: \(tracked.matchedName ?? "?") (id=\(contactID), sim=\(String(format: "%.3f", tracked.matchSimilarity)), hits=\(tracked.consecutiveHits))")
        cooldownMap[contactID] = Date()

        let result = FaceResult(
            id: tracked.trackingID,
            personID: contactID,
            name: tracked.matchedName ?? String(localized: "未知"),
            relationship: tracked.matchedRelationship,
            confidence: tracked.matchSimilarity,
            boundingBox: tracked.lastBoundingBox
        )

        stateStore.handle(.faceRecognized(result))
        logger.info("Face recognized: \(result.name) (similarity: \(tracked.matchSimilarity))")
    }

    // MARK: - IoU

    private static func computeIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}
