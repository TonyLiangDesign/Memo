import SwiftUI
import SwiftData

/// 看护者端 — 空间建档：房间列表 + CRUD + HomeKit 设备概览
struct RoomListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitPassiveEventService.self) private var homeKit
    @Query(sort: \RoomProfile.updatedAt, order: .reverse)
    private var rooms: [RoomProfile]

    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                homeKitStatusHeader

                ForEach(rooms, id: \.roomID) { room in
                    NavigationLink(destination: RoomDetailView(room: room)) {
                        roomRow(room)
                    }
                }
                .onDelete(perform: deleteRooms)

                unassignedSection
            }
            .overlay {
                if rooms.isEmpty {
                    ContentUnavailableView(
                        String(localized: "暂无房间"),
                        systemImage: "map",
                        description: Text(String(localized: "点击右上角添加房间并扫描空间"))
                    )
                }
            }
            .navigationTitle(String(localized: "空间建档"))
            .roleSwitchToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddRoomView()
            }
        }
    }

    // MARK: - HomeKit Status

    @ViewBuilder
    private var homeKitStatusHeader: some View {
        switch homeKit.status {
        case .restricted:
            Section {
                Label(String(localized: "HomeKit 权限受限，请在系统设置中允许"), systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        case .waitingForHomes:
            Section {
                Label(String(localized: "正在搜索 HomeKit 设备…"), systemImage: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            Section {
                Label(String(localized: "HomeKit 异常：\(msg)"), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Row

    private func roomRow(_ room: RoomProfile) -> some View {
        let deviceCount = homeKit.discoveredAccessories.filter { room.homeKitRoomNames.contains($0.roomName) }.count

        return HStack(spacing: 12) {
            Text(room.emoji).font(.largeTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(room.name).font(.headline)
                HStack(spacing: 8) {
                    if let scanned = room.lastScannedAt {
                        Text(String(localized: "扫描：\(scanned.formatted(.relative(presentation: .named)))"))
                    }
                    if deviceCount > 0 {
                        Text(String(localized: "\(deviceCount) 设备"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CapsuleBadge(value: room.statusEnum)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Unassigned Devices

    @ViewBuilder
    private var unassignedSection: some View {
        let allBoundNames = Set(rooms.flatMap(\.homeKitRoomNames))
        let unassigned = homeKit.discoveredAccessories.filter { !allBoundNames.contains($0.roomName) }

        if !unassigned.isEmpty {
            let grouped = Dictionary(grouping: unassigned) { $0.roomName }
            Section(header: Text(String(localized: "未分配设备"))) {
                ForEach(grouped.keys.sorted(), id: \.self) { hkRoom in
                    let devices = grouped[hkRoom]!
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hkRoom).font(.subheadline)
                            Text(String(localized: "\(devices.count) 个传感器"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(String(localized: "创建房间")) {
                            createRoomFromHomeKit(name: hkRoom)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func createRoomFromHomeKit(name: String) {
        let emoji = emojiForRoomName(name)
        let room = RoomProfile(name: name, emoji: emoji, status: .draft)
        room.homeKitRoomNames = [name]
        modelContext.insert(room)
        try? modelContext.save()
    }

    private func emojiForRoomName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("bed") || lower.contains("卧") { return "🛏️" }
        if lower.contains("kitchen") || lower.contains("厨") { return "🍳" }
        if lower.contains("bath") || lower.contains("浴") || lower.contains("wash") { return "🚿" }
        if lower.contains("living") || lower.contains("客") { return "🛋️" }
        if lower.contains("study") || lower.contains("office") || lower.contains("书") { return "📖" }
        return "🏠"
    }

    private func deleteRooms(at offsets: IndexSet) {
        for idx in offsets {
            let room = rooms[idx]
            let roomID = room.roomID
            let descriptor = FetchDescriptor<SpatialAnchor>()
            if let anchors = try? modelContext.fetch(descriptor) {
                for anchor in anchors where anchor.roomID == roomID {
                    anchor.roomID = nil
                }
            }
            let store = ItemAnchorStore(modelContext: modelContext)
            store.deleteRoomWorldMap(roomID: roomID)
            modelContext.delete(room)
        }
        try? modelContext.save()
    }
}
