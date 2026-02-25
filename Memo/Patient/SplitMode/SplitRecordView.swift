import SwiftUI
import SwiftData
import RealityKit
import ARKit
import EverMemOSKit

/// 分离模式 — 记一记：全屏 AR + RecordFeature + 返回按钮
struct SplitRecordView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(GeminiMedicationService.self) private var geminiService
    @Environment(APIKeyStore.self) private var apiKeyStore

    @Query(filter: #Predicate<RoomProfile> { $0.status != "draft" })
    private var readyRooms: [RoomProfile]

    @State private var arHolder = ARViewHolder()
    @State private var findManager: FindItemManager?
    @State private var store: ItemAnchorStore?
    @State private var recordFeature = RecordFeature()
    @State private var detectedRoomID: String?

    var body: some View {
        ZStack {
            FindItemARContainer(holder: arHolder)

            VStack(spacing: 0) {
                topBar
                Spacer()
                RecordOverlayView(
                    feature: recordFeature,
                    isStable: findManager?.trackingState == .normal
                ) {
                    guard let arView = arHolder.view, let findManager else { return }
                    let roomID = detectedRoomID
                    let roomName = roomID.flatMap { rid in readyRooms.first { $0.roomID == rid }?.name }
                    recordFeature.capture(
                        arView: arView,
                        findManager: findManager,
                        geminiService: geminiService,
                        apiClient: apiKeyStore.buildAPIClient(),
                        roomID: roomID,
                        roomName: roomName
                    )
                }
                .padding(.bottom, 48)
            }

            if case .success(let name) = recordFeature.phase {
                SuccessOverlay(name: name)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .onAppear { setup() }
        .onDisappear { cleanup() }
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
                if mgr.isDetectingRoom {
                    CapsuleHint(text: mgr.statusMessage, showSpinner: true)
                } else {
                    TrackingStatusBadge(manager: mgr)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 56)
    }

    // MARK: - Lifecycle

    private func setup() {
        let (s, mgr) = FindItemManager.bootstrap(modelContext: modelContext, arHolder: arHolder)
        store = s
        findManager = mgr

        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard let arView = arHolder.view else { return }
            if !readyRooms.isEmpty {
                await mgr.detectCurrentRoom(rooms: readyRooms, on: arView)
                detectedRoomID = mgr.detectedRoomID
            } else {
                mgr.attachToSession(on: arView)
            }
        }
    }

    private func cleanup() {
        findManager?.detach()
        findManager = nil
    }
}
