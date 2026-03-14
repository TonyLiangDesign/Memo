import SwiftUI
import SwiftData

/// 房间详情页 — AR扫描 + HomeKit设备管理 + 房间绑定
struct RoomDetailView: View {
    @Bindable var room: RoomProfile
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitPassiveEventService.self) private var homeKit

    @State private var showScan = false
    @State private var showBindingEditor = false
    @State private var showEmojiPicker = false
    @State private var emojiInput = ""

    var body: some View {
        List {
            roomInfoSection
            scanSection
            devicesSection
            bindingSection
        }
        .navigationTitle(room.displayName)
        .fullScreenCover(isPresented: $showScan) {
            RoomScanView(room: room)
        }
        .alert(String(localized: "选择房间图标"), isPresented: $showEmojiPicker) {
            TextField(String(localized: "输入 emoji"), text: $emojiInput)
            Button(String(localized: "确定")) {
                let trimmed = emojiInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if let first = trimmed.first, first.isEmoji {
                    room.emoji = String(first)
                    room.updatedAt = Date()
                    try? modelContext.save()
                }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        }
    }

    // MARK: - Room Info

    private var roomInfoSection: some View {
        Section(String(localized: "房间信息")) {
            HStack {
                Text(String(localized: "图标"))
                Spacer()
                Button {
                    emojiInput = room.emoji
                    showEmojiPicker = true
                } label: {
                    Text(room.emoji)
                        .font(.system(size: 36))
                }
            }
        }
    }

    // MARK: - AR Scan

    private var scanSection: some View {
        Section(String(localized: "空间扫描")) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        CapsuleBadge(value: room.statusEnum)
                        if let scanned = room.lastScannedAt {
                            Text(scanned.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if room.featurePointCount > 0 {
                        Text(String(localized: "\(room.featurePointCount) 特征点 · \(ByteCountFormatter.string(fromByteCount: Int64(room.lastMapSizeBytes), countStyle: .file))"))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button {
                    showScan = true
                } label: {
                    Label(room.isReady ? String(localized: "重新扫描") : String(localized: "扫描空间"), systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - HomeKit Devices

    private var devicesSection: some View {
        let devices = homeKit.discoveredAccessories.filter { room.homeKitRoomNames.contains($0.roomName) }

        return Section(header: Text(String(localized: "HomeKit 设备")), footer: devicesFooter(count: devices.count)) {
            if devices.isEmpty {
                Text(String(localized: "暂无关联设备"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(devices) { accessory in
                    deviceRow(accessory)
                }
            }
        }
    }

    private func devicesFooter(count: Int) -> some View {
        Group {
            if room.homeKitRoomNames.isEmpty {
                Text(String(localized: "请在下方「HomeKit 房间绑定」中关联 HomeKit 房间以显示设备。"))
            } else if count == 0 {
                Text(String(localized: "已关联的 HomeKit 房间中未发现传感器设备。"))
            } else {
                EmptyView()
            }
        }
    }

    private func deviceRow(_ accessory: DiscoveredAccessory) -> some View {
        let isOn = homeKit.isMonitored(accessory.id)

        return Toggle(isOn: Binding(
            get: { isOn },
            set: { homeKit.setMonitored(accessory.id, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: iconForSensorTypes(accessory.sensorTypes))
                        .foregroundStyle(accessory.isReachable ? .blue : .gray)
                    Text(accessory.name)
                }
                HStack(spacing: 8) {
                    Text(sensorTypeLabel(accessory.sensorTypes))
                    if !accessory.isReachable {
                        Text(String(localized: "离线")).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - HomeKit Room Binding

    private var bindingSection: some View {
        let allHomeKitRooms = Set(homeKit.discoveredAccessories.map(\.roomName)).sorted()

        return Section(header: Text(String(localized: "HomeKit 房间绑定")), footer: Text(String(localized: "选择哪些 HomeKit 房间的设备属于此房间。"))) {
            if allHomeKitRooms.isEmpty {
                Text(String(localized: "未发现 HomeKit 房间"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(allHomeKitRooms, id: \.self) { hkRoom in
                    let isBound = room.homeKitRoomNames.contains(hkRoom)
                    let deviceCount = homeKit.discoveredAccessories.filter { $0.roomName == hkRoom }.count

                    Toggle(isOn: Binding(
                        get: { isBound },
                        set: { newValue in
                            if newValue {
                                room.homeKitRoomNames.append(hkRoom)
                            } else {
                                room.homeKitRoomNames.removeAll { $0 == hkRoom }
                            }
                            room.updatedAt = Date()
                            try? modelContext.save()
                        }
                    )) {
                        HStack {
                            Text(hkRoom)
                            Spacer()
                            Text(String(localized: "\(deviceCount) 设备"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func iconForSensorTypes(_ types: [String]) -> String {
        if types.contains("motion") { return "figure.walk.motion" }
        if types.contains("contact") { return "door.left.hand.open" }
        if types.contains("outlet") { return "powerplug.fill" }
        return "sensor.fill"
    }

    private func sensorTypeLabel(_ types: [String]) -> String {
        types.map { type in
            switch type {
            case "motion": return String(localized: "动作传感器")
            case "contact": return String(localized: "门磁传感器")
            case "outlet": return String(localized: "插座")
            default: return type
            }
        }.joined(separator: " · ")
    }
}
