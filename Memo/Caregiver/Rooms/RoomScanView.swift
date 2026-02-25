import SwiftUI
import SwiftData
import RealityKit
import ARKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "RoomScanView")

/// 全屏 AR 扫描页 — 看护者端按房间建立世界地图
struct RoomScanView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let room: RoomProfile

    @State private var arHolder = ARViewHolder()
    @State private var findManager: FindItemManager?
    @State private var featurePointCount = 0
    @State private var hasReachedMapped = false
    @State private var qualifiedSince: Date?
    @State private var canSave = false
    @State private var isSaving = false
    @State private var scanPaused = false
    @State private var errorMessage: String?
    @State private var qualityTimer: Timer?

    var body: some View {
        ZStack {
            FindItemARContainer(holder: arHolder)

            VStack(spacing: 0) {
                topBar
                Spacer()
                scanGuidance
                    .padding(.bottom, 16)
                saveButton
                    .padding(.bottom, 48)
            }

            if scanPaused {
                pauseOverlay
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear { setup() }
        .onDisappear { cleanup() }
        .onChange(of: scenePhase) { _, newPhase in
            scanPaused = newPhase != .active
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
            if let mgr = findManager {
                TrackingStatusBadge(manager: mgr)
            }
            Spacer()
            Text(room.displayName)
                .font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .padding(.horizontal, 20).padding(.top, 56)
    }

    // MARK: - Scan Guidance

    private var scanGuidance: some View {
        VStack(spacing: 8) {
            Text(guidanceText)
                .font(.callout.bold()).foregroundStyle(.white)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Label("\(featurePointCount) 特征点", systemImage: "dot.radiowaves.left.and.right")
                if let mgr = findManager {
                    Label(mappingLabel(mgr.mappingStatus), systemImage: "map")
                }
            }
            .font(.caption).foregroundStyle(.white.opacity(0.8))

            // Quality bar
            qualityBar
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 20)
    }

    private var guidanceText: String {
        guard let mgr = findManager else { return String(localized: "正在启动...") }

        if case .failed(let reason) = mgr.trackingState {
            return String(localized: "扫描中断：\(reason)")
        }

        switch mgr.trackingState {
        case .initializing, .limited:
            return String(localized: "请慢慢环顾房间...")
        default:
            break
        }

        if !hasReachedMapped {
            return String(localized: "继续扫描，覆盖门口和主要家具")
        }
        if featurePointCount < 500 {
            return String(localized: "特征不够丰富，请扫描更多区域")
        }
        if !canSave {
            return String(localized: "即将就绪...")
        }
        return String(localized: "质量达标，可以保存")
    }

    private func mappingLabel(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: String(localized: "未就绪")
        case .limited:      String(localized: "受限")
        case .extending:    String(localized: "扩展中")
        case .mapped:       String(localized: "已建图")
        @unknown default:   String(localized: "未知")
        }
    }

    private var qualityBar: some View {
        let progress: Double = min(Double(featurePointCount) / 500.0, 1.0)
        let color: Color = featurePointCount >= 500 ? .green : .orange
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            Task { await saveWorldMap() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                }
                Text(isSaving ? "正在保存..." : "保存空间地图")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(canSave && !isSaving ? Color.green : Color.gray, in: Capsule())
            .padding(.horizontal, 40)
        }
        .disabled(!canSave || isSaving)
    }

    // MARK: - Pause Overlay

    private var pauseOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 60)).foregroundStyle(.white)
            Text("扫描暂停，请返回继续")
                .font(.title3.bold()).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.7))
    }

    // MARK: - Lifecycle

    private func setup() {
        let store = ItemAnchorStore(modelContext: modelContext)
        let mgr = FindItemManager(store: store)
        findManager = mgr

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard let arView = arHolder.view else { return }

            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            arView.session.delegate = mgr
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])

            startQualityTimer(arView: arView)
        }
    }

    private func cleanup() {
        qualityTimer?.invalidate()
        qualityTimer = nil
        findManager?.detach()
        findManager = nil
    }

    // MARK: - Quality Timer

    private func startQualityTimer(arView: ARView) {
        qualityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let mgr = findManager,
                      let frame = arView.session.currentFrame else { return }

                let currentCount = frame.rawFeaturePoints?.points.count ?? 0
                featurePointCount = max(featurePointCount, currentCount)

                if mgr.mappingStatus == .mapped { hasReachedMapped = true }
                let enoughFeatures = featurePointCount >= 500

                if hasReachedMapped && enoughFeatures {
                    if qualifiedSince == nil { qualifiedSince = Date() }
                    if Date().timeIntervalSince(qualifiedSince!) >= 2.0 {
                        canSave = true
                    }
                } else {
                    qualifiedSince = nil
                    canSave = false
                }
            }
        }
    }

    // MARK: - Save

    private func saveWorldMap() async {
        guard let arView = arHolder.view else { return }
        isSaving = true
        errorMessage = nil

        do {
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

            let data = try NSKeyedArchiver.archivedData(
                withRootObject: worldMap, requiringSecureCoding: true
            )

            let store = ItemAnchorStore(modelContext: modelContext)
            try store.saveRoomWorldMap(roomID: room.roomID, data: data)

            // Update RoomProfile
            room.statusEnum = .ready
            room.lastScannedAt = Date()
            room.featurePointCount = featurePointCount
            room.lastMapSizeBytes = data.count
            room.updatedAt = Date()
            try? modelContext.save()

            logger.info("Saved room world map: \(room.displayName) (\(data.count) bytes, \(featurePointCount) features)")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            logger.error("Failed to save room world map: \(error.localizedDescription)")
        }
    }
}
