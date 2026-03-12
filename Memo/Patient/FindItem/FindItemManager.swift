import ARKit
import RealityKit
import SwiftData
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "FindItemManager")

/// AR session manager for the Find Item feature.
/// Handles Place mode (anchor placement + world map save)
/// and Find mode (world map reload + relocalization + distance guidance).
@Observable @MainActor
final class FindItemManager: NSObject, FrameConsumer {

    // MARK: - FrameConsumer Protocol

    let consumerID = "find-item-\(UUID().uuidString.prefix(8))"
    let desiredFrameRate: Double = 2.0  // 0.5s interval, matches original Timer
    private(set) var isPaused = false

    // MARK: - Orchestrator (optional, only set in LiveModeView)

    weak var orchestrator: PerceptionOrchestrator?

    // MARK: - Types

    enum Mode: Equatable {
        case idle
        case place
        case find(String) // item ID
    }

    enum TrackingState: Equatable {
        case initializing
        case normal
        case limited(String)
        case relocating
        case failed(String)

        var color: Color {
            switch self {
            case .normal: .green
            case .limited, .relocating: .yellow
            case .initializing: .orange
            case .failed: .red
            }
        }
    }

    // MARK: - Observable State

    var mode: Mode = .idle
    var trackingState: TrackingState = .initializing
    var distanceToTarget: Float?
    var anchorPlaced = false
    var worldMapSaved = false
    var relocalized = false
    var statusMessage = ""
    var errorMessage: String?
    var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable

    // MARK: - Internal

    let store: ItemAnchorStore
    private var targetAnchorID: String?
    private var distanceTimer: Timer?
    private var findStartedAt: Date?
    private var findRoomID: String?
    private var multiplexer: ARSessionDelegateMultiplexer?

    // MARK: - Frame-driven tracking (replaces Timer when Orchestrator present)

    private weak var activeARView: ARView?
    private var findItem: SpatialAnchor?
    private var hasOrchestrator: Bool { orchestrator != nil }

    /// Called on find mode exit with (roomID, didRelocalize).
    var onRelocResult: ((String, Bool) -> Void)?

    init(store: ItemAnchorStore) {
        self.store = store
        super.init()
    }

    // MARK: - Multiplexer Integration

    func registerWithMultiplexer(_ multiplexer: ARSessionDelegateMultiplexer) {
        self.multiplexer = multiplexer
        multiplexer.addDelegate(self)
    }

    private func ensureDelegateRegistered(on arView: ARView) {
        if let multiplexer {
            multiplexer.addDelegate(self)
            multiplexer.attach(to: arView.session)
        } else {
            arView.session.delegate = self
        }
    }

    // MARK: - FrameConsumer

