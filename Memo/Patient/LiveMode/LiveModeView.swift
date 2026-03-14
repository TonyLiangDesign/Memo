import SwiftUI
import SwiftData
import RealityKit
import ARKit
import EverMemOSKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "LiveMode")

/// 患者主界面（融合模式）：全屏 ARView 常驻，默认对话模式
/// 记一记、找一找、答题收纳到右上角 "..." 菜单，底部无按钮
struct LiveModeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RoleManager.self) private var roleManager
    @Environment(GeminiMedicationService.self) private var geminiService
    @Environment(APIKeyStore.self) private var apiKeyStore
    @Environment(SpeechSynthesisService.self) private var tts
    @Environment(DailyMemoryService.self) private var dailyMemoryService
    @Environment(HomeKitPassiveEventService.self) private var homeKitService

    @Query(filter: #Predicate<RoomProfile> { $0.status != "draft" })
    private var readyRooms: [RoomProfile]
    @Query private var allContacts: [CareContact]

    enum ActiveFeature: Equatable { case idle, record, find }

    @State private var feature: ActiveFeature = .idle
    @State private var arHolder = ARViewHolder()
    @State private var findManager: FindItemManager?
    @State private var store: ItemAnchorStore?
    @State private var chatViewModel: ChatViewModel?
    @State private var recordFeature = RecordFeature()
    @State private var multiplexer = ARSessionDelegateMultiplexer()
    @State private var orchestrator = PerceptionOrchestrator(
        frameProvider: FrameProvider(),
        stateStore: PerceptionStateStore()
    )
    @State private var faceRecognitionService: FaceRecognitionService?

    // Find
    @State private var selectedItem: SpatialAnchor?

    // Room detection task (cancellable)
    @State private var detectionTask: Task<Void, Never>?

    // Camera toggle (for testing face recognition with front camera)
    @State private var usingFrontCamera = false
    @State private var showPractice = false
    @State private var isScanningFace = false

    var body: some View {
        ZStack {
            FindItemARContainer(holder: arHolder)
            VStack(spacing: 0) {
                HStack {
                    // Room emoji - top-left corner
                    if let roomName = orchestrator.stateStore.currentRoomName,
                       let emoji = roomName.first(where: { $0.isEmoji }) {
                        Text(String(emoji))
                            .font(.system(size: 32))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 56)

                topStatusBar
                Spacer()
                middleContent
            }
            if case .success(let item, let room) = recordFeature.phase {
                SuccessOverlay(name: item, room: room)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .fullScreenCover(isPresented: $showPractice) { DailyPracticeView() }
        .onAppear { startLiveMode() }
        .onDisappear { stopAll() }
        .onChange(of: recordFeature.phase) {
            // Return to chat after capture completes (phase resets to .ready)
            if recordFeature.phase == .ready && feature == .record {
                switchFeature(to: .idle)
            }
        }
        .onChange(of: allContacts.count) { reloadFaceRecognition() }
        .onChange(of: allContacts.map(\.faceVersion)) { reloadFaceRecognition() }
    }

    // MARK: - Top Status Bar

    private var topStatusBar: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                moreMenu
                Button { captureWhoIs() } label: {
                    Image(systemName: "person.fill.viewfinder")
                        .font(.title2).foregroundStyle(isScanningFace ? .yellow : .white)
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(isScanningFace)
                Button { captureRecord() } label: {
                    Image(systemName: "plus.viewfinder")
                        .font(.title2).foregroundStyle(feature == .record ? .yellow : .white)
                        .frame(width: 64, height: 64)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .disabled(recordFeature.phase == .capturing || recordFeature.phase == .saving)
                findMenuButton
            }
        }
        .padding(.horizontal, 20).padding(.top, 56)
    }

    // MARK: - Middle Content

    @ViewBuilder
    private var middleContent: some View {
        VStack(spacing: 8) {
            // Status hints moved from top
            VStack(alignment: .leading, spacing: 6) {
                // Room detection status
                if let mgr = findManager, mgr.isDetectingRoom {
                    CapsuleHint(text: mgr.statusMessage, showSpinner: true)
                }
                // Face recognition badges
                ForEach(Array(orchestrator.stateStore.visibleFaces.values), id: \.id) { face in
                    CapsuleHint(text: face.displayName)
                }
                // Tracking status — only in find mode
                if feature == .find, let mgr = findManager {
                    TrackingStatusBadge(manager: mgr)
                }
            }

            // Feature-specific content
            switch feature {
            case .idle:  ChatOverlay(viewModel: $chatViewModel, perceptionState: orchestrator.stateStore, faceRecognitionService: faceRecognitionService)
            case .record:
                // Only show progress/result phases — capture is auto-triggered by the button
                if recordFeature.phase != .ready {
                    RecordOverlayView(
                        feature: recordFeature,
                        isStable: true
                    ) { /* no-op: capture triggered by captureRecord() */ }
                    .padding(.bottom, 12)
                }
            case .find:
                FindDistanceOverlay(manager: findManager, selectedItem: selectedItem)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - More Menu (top-right "..." button)

    private var moreMenu: some View {
        Menu {
            // 答题
            Button { showPractice = true } label: {
                if dailyMemoryService.hasPendingPractice {
                    Label(String(localized: "每日答题 ●"), systemImage: "brain.head.profile")
                } else {
                    Label(String(localized: "每日答题"), systemImage: "brain.head.profile")
                }
            }

            // 回到对话（idle）
            if feature != .idle {
                Button { switchFeature(to: .idle) } label: {
                    Label(String(localized: "返回对话"), systemImage: "mic.fill")
                }
            }

            Divider()

            // 切换前后摄像头
            Button { toggleCamera() } label: {
                Label(
                    usingFrontCamera ? "切换后置摄像头" : "切换前置摄像头",
                    systemImage: "arrow.triangle.2.circlepath.camera"
                )
            }

            // 切换看护者
            Button { withAnimation { roleManager.toggleRole() } } label: {
                Label(String(localized: "切换看护者"), systemImage: "arrow.left.arrow.right")
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis")
                    .font(.title2).fontWeight(.bold).foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(.black.opacity(0.5), in: Circle())
                if dailyMemoryService.hasPendingPractice {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                        .offset(x: 2, y: -2)
                }
            }
        }
    }

    private var findMenuButton: some View {
        let saved = store?.items ?? []
        let grouped = Dictionary(grouping: saved) { $0.roomID }
        return Menu {
            if saved.isEmpty {
                Text(String(localized: "暂无已保存的物品"))
            } else {
                ForEach(readyRooms, id: \.roomID) { room in
                    let roomItems = grouped[room.roomID] ?? []
                    if !roomItems.isEmpty {
                        Section(room.displayName) {
                            ForEach(roomItems, id: \.anchorID) { item in
                                Button { beginFind(item: item) } label: {
                                    Label("\(item.emoji) \(item.itemName)", systemImage: "location.fill")
                                }
                            }
                        }
                    }
                }
                let unassigned = grouped[nil] ?? []
                if !unassigned.isEmpty {
                    Section(String(localized: "未分配")) {
                        ForEach(unassigned, id: \.anchorID) { item in
                            Button { beginFind(item: item) } label: {
                                Label("\(item.emoji) \(item.itemName)", systemImage: "location.fill")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.title2).foregroundStyle(feature == .find ? .yellow : .white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.5), in: Circle())
        }
    }

    // MARK: - Camera Toggle

    private func toggleCamera() {
        guard let arView = arHolder.view else {
            logger.warning("[Camera] toggleCamera: arView is nil")
            return
        }
        usingFrontCamera.toggle()
        logger.info("[Camera] Switching to \(self.usingFrontCamera ? "FRONT" : "REAR") camera")
        orchestrator.frameProvider.usingFrontCamera = usingFrontCamera
        orchestrator.notifySessionWillReset(reason: "Camera toggle")

        if usingFrontCamera {
            guard ARFaceTrackingConfiguration.isSupported else {
                logger.error("[Camera] ARFaceTrackingConfiguration NOT supported on this device")
                usingFrontCamera = false
                return
            }
            let config = ARFaceTrackingConfiguration()
            logger.info("[Camera] Running ARFaceTrackingConfiguration")
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            logger.info("[Camera] Running ARWorldTrackingConfiguration")
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        // ARFaceTrackingConfiguration doesn't fire cameraDidChangeTrackingState,
        // so SessionObserver can't auto-recover. Force recovery after a short delay.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if orchestrator.stateStore.isSessionDisrupted {
                logger.info("[Camera] Force recovering consumers after config switch")
                orchestrator.notifySessionDidRecover()
            }
        }
    }

    // MARK: - One-Tap Record

    private func captureRecord() {
        // Switch to record mode (sets up FindItemManager) if not already there
        if feature != .record {
            switchFeature(to: .record)
        }

        // Wait briefly for FindItemManager to attach, then trigger capture
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard let arView = arHolder.view, let findManager else {
                logger.error("[Record] captureRecord: arView or findManager is nil")
                return
            }
            let roomID = orchestrator.stateStore.currentRoomID
            let roomName = orchestrator.stateStore.currentRoomName
            logger.info("[Record] Capturing with roomID=\(roomID ?? "nil"), roomName=\(roomName ?? "nil")")
            recordFeature.capture(
                arView: arView,
                findManager: findManager,
                geminiService: geminiService,
                apiClient: apiKeyStore.buildAPIClient(),
                roomID: roomID,
                roomName: roomName
            )
        }
    }

    // MARK: - One-Tap Face Recognition

    private func captureWhoIs() {
        guard let arView = arHolder.view,
              let faceService = faceRecognitionService else {
            logger.error("[WhoIs] arView or faceService is nil")
            return
        }

        isScanningFace = true
        let orientation: CGImagePropertyOrientation = usingFrontCamera ? .leftMirrored : .right

        Task {
            // Multi-frame: try up to 5 frames over ~1s for best result
            var bestMatches: [FaceMatch] = []
            var anyFaceDetected = false

            for attempt in 0..<5 {
                guard let frame = arView.session.currentFrame else { continue }
                let matches = await faceService.recognizeSnapshot(
                    pixelBuffer: frame.capturedImage,
                    orientation: orientation
                )
                logger.info("[WhoIs] Attempt \(attempt): \(matches.count) faces, best sim=\(matches.map(\.similarity).max() ?? 0)")

                if !matches.isEmpty { anyFaceDetected = true }
                let recognized = matches.filter { $0.similarity > 0.30 && $0.name != nil }
                if !recognized.isEmpty {
                    // Keep matches with highest similarity
                    let currentBest = bestMatches.map(\.similarity).max() ?? 0
                    let newBest = recognized.map(\.similarity).max() ?? 0
                    if newBest > currentBest { bestMatches = recognized }
                }
                // Stop early if we got a strong match
                if bestMatches.contains(where: { $0.similarity > 0.55 }) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }

            if !bestMatches.isEmpty {
                for match in bestMatches {
                    logger.info("[WhoIs] Recognized: \(match.name ?? "?") sim=\(match.similarity)")
                    let result = FaceResult(
                        id: UUID(),
                        personID: match.contactID ?? "",
                        name: match.name ?? "未知",
                        relationship: match.relationship,
                        confidence: match.similarity,
                        boundingBox: match.boundingBox
                    )
                    orchestrator.stateStore.handle(.faceRecognized(result))
                }
            } else if anyFaceDetected {
                logger.info("[WhoIs] Faces detected but none matched registered contacts")
                tts.enqueue(String(localized: "检测到人脸，但未匹配到已注册的联系人"))
            } else {
                logger.info("[WhoIs] No faces detected in any frame")
                tts.enqueue(String(localized: "没有检测到人脸"))
            }

            isScanningFace = false

            // Auto-clear face badges after 5 seconds
            try? await Task.sleep(for: .seconds(5))
            for face in orchestrator.stateStore.visibleFaces.keys {
                orchestrator.stateStore.handle(.faceLost(trackingID: face))
            }
        }
    }

    // MARK: - Detection Cancellation

    private func cancelDetectionIfNeeded() {
        guard detectionTask != nil else { return }
        logger.info("[Lifecycle] Cancelling room detection task")
        detectionTask?.cancel()
        detectionTask = nil
        findManager?.detach()
        findManager = nil
    }

    // MARK: - Feature Switching

    private func switchFeature(to target: ActiveFeature) {
        guard target != feature else { return }
        logger.info("[Feature] Switching \(String(describing: self.feature)) → \(String(describing: target))")
        cancelDetectionIfNeeded()
        cleanupCurrentFeature()
        feature = target
        setupCurrentFeature()
    }

    // MARK: - Find Actions

    private func beginFind(item: SpatialAnchor) {
        logger.info("[Find] beginFind: \(item.emoji) \(item.itemName) (anchor=\(item.anchorID), room=\(item.roomID ?? "nil"))")
        cancelDetectionIfNeeded()
        cleanupCurrentFeature()
        feature = .find
        selectedItem = item

        let s = store ?? ItemAnchorStore(modelContext: modelContext)
        store = s
        let mgr = FindItemManager(store: s)
        mgr.registerWithMultiplexer(multiplexer)
        mgr.orchestrator = orchestrator      // Inject orchestrator
        orchestrator.register(mgr)           // Register as FrameConsumer
        findManager = mgr
        setupRelocCallback(mgr)

        guard let arView = arHolder.view else { return }
        arView.scene.anchors.removeAll()
        // No manual notifySessionWillReset — FindItemManager.runSessionWithReset handles it
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            do {
                try mgr.startFindMode(item: item, roomID: item.roomID, on: arView)
                mgr.startDistanceTracking(arView: arView, item: item)
            } catch {
                mgr.errorMessage = String(localized: "加载地图失败：\(error.localizedDescription)")
                selectedItem = nil
            }
        }
    }

    // MARK: - Reloc Callback

    private func setupRelocCallback(_ mgr: FindItemManager) {
        mgr.onRelocResult = { [self] roomID, success in
            guard let room = readyRooms.first(where: { $0.roomID == roomID }) else { return }
            if success {
                room.relocSuccessCount += 1
                room.relocFailCount = 0
            } else {
                room.relocFailCount += 1
                if room.relocFailCount >= 3 {
                    room.statusEnum = .needsRescan
                }
            }
            room.updatedAt = Date()
            try? modelContext.save()
        }
    }

    // MARK: - Lifecycle

    private func setupCurrentFeature() {
        let s = store ?? ItemAnchorStore(modelContext: modelContext)
        store = s

        switch feature {
        case .idle:
            break
        case .record:
            let mgr = FindItemManager(store: s)
            mgr.registerWithMultiplexer(multiplexer)
            mgr.orchestrator = orchestrator     // Inject orchestrator
            orchestrator.register(mgr)          // Register (record mode needs mappingStatus)
            findManager = mgr
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                guard let arView = arHolder.view else { return }
                mgr.attachToSession(on: arView)
            }
        case .find:
            break  // Find mode is entered via beginFind(), not here
        }
    }

    private func cleanupCurrentFeature() {
        switch feature {
        case .idle:
            break
        case .record:
            if let mgr = findManager { orchestrator.unregister(mgr) }
            findManager?.detach()
            findManager = nil
            recordFeature.phase = .ready
        case .find:
            selectedItem = nil
            if let mgr = findManager { orchestrator.unregister(mgr) }
            findManager?.detach()
            findManager = nil
        }
        arHolder.view?.scene.anchors.removeAll()
    }

    private func startLiveMode() {
        logger.info("[Lifecycle] startLiveMode: readyRooms=\(self.readyRooms.count), contacts=\(self.allContacts.count)")
        let s = ItemAnchorStore(modelContext: modelContext)
        store = s

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard let arView = arHolder.view else {
                logger.error("[Lifecycle] startLiveMode: arView is nil after delay")
                return
            }
            logger.info("[Lifecycle] ARView ready, attaching multiplexer + orchestrator")
            multiplexer.attach(to: arView.session)
            orchestrator.attach(to: multiplexer)
            orchestrator.start()
            startFaceRecognition()

            // Start HomeKit monitoring
            homeKitService.start(modelContext: modelContext, apiClient: apiKeyStore.buildAPIClient())

            guard !readyRooms.isEmpty else {
                logger.info("[Lifecycle] No ready rooms, skipping room detection")
                return
            }

            let detector = FindItemManager(store: s)
            detector.registerWithMultiplexer(multiplexer)
            detector.orchestrator = orchestrator
            findManager = detector  // Expose for UI status spinner

            detectionTask = Task {
                await detector.detectCurrentRoom(rooms: readyRooms, on: arView)

                guard !Task.isCancelled else {
                    detector.detach()
                    return
                }

                // Write room state into stateStore
                if let roomID = detector.detectedRoomID,
                   let room = readyRooms.first(where: { $0.roomID == roomID }) {
                    orchestrator.stateStore.handle(
                        .roomDetected(roomID: roomID, name: room.displayName)
                    )
                } else {
                    orchestrator.stateStore.handle(.roomDetectionFailed)
                }

                detector.detach()
                findManager = nil
                detectionTask = nil
            }
        }
    }

    private func startFaceRecognition() {
        logger.info("[Face] Loading face recognition (snapshot mode), contacts=\(self.allContacts.count), enrolled=\(self.allContacts.filter(\.faceEnrolled).count)")
        let faceService = FaceRecognitionService(
            embeddingService: FaceEmbeddingService(),
            faceDataStore: FaceDataStore(),
            stateStore: orchestrator.stateStore
        )
        faceService.loadRegisteredFaces(contacts: allContacts)

        // TTS announcement + memory recording when face is recognized
        let ttsRef = tts
        let vmRef = $chatViewModel
        orchestrator.stateStore.onFaceAnnouncement = { result in
            let text: String
            if let rel = result.relationship {
                text = String(localized: "这是您的\(rel)，\(result.name)")
            } else {
                text = String(localized: "这是\(result.name)")
            }
            ttsRef.enqueue(text)

            // Record as memory
            let memoryText = result.relationship != nil
                ? String(localized: "见到了\(result.relationship!)（\(result.name)）")
                : String(localized: "见到了\(result.name)")
            vmRef.wrappedValue?.recordPatientBehavior(memoryText, flush: true)
        }

        // Snapshot mode: don't register as continuous FrameConsumer to save battery
        faceRecognitionService = faceService
        logger.info("[Face] FaceRecognitionService loaded (snapshot mode, not continuous)")

        // Update existing ChatViewModel with the now-available services
        chatViewModel?.perceptionState = orchestrator.stateStore
        chatViewModel?.faceRecognitionService = faceService
    }

    private func reloadFaceRecognition() {
        guard let faceService = faceRecognitionService else { return }
        logger.info("[Face] Reloading face recognition data, contacts=\(self.allContacts.count), enrolled=\(self.allContacts.filter(\.faceEnrolled).count)")
        faceService.loadRegisteredFaces(contacts: allContacts)
    }

    private func stopAll() {
        logger.info("[Lifecycle] stopAll")
        cancelDetectionIfNeeded()
        cleanupCurrentFeature()
        faceRecognitionService = nil
        orchestrator.stop()
        orchestrator.detach(from: multiplexer)
        orchestrator.stateStore.reset()
    }
}
