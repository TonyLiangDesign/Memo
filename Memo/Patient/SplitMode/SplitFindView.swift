import SwiftUI
import SwiftData
import RealityKit
import ARKit

/// 分离模式 — 找一找：全屏 AR + FindItemManager + 物品选择 + 距离引导
struct SplitFindView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<RoomProfile> { $0.status != "draft" })
    private var readyRooms: [RoomProfile]

    @State private var arHolder = ARViewHolder()
    @State private var findManager: FindItemManager?
    @State private var store: ItemAnchorStore?
    @State private var selectedItem: SpatialAnchor?

    var body: some View {
        ZStack {
            FindItemARContainer(holder: arHolder)

            VStack(spacing: 0) {
                topBar
                Spacer()
                if selectedItem != nil {
                    FindDistanceOverlay(manager: findManager, selectedItem: selectedItem)
                        .padding(.bottom, 48)
                } else {
                    itemPicker
                }
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
                TrackingStatusBadge(manager: mgr)
            }
            Spacer()
            if selectedItem != nil {
                Button {
                    stopFind()
                } label: {
                    Text("重新选择").font(.callout.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 56)
    }

    // MARK: - Item Picker (grouped by room)

    private var itemPicker: some View {
        let saved = store?.items ?? []
        let grouped = Dictionary(grouping: saved) { $0.roomID }
        return VStack(spacing: 12) {
            if saved.isEmpty {
                Text("暂无已保存的物品")
                    .font(.title3).foregroundStyle(.white.opacity(0.7))
                    .padding(24)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
            } else {
                Text("选择要找的物品").font(.headline).foregroundStyle(.white.opacity(0.8))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Group by room
                        ForEach(readyRooms, id: \.roomID) { room in
                            let roomItems = grouped[room.roomID] ?? []
                            ForEach(roomItems, id: \.anchorID) { item in
                                itemCard(item, subtitle: room.name)
                            }
                        }
                        // Unassigned
                        let unassigned = grouped[nil] ?? []
                        ForEach(unassigned, id: \.anchorID) { item in
                            itemCard(item, subtitle: nil)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .padding(.bottom, 48)
    }

    private func itemCard(_ item: SpatialAnchor, subtitle: String?) -> some View {
        Button { beginFind(item: item) } label: {
            VStack(spacing: 6) {
                Text(item.emoji).font(.system(size: 36))
                Text(item.itemName).font(.callout.bold()).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 100, height: 100)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Find Actions

    private func beginFind(item: SpatialAnchor) {
        selectedItem = item

        guard let arView = arHolder.view, let findManager else { return }
        arView.scene.anchors.removeAll()
        setupRelocCallback(findManager)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            do {
                try findManager.startFindMode(item: item, roomID: item.roomID, on: arView)
                findManager.startDistanceTracking(arView: arView, item: item)
            } catch {
                findManager.errorMessage = String(localized: "加载地图失败：\(error.localizedDescription)")
                selectedItem = nil
            }
        }
    }

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

    private func stopFind() {
        selectedItem = nil
        findManager?.detach()
        arHolder.view?.scene.anchors.removeAll()

        // Re-attach for idle tracking
        if let store {
            let mgr = FindItemManager(store: store)
            findManager = mgr
            if let arView = arHolder.view {
                mgr.attachToSession(on: arView)
            }
        }
    }

    // MARK: - Lifecycle

    private func setup() {
        let (s, mgr) = FindItemManager.bootstrap(modelContext: modelContext, arHolder: arHolder)
        store = s
        findManager = mgr
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            guard let arView = arHolder.view else { return }
            mgr.attachToSession(on: arView)
        }
    }

    private func cleanup() {
        findManager?.detach()
        findManager = nil
    }
}