    func processFrame(_ frame: FrameInput) async {
        // 1. Update mappingStatus (replaces session(_:didUpdate:) when orchestrator present)
        mappingStatus = frame.worldMappingStatus

        // 2. Distance tracking (find mode only, replaces Timer)
        // Note: FrameInput doesn't carry anchor data, so we read from the live
        // ARSession for anchor positions + camera pose. processFrame is effectively
        // used as a frame-rate-controlled trigger here; worldMappingStatus above is
        // the only field consumed from the passed FrameInput.
        guard case .find = mode,
              let arView = activeARView,
              let targetID = targetAnchorID else { return }

        guard let currentFrame = arView.session.currentFrame else { return }
        let cam = currentFrame.camera.transform.columns.3
        if let anchor = currentFrame.anchors.first(where: { $0.name == targetID }) {
            let pos = anchor.transform.columns.3
            let dx = cam.x - pos.x, dy = cam.y - pos.y, dz = cam.z - pos.z
            distanceToTarget = sqrt(dx * dx + dy * dy + dz * dz)

            // Place marker on relocalization (same logic as original Timer)
            if relocalized, arView.scene.anchors.isEmpty, let item = findItem {
                arView.scene.addAnchor(
                    FindItemARContainer.createMarkerEntity(
                        name: item.displayName, color: .systemGreen, at: anchor.transform
                    )
                )
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }

        // Arrival haptic
        if let dist = distanceToTarget, dist < 0.3 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    // MARK: - Session Reset Coordination

    /// Wraps session.run(resetTracking) with automatic orchestrator notification.
    private func runSessionWithReset(
        _ config: ARWorldTrackingConfiguration,
        on arView: ARView
    ) {
        orchestrator?.notifySessionWillReset(reason: "AR session reset")
        ensureDelegateRegistered(on: arView)
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - Place Mode

    /// Full restart: resets ARSession with a new config. Use when loading a world map.
    func startPlaceMode(on arView: ARView) {
        mode = .place
        trackingState = .initializing
        anchorPlaced = false
        worldMapSaved = false
        statusMessage = String(localized: "正在启动相机...")
        errorMessage = nil

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]

        if let data = store.loadSharedWorldMap(),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            config.initialWorldMap = worldMap
            statusMessage = String(localized: "正在加载已有空间地图...")
        }

        runSessionWithReset(config, on: arView)
    }

    /// Lightweight attach: hooks into an already-running ARSession without resetting tracking.
    /// Use when ARView is persistent and session is already tracking.
    func attachToSession(on arView: ARView) {
        mode = .place
        anchorPlaced = false
        worldMapSaved = false
        errorMessage = nil
        ensureDelegateRegistered(on: arView)

        // Inherit current tracking state from the live session
        if let frame = arView.session.currentFrame {
            mappingStatus = frame.worldMappingStatus
            switch frame.camera.trackingState {
            case .normal:
                trackingState = .normal
                statusMessage = String(localized: "追踪正常，对准物品拍照")
            case .limited(let reason):
                switch reason {
                case .initializing:
                    trackingState = .initializing
                    statusMessage = String(localized: "正在初始化...")
                default:
                    trackingState = .limited(String(localized: "受限"))
                    statusMessage = String(localized: "追踪受限")
                }
            case .notAvailable:
                trackingState = .failed(String(localized: "AR不可用"))
                statusMessage = String(localized: "AR追踪不可用")
            }
        } else {
            trackingState = .initializing
            statusMessage = String(localized: "等待相机就绪...")
        }
    }

    /// Place an anchor ahead of camera with optional lateral offset.
    /// - Parameters:
    ///   - forward: distance ahead (default 0.5m)
    ///   - lateral: horizontal offset, negative = left (default 0)
    func placeAnchor(in arView: ARView, forward: Float = 0.5, lateral: Float = 0) -> (String, simd_float4x4)? {
        guard let frame = arView.session.currentFrame else {
            errorMessage = String(localized: "无法获取相机位置")
            return nil
        }

        let cameraTransform = frame.camera.transform
        var offset = matrix_identity_float4x4
        offset.columns.3.z = -forward
        offset.columns.3.x = lateral
        let anchorTransform = simd_mul(cameraTransform, offset)

        let anchorID = UUID().uuidString
        let arAnchor = ARAnchor(name: anchorID, transform: anchorTransform)
        arView.session.add(anchor: arAnchor)

        anchorPlaced = true
        statusMessage = String(localized: "已放置标记！请给物品命名")
        return (anchorID, anchorTransform)
    }

    /// Save world map + register item in store.
    /// When `roomID` is provided (room already scanned), skips world map save — only creates anchor.
    func saveItem(name: String, emoji: String, anchorID: String, roomID: String? = nil, in arView: ARView) async throws {
        let skipMapSave = roomID != nil

        if !skipMapSave {
            statusMessage = String(localized: "等待地图就绪...")

            // Wait for mappingStatus == .mapped (up to 10s)
            for _ in 0..<20 {
                if mappingStatus == .mapped { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard mappingStatus == .mapped else {
                throw FindItemError.noWorldMap
            }
        }

        statusMessage = skipMapSave ? String(localized: "正在保存物品位置...") : String(localized: "正在保存空间地图...")

        let worldMap = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ARWorldMap, Error>) in
            arView.session.getCurrentWorldMap { worldMap, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let worldMap {
                    cont.resume(returning: worldMap)
                } else {
                    cont.resume(throwing: FindItemError.noWorldMap)
                }
            }
        }

        if !skipMapSave {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: worldMap, requiringSecureCoding: true
            )
            try store.saveSharedWorldMap(data: data)
        }

        // Extract pose from the placed anchor
        let arAnchor = worldMap.anchors.first { $0.name == anchorID }
        let t = arAnchor?.transform ?? matrix_identity_float4x4
        let quat = simd_quatf(t)
        let ms: String = switch mappingStatus {
        case .mapped: "mapped"
        case .extending: "extending"
        case .limited: "limited"
        default: "notAvailable"
        }
        store.addItem(
            name: name, emoji: emoji, anchorID: anchorID,
            posX: t.columns.3.x, posY: t.columns.3.y, posZ: t.columns.3.z,
            rotX: quat.imag.x, rotY: quat.imag.y, rotZ: quat.imag.z, rotW: quat.real,
            confidence: arAnchor != nil ? 1.0 : 0.0, mappingStatus: ms, roomID: roomID
        )

        worldMapSaved = true
        statusMessage = String(localized: "已保存「\(emoji) \(name)」的位置")
    }

