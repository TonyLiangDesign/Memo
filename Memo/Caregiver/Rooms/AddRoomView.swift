import SwiftUI
import SwiftData

/// 新增房间 — 预设 + HomeKit 发现的房间
struct AddRoomView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitPassiveEventService.self) private var homeKit
    @Query private var existingRooms: [RoomProfile]

    var onCreated: ((RoomProfile) -> Void)?

    private let emojiOptions: [(String, String)] = [
        ("🛋️", String(localized: "客厅")),
        ("🛏️", String(localized: "卧室")),
        ("🍳", String(localized: "厨房")),
        ("🚿", String(localized: "浴室")),
        ("📖", String(localized: "书房")),
        ("🏠", String(localized: "其他")),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    presetGrid
                    homeKitImportSection
                }
                .padding(20)
            }
            .navigationTitle("选择房间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - Presets

    private var presetGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
            ForEach(emojiOptions, id: \.0) { emoji, label in
                Button { save(emoji: emoji, name: label) } label: {
                    VStack(spacing: 8) {
                        Text(emoji).font(.system(size: 40))
                        Text(label).font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - HomeKit Import

    @ViewBuilder
    private var homeKitImportSection: some View {
        let boundNames = Set(existingRooms.flatMap(\.homeKitRoomNames))
        let unboundRooms = Set(homeKit.discoveredAccessories.map(\.roomName))
            .subtracting(boundNames)
            .sorted()

        if !unboundRooms.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("从 HomeKit 导入")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 16) {
                    ForEach(unboundRooms, id: \.self) { hkRoom in
                        let emoji = emojiForRoomName(hkRoom)
                        let deviceCount = homeKit.discoveredAccessories.filter { $0.roomName == hkRoom }.count

                        Button { saveFromHomeKit(name: hkRoom, emoji: emoji) } label: {
                            VStack(spacing: 6) {
                                Text(emoji).font(.system(size: 36))
                                Text(hkRoom).font(.subheadline).lineLimit(1)
                                Text("\(deviceCount) 设备")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 100)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func save(emoji: String, name: String) {
        let room = RoomProfile(name: name, emoji: emoji, status: .draft)
        modelContext.insert(room)
        try? modelContext.save()
        dismiss()
        onCreated?(room)
    }

    private func saveFromHomeKit(name: String, emoji: String) {
        let room = RoomProfile(name: name, emoji: emoji, status: .draft)
        room.homeKitRoomNames = [name]
        modelContext.insert(room)
        try? modelContext.save()
        dismiss()
        onCreated?(room)
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
}