    // MARK: - Find Mode

    func startFindMode(item: SpatialAnchor, roomID: String? = nil, on arView: ARView) throws {
        mode = .find(item.anchorID)
        targetAnchorID = item.anchorID
        activeARView = arView
        findItem = item
        trackingState = .relocating
        relocalized = false
        distanceToTarget = nil
        statusMessage = String(localized: "正在搜索空间特征，请慢慢环顾四周...")
        errorMessage = nil
        findStartedAt = Date()
        findRoomID = roomID ?? item.roomID

        // Try room map first, then fall back to shared map
        var data: Data?
        if let rid = findRoomID {
            data = store.loadRoomWorldMap(roomID: rid)
        }
        if data == nil {
            data = store.loadSharedWorldMap()
        }
        guard let mapData = data else {
            throw FindItemError.noWorldMap
        }
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: ARWorldMap.self, from: mapData
        ) else {
            throw FindItemError.worldMapCorrupted
        }

        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = worldMap
        runSessionWithReset(config, on: arView)
    }

    /// Compute distance from camera to target anchor.
    func updateDistance(arView: ARView) {
        guard let targetID = targetAnchorID,
              let frame = arView.session.currentFrame else { return }

        let cam = frame.camera.transform.columns.3
        if let anchor = frame.anchors.first(where: { $0.name == targetID }) {
            let pos = anchor.transform.columns.3
            let dx = cam.x - pos.x
            let dy = cam.y - pos.y
            let dz = cam.z - pos.z
            distanceToTarget = sqrt(dx * dx + dy * dy + dz * dz)
        }
    }

    /// Distance guidance text in Chinese.
    var distanceGuidance: String {
        guard let d = distanceToTarget else { return "" }
        switch d {
        case ..<0.3:  return String(localized: "到达了！")
        case ..<0.5:  return String(localized: "就在附近")
        case ..<1.0:  return String(localized: "越来越近了")
        case ..<2.0:  return String(localized: "继续靠近")
        default:      return String(localized: "继续朝标记方向走")
        }
    }

    // MARK: - Distance Tracking

    /// Start a repeating timer that updates distance, places relocalization marker, and triggers haptics.
    /// When orchestrator is present, processFrame drives this instead — Timer is a fallback for Split views.
    func startDistanceTracking(arView: ARView, item: SpatialAnchor) {
        if hasOrchestrator {
            activeARView = arView
            findItem = item
            return
        }
        // Fallback: no Orchestrator (SplitFindView)
        stopDistanceTracking()
        distanceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, let _ = self.targetAnchorID else { return }
                self.updateDistance(arView: arView)
                if self.relocalized,
                   let frame = arView.session.currentFrame,
                   let anchor = frame.anchors.first(where: { $0.name == item.anchorID }),
                   arView.scene.anchors.isEmpty {
                    arView.scene.addAnchor(
                        FindItemARContainer.createMarkerEntity(
                            name: item.displayName, color: .systemGreen, at: anchor.transform
                        )
                    )
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
                if let dist = self.distanceToTarget, dist < 0.3 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    func stopDistanceTracking() {
        distanceTimer?.invalidate()
        distanceTimer = nil
    }

    // MARK: - Room Detection

    /// Detected room ID after auto-detection completes.
    var detectedRoomID: String?
    var isDetectingRoom = false

    /// Try each room's world map in order; the first to relocalize wins.
    /// Sorted by most recently updated so the likeliest room is tried first.
    func detectCurrentRoom(rooms: [RoomProfile], on arView: ARView) async {
        let sorted = rooms.sorted { $0.updatedAt > $1.updatedAt }
        isDetectingRoom = true
        detectedRoomID = nil
        statusMessage = String(localized: "正在识别房间...")
        logger.info("[RoomDetect] Starting detection with \(sorted.count) rooms")

        for room in sorted {
            guard !Task.isCancelled else { break }
            logger.info("[RoomDetect] Trying room: \(room.displayName) (id=\(room.roomID), status=\(room.status))")

            let mapURL = store.roomMapURL(for: room.roomID)
            let fileExists = FileManager.default.fileExists(atPath: mapURL.path)
            logger.info("[RoomDetect]   Map file exists: \(fileExists), path: \(mapURL.path)")

            guard let data = store.loadRoomWorldMap(roomID: room.roomID) else {
                logger.warning("[RoomDetect]   loadRoomWorldMap returned nil — skipping")
                continue
            }
            logger.info("[RoomDetect]   Map loaded: \(data.count) bytes")

            guard let worldMap = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self, from: data
            ) else {
                logger.warning("[RoomDetect]   NSKeyedUnarchiver failed — skipping")
                continue
            }
            logger.info("[RoomDetect]   WorldMap OK, anchors: \(worldMap.anchors.count), rawFeaturePoints: \(worldMap.rawFeaturePoints.points.count)")

            relocalized = false
            trackingState = .relocating

            let config = ARWorldTrackingConfiguration()
            config.initialWorldMap = worldMap
            runSessionWithReset(config, on: arView)

            // Wait up to 5 seconds for relocalization
            // Note: we check trackingState == .normal directly, not `relocalized`,
            // because `relocalized` is only set when mode == .find (which it isn't during detection).
            var sawRelocalizing = false
            for tick in 0..<10 {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .milliseconds(500))
                if case .relocating = trackingState { sawRelocalizing = true }
                if case .limited(let r) = trackingState, r.contains("重新定位") { sawRelocalizing = true }
                let isNormal = trackingState == .normal
                logger.info("[RoomDetect]   tick \(tick): tracking=\(String(describing: self.trackingState)), sawRelocalizing=\(sawRelocalizing), isNormal=\(isNormal)")
                if isNormal && sawRelocalizing {
                    detectedRoomID = room.roomID
                    isDetectingRoom = false
                    relocalized = true
                    statusMessage = String(localized: "已识别：\(room.displayName)")
                    logger.info("[RoomDetect] ✅ Matched room: \(room.displayName)")
                    return
                }
            }
            logger.info("[RoomDetect]   ❌ Timeout for room: \(room.displayName)")
            guard !Task.isCancelled else { break }
        }

        isDetectingRoom = false

        guard !Task.isCancelled else { return }

        // No room matched — restart with a clean session
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        runSessionWithReset(config, on: arView)
        statusMessage = String(localized: "未识别到已建档房间")
        logger.info("[RoomDetect] No room matched, clean session started")
    }

    // MARK: - Factory

    /// Bootstrap AR infrastructure: creates an `ItemAnchorStore` + `FindItemManager` pair.
    @MainActor
    static func bootstrap(modelContext: ModelContext, arHolder: ARViewHolder)
        -> (store: ItemAnchorStore, manager: FindItemManager)
    {
        let store = ItemAnchorStore(modelContext: modelContext)
        let manager = FindItemManager(store: store)
        return (store, manager)
    }

    // MARK: - Cleanup

    /// Exit find mode: report reloc result, reset internal state, but stay registered with multiplexer.
    func resetToNormalTracking() {
        // Report reloc result for room-based tracking
        if case .find = mode, let roomID = findRoomID {
            let success = relocalized
            let timedOut = !success && findStartedAt.map {
                Date().timeIntervalSince($0) >= 30
            } ?? false
            if success || timedOut {
                onRelocResult?(roomID, success)
            }
        }

        stopDistanceTracking()
        mode = .idle
        trackingState = .initializing
        distanceToTarget = nil
        anchorPlaced = false
        worldMapSaved = false
        relocalized = false
        targetAnchorID = nil
        findStartedAt = nil
        findRoomID = nil
        errorMessage = nil
        activeARView = nil
        findItem = nil
    }

    /// Detach from session without pausing it. Use when ARView stays alive.
    func detach() {
        resetToNormalTracking()
        multiplexer?.removeDelegate(self)
    }

    /// Full stop: pauses ARSession. Use only when ARView is being torn down.
    func stopSession(on arView: ARView) {
        arView.session.pause()
        detach()
    }
}

// MARK: - ARSessionDelegate

extension FindItemManager: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            switch camera.trackingState {
            case .notAvailable:
                trackingState = .failed(String(localized: "AR不可用"))
                statusMessage = String(localized: "AR追踪不可用")

            case .limited(let reason):
                switch reason {
                case .relocalizing:
                    if case .find = mode {
                        trackingState = .relocating
                        statusMessage = String(localized: "正在搜索已保存的位置，请慢慢环顾四周...")
                    } else {
                        trackingState = .limited(String(localized: "正在重新定位"))
                        statusMessage = String(localized: "正在重新定位")
                    }
                case .initializing:
                    trackingState = .limited(String(localized: "正在初始化"))
                    statusMessage = String(localized: "正在初始化...")
                case .excessiveMotion:
                    trackingState = .limited(String(localized: "移动过快"))
                    statusMessage = String(localized: "请慢一点移动手机")
                case .insufficientFeatures:
                    trackingState = .limited(String(localized: "环境特征不足"))
                    statusMessage = String(localized: "环境特征不足，试试光线更好的地方")
                @unknown default:
                    trackingState = .limited(String(localized: "受限"))
                    statusMessage = String(localized: "追踪受限")
                }

            case .normal:
                trackingState = .normal
                if case .find = mode, !relocalized {
                    relocalized = true
                    statusMessage = String(localized: "已找到位置！正在显示物品标记...")
                } else if case .place = mode {
                    statusMessage = String(localized: "追踪正常，点击屏幕放置标记")
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            if case .find = mode, let targetID = targetAnchorID {
                for anchor in anchors where anchor.name == targetID {
                    relocalized = true
                    statusMessage = String(localized: "找到了！跟着标记走")
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            trackingState = .failed(error.localizedDescription)
            errorMessage = String(localized: "AR错误：\(error.localizedDescription)")
            logger.error("AR session failed: \(error.localizedDescription)")
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // When orchestrator is present, processFrame handles mappingStatus updates.
        // Only run this fallback path for Split views (no orchestrator).
        Task { @MainActor in
            guard !hasOrchestrator else { return }
            mappingStatus = frame.worldMappingStatus
        }
    }
}

// MARK: - Errors

enum FindItemError: LocalizedError {
    case worldMapCorrupted
    case noWorldMap
    case roomMapUnavailable
    case trackingFailed

    var errorDescription: String? {
        switch self {
        case .worldMapCorrupted: String(localized: "保存的空间地图已损坏")
        case .noWorldMap: String(localized: "没有已保存的空间地图")
        case .roomMapUnavailable: String(localized: "空间地图不可用，请看护者重新扫描该房间")
        case .trackingFailed: String(localized: "AR追踪失败")
        }
    }
}
