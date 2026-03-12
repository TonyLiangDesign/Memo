import Foundation
import HomeKit
import SwiftData
import os.log
import EverMemOSKit
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "HomeKitPassive")

/// Represents a HomeKit accessory discovered in the user's home for UI display.
struct DiscoveredAccessory: Identifiable, Equatable {
    let id: UUID                  // accessory.uniqueIdentifier
    let name: String
    let roomName: String
    let homeName: String
    let categoryType: String
    let isReachable: Bool
    let sensorTypes: [String]     // e.g. ["motion", "contact", "outlet"]

    static func == (lhs: DiscoveredAccessory, rhs: DiscoveredAccessory) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.roomName == rhs.roomName
            && lhs.isReachable == rhs.isReachable
    }
}

/// Ingests passive HomeKit sensor signals (contact, motion, outlet) into local memory records.
@Observable @MainActor
final class HomeKitPassiveEventService: NSObject {
    enum Status: Equatable {
        case idle
        case waitingForHomes
        case restricted
        case running(homes: Int, accessories: Int)
        case failed(String)
    }

    var status: Status = .idle
    var lastEventSummary: String?

    /// All discovered accessories from HomeKit homes
    var discoveredAccessories: [DiscoveredAccessory] = []

    /// UUIDs of accessories the caregiver has enabled for monitoring
    var monitoredAccessoryIDs: Set<UUID> {
        didSet { persistMonitoredIDs() }
    }

    private let homeManager = HMHomeManager()
    private var modelContext: ModelContext?
    private var everMemOSClient: EverMemOSClient?
    private var isStarted = false
    private var homeRefreshTask: Task<Void, Never>?

    private var characteristicValueCache: [String: String] = [:]
    private var lastEventTimeByCharacteristic: [String: Date] = [:]
    private var accessoryHomeMap: [UUID: HMHome] = [:]

    private let groupID = "memo_homekit_passive_group"
    private let groupName = "Memo 家居被动事件"
    private let duplicateWindow: TimeInterval = 2
    private static let monitoredIDsKey = "homekit_monitored_accessory_ids"

    override init() {
        // Restore persisted selections
        if let saved = UserDefaults.standard.array(forKey: Self.monitoredIDsKey) as? [String] {
            monitoredAccessoryIDs = Set(saved.compactMap { UUID(uuidString: $0) })
        } else {
            monitoredAccessoryIDs = []
        }
        super.init()
    }

    /// Toggle monitoring for an accessory. If it was never selected before, enable it.
    func setMonitored(_ accessoryID: UUID, enabled: Bool) {
        if enabled {
            monitoredAccessoryIDs.insert(accessoryID)
        } else {
            monitoredAccessoryIDs.remove(accessoryID)
        }
        // Re-bind to apply changes
        rebindHomes(homeManager.homes)
    }

    func isMonitored(_ accessoryID: UUID) -> Bool {
        monitoredAccessoryIDs.contains(accessoryID)
    }

    /// Enable all currently discovered accessories
    func enableAll() {
        for acc in discoveredAccessories {
            monitoredAccessoryIDs.insert(acc.id)
        }
        rebindHomes(homeManager.homes)
    }

    /// Disable all accessories
    func disableAll() {
        monitoredAccessoryIDs.removeAll()
        rebindHomes(homeManager.homes)
    }

    private func persistMonitoredIDs() {
        let strings = monitoredAccessoryIDs.map(\.uuidString)
        UserDefaults.standard.set(strings, forKey: Self.monitoredIDsKey)
    }

    func start(context: ModelContext, client: EverMemOSClient? = nil) {
        guard !isStarted else { return }
        isStarted = true
        modelContext = context
        everMemOSClient = client
        homeManager.delegate = self
        registerLifecycleObserver()

        logger.info("🏠 HomeKit 服务启动中...")
        logger.info("🔑 EverMemOSClient 配置: \(client != nil ? "已配置" : "未配置")")

        refreshStatusFromAuthorization()
        probeHomes(reason: "start")
    }

    private func refreshStatusFromAuthorization() {
        if #available(iOS 13.0, *) {
            let auth = homeManager.authorizationStatus
            logger.info("🔐 HomeKit 授权状态: \(self.describeAuthorizationStatus(auth), privacy: .public)")
            applyAuthorizationStatus(auth)
        }
    }

    @available(iOS 13.0, *)
    private func applyAuthorizationStatus(_ auth: HMHomeManagerAuthorizationStatus) {
        if auth.contains(.authorized) {
            return
        }

        if auth.contains(.restricted) {
            logger.warning("⛔️ HomeKit 权限受系统限制")
            status = .restricted
            return
        }

        if auth.contains(.determined) {
            logger.info("⌛️ HomeKit 权限等待系统完成确认")
            if homeManager.homes.isEmpty {
                status = .waitingForHomes
            }
            return
        }

        logger.warning("⛔️ HomeKit 未授权")
        status = .restricted
    }

    @available(iOS 13.0, *)
    private func describeAuthorizationStatus(_ auth: HMHomeManagerAuthorizationStatus) -> String {
        var parts: [String] = ["raw=\(auth.rawValue)"]
        if auth.contains(.determined) {
            parts.append("determined")
        }
        if auth.contains(.restricted) {
            parts.append("restricted")
        }
        if auth.contains(.authorized) {
            parts.append("authorized")
        }
        return parts.joined(separator: ",")
    }

    private func probeHomes(reason: String) {
        if !homeManager.homes.isEmpty {
            logger.info("✅ 发现 \(self.homeManager.homes.count) 个家庭")
            homeRefreshTask?.cancel()
            homeRefreshTask = nil
            rebindHomes(homeManager.homes)
        } else if status != .restricted {
            logger.warning("⚠️ 未发现家庭，等待 HomeKit 加载...")
            status = .waitingForHomes
            scheduleHomeRefreshIfNeeded(trigger: reason)
        }
    }

    private func scheduleHomeRefreshIfNeeded(trigger: String) {
        guard homeRefreshTask == nil else { return }

        homeRefreshTask = Task { [weak self] in
            let delays: [UInt64] = [1_000_000_000, 3_000_000_000, 5_000_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    guard self.homeManager.homes.isEmpty else {
                        self.homeRefreshTask = nil
                        return
                    }
                    self.probeHomes(reason: "retry-after-\(delay / 1_000_000_000)s-\(trigger)")
                }
            }
            await MainActor.run {
                self?.homeRefreshTask = nil
            }
        }
    }

    private func registerLifecycleObserver() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        #endif
    }

    #if canImport(UIKit)
    @objc private func handleApplicationDidBecomeActive() {
        probeHomes(reason: "didBecomeActive")
    }
    #endif

    private func rebindHomes(_ homes: [HMHome]) {
        accessoryHomeMap.removeAll()

        var discovered: [DiscoveredAccessory] = []
        var monitoredCount = 0
        let isFirstDiscovery = discoveredAccessories.isEmpty && monitoredAccessoryIDs.isEmpty

        for home in homes {
            home.delegate = self
            for accessory in home.accessories {
                accessoryHomeMap[accessory.uniqueIdentifier] = home

                // Determine what sensor types this accessory provides
                let sensorTypes = Self.detectSensorTypes(accessory)
                guard !sensorTypes.isEmpty else { continue }

                discovered.append(DiscoveredAccessory(
                    id: accessory.uniqueIdentifier,
                    name: accessory.name,
                    roomName: accessory.room?.name ?? "未分配",
                    homeName: home.name,
                    categoryType: accessory.category.categoryType,
                    isReachable: accessory.isReachable,
                    sensorTypes: sensorTypes
                ))

                // Auto-enable all on first discovery (no prior selections)
                if isFirstDiscovery {
                    monitoredAccessoryIDs.insert(accessory.uniqueIdentifier)
                }

                // Only bind if caregiver has enabled this accessory
                if monitoredAccessoryIDs.contains(accessory.uniqueIdentifier) {
                    monitoredCount += 1
                    bindAccessory(accessory, home: home)
                }
            }
        }
        discoveredAccessories = discovered
        status = .running(homes: homes.count, accessories: monitoredCount)
    }

    /// Detect which sensor types an accessory provides
    private static func detectSensorTypes(_ accessory: HMAccessory) -> [String] {
        var types: [String] = []
        for service in accessory.services {
            for characteristic in service.characteristics {
                switch characteristic.characteristicType {
                case HMCharacteristicTypeMotionDetected:
                    if !types.contains("motion") { types.append("motion") }
                case HMCharacteristicTypeContactState:
                    if !types.contains("contact") { types.append("contact") }
                case HMCharacteristicTypePowerState, HMCharacteristicTypeOutletInUse:
                    if !types.contains("outlet") { types.append("outlet") }
                default:
                    break
                }
            }
        }
        // Also include accessories matched by name/category (existing logic)
        if accessory.name.contains("Motion") && !types.contains("motion") {
            types.append("motion")
        }
        if accessory.category.categoryType == HMAccessoryCategoryTypeOutlet && !types.contains("outlet") {
            types.append("outlet")
        }
        return types
    }

    private func bindAccessory(_ accessory: HMAccessory, home: HMHome) {
        accessory.delegate = self
        accessoryHomeMap[accessory.uniqueIdentifier] = home

        logger.info("🔗 绑定配件: \(accessory.name) (房间: \(accessory.room?.name ?? "未分配"))")

        let isMotionAccessory = accessory.name.contains("Motion")
        let isEveAccessory = accessory.name.contains("Eve")
        let isOutletAccessory = accessory.name.contains("Hot Water") || accessory.category.categoryType == HMAccessoryCategoryTypeOutlet

        for service in accessory.services {
            for characteristic in service.characteristics {
                // 对于 Eve 设备和插座设备，显示所有特征值以便调试
                if isEveAccessory || isOutletAccessory {
                    logger.info("🔍 设备特征: \(accessory.name) - \(service.name)")
                    logger.info("   UUID: \(characteristic.characteristicType)")
                    logger.info("   值: \(String(describing: characteristic.value))")
                    logger.info("   可读: \(characteristic.properties.contains(HMCharacteristicPropertyReadable))")
                    logger.info("   可写: \(characteristic.properties.contains(HMCharacteristicPropertyWritable))")
                    logger.info("   支持通知: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                }

                // 对于 Motion 配件，监听所有特征值
                // 对于其他配件，只监听标准特征值
                let shouldMonitor = isMotionAccessory || Self.isSupportedCharacteristic(characteristic)
                guard shouldMonitor else { continue }

                let key = characteristicCacheKey(accessory: accessory, service: service, characteristic: characteristic)

                if isMotionAccessory {
                    logger.info("🎯 Motion 配件特征: \(service.name) - UUID: \(characteristic.characteristicType)")
                    logger.info("   当前值: \(String(describing: characteristic.value))")
                    logger.info("   支持通知: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                }

                if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                    characteristic.readValue { error in
                        if let error {
                            logger.warning("HomeKit readValue failed: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        Task { @MainActor in
                            self.primeCacheIfNeeded(key: key, value: characteristic.value)
                        }
                    }
                }

                if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                    characteristic.enableNotification(true) { error in
                        if let error {
                            logger.warning("HomeKit enableNotification failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }
            }
        }
    }

    private static func isSupportedCharacteristic(_ characteristic: HMCharacteristic) -> Bool {
        characteristic.characteristicType == HMCharacteristicTypeContactState
            || characteristic.characteristicType == HMCharacteristicTypeMotionDetected
            || characteristic.characteristicType == HMCharacteristicTypePowerState
            || characteristic.characteristicType == HMCharacteristicTypeOutletInUse
    }

    private func characteristicCacheKey(
        accessory: HMAccessory,
        service: HMService,
        characteristic: HMCharacteristic
    ) -> String {
        "\(accessory.uniqueIdentifier.uuidString)|\(service.uniqueIdentifier.uuidString)|\(characteristic.characteristicType)"
    }

    private func primeCacheIfNeeded(key: String, value: Any?) {
        guard characteristicValueCache[key] == nil else { return }
        characteristicValueCache[key] = normalizedValue(value)
    }

    private func normalizedValue(_ value: Any?) -> String {
        switch value {
        case let b as Bool:
            return b ? "1" : "0"
        case let n as NSNumber:
            return n.stringValue
        case let s as String:
            return s
        case .none:
            return "nil"
        default:
            return String(describing: value)
        }
    }

    private func ingestIfChanged(
        accessory: HMAccessory,
        service: HMService,
        characteristic: HMCharacteristic
    ) {
        let key = characteristicCacheKey(accessory: accessory, service: service, characteristic: characteristic)
        let valueString = normalizedValue(characteristic.value)
        let previous = characteristicValueCache[key]
        characteristicValueCache[key] = valueString

        // First observed value is used as baseline only.
        guard let previous else { return }
        guard previous != valueString else { return }

        // Additional debounce against connection jitter.
        if let lastTime = lastEventTimeByCharacteristic[key],
           Date().timeIntervalSince(lastTime) < duplicateWindow {
            return
        }
        lastEventTimeByCharacteristic[key] = Date()

        // Upload sensor event for motion sensors (any characteristic from motion accessory)
        if accessory.name.contains("Motion") || service.name.contains("Motion") {
            uploadMotionEvent(accessory: accessory, characteristic: characteristic)
        }

        // Upload outlet in-use state changes (detect when appliance is turned on/off)
        if characteristic.characteristicType == HMCharacteristicTypeOutletInUse
            || characteristic.characteristicType == HMCharacteristicTypePowerState {
            uploadOutletEvent(accessory: accessory, characteristic: characteristic)
        }

        guard let signalText = buildSignalText(accessory: accessory, characteristic: characteristic) else {
            return
        }
        persistPassiveEvent(signalText)
    }

    private func buildSignalText(accessory: HMAccessory, characteristic: HMCharacteristic) -> String? {
        let location = accessory.room?.name ?? accessoryHomeMap[accessory.uniqueIdentifier]?.name ?? "未分配房间"
        let prefix = "HomeKit 被动事件：\(accessory.name)（\(location)）"

        switch characteristic.characteristicType {
        case HMCharacteristicTypeMotionDetected:
            guard let motion = boolValue(characteristic.value), motion else { return nil }
            return "\(prefix)检测到活动。"
        case HMCharacteristicTypeContactState:
            guard let raw = intValue(characteristic.value) else { return nil }
            // 0 = contact detected (closed), 1 = no contact (open)
            return raw == 1 ? "\(prefix)已打开。" : "\(prefix)已关闭。"
        case HMCharacteristicTypePowerState:
            guard let on = boolValue(characteristic.value) else { return nil }
            return on ? "\(prefix)已开启电源。" : "\(prefix)已关闭电源。"
        case HMCharacteristicTypeOutletInUse:
            guard let inUse = boolValue(characteristic.value) else { return nil }
            return inUse ? "\(prefix)处于用电状态。" : "\(prefix)结束用电状态。"
        default:
            return nil
        }
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private func persistPassiveEvent(_ content: String) {
        guard let modelContext else { return }

        let event = MemoryEvent(
            sender: "homekit",
            senderName: "HomeKit",
            role: "system",
            content: content,
            groupID: groupID,
            groupName: groupName,
            eventType: .action,
            syncStatus: .pendingSync,
            reviewStatus: .pendingReview
        )
        modelContext.insert(event)

        let log = EventLog(
            atomicFact: content,
            timestamp: event.deviceTime,
            parentType: "memory_event",
            parentID: event.eventID,
            userID: "patient",
            groupID: groupID
        )
        modelContext.insert(log)

        do {
            try modelContext.save()
            lastEventSummary = content
        } catch {
            logger.error("HomeKit passive event save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func uploadMotionEvent(accessory: HMAccessory, characteristic: HMCharacteristic) {
        guard let motionDetected = boolValue(characteristic.value) else { return }
        guard let modelContext else { return }

        let roomName = accessory.room?.name ?? accessoryHomeMap[accessory.uniqueIdentifier]?.name ?? "未分配房间"
        let eventType = motionDetected ? "detected" : "cleared"
        let timestamp = Date()

        logger.info("📍 Motion 事件: \(accessory.name) [\(roomName)] - \(eventType)")

        let sensorEvent = SensorEvent(
            sensorID: accessory.uniqueIdentifier.uuidString,
            sensorType: "motion",
            roomName: roomName,
            eventType: eventType,
            timestamp: timestamp,
            uploadStatus: .pending
        )
        modelContext.insert(sensorEvent)

        Task {
            guard let client = everMemOSClient else {
                logger.warning("⚠️ EverMemOSClient 未配置，跳过上传")
                return
            }
            do {
                logger.info("⬆️ 开始上传传感器事件: \(roomName) \(eventType)")

                // 根据房间和事件类型生成有意义的记录
                let content: String
                if eventType == "detected" {
                    content = "患者进入\(roomName)"
                } else {
                    content = "患者离开\(roomName)"
                }

                let request = MemorizeRequest(
                    messageId: sensorEvent.eventID,
                    createTime: ISO8601DateFormatter().string(from: timestamp),
                    sender: "homekit_sensor",
                    content: content,
                    groupId: "homekit_motion_sensors",
                    groupName: "房间活动记录",
                    senderName: "HomeKit 传感器",
                    role: "system",
                    flush: true
                )

                logger.info("📤 上传内容: \(content)")

                let response = try await client.memorize(request)
                await MainActor.run {
                    sensorEvent.uploadStatus = .uploaded
                    try? modelContext.save()
                }
                logger.info("✅ 传感器事件上传成功")
            } catch {
                await MainActor.run {
                    sensorEvent.uploadStatus = .failed
                    try? modelContext.save()
                }
                logger.error("❌ 传感器事件上传失败: \(error.localizedDescription)")
            }
        }
    }

    private func uploadOutletEvent(accessory: HMAccessory, characteristic: HMCharacteristic) {
        guard let powerOn = boolValue(characteristic.value) else { return }
        guard let modelContext else { return }

        let roomName = accessory.room?.name ?? accessoryHomeMap[accessory.uniqueIdentifier]?.name ?? "未分配房间"
        let eventType = powerOn ? "on" : "off"
        let timestamp = Date()

        logger.info("🔌 插座事件: \(accessory.name) [\(roomName)] - \(eventType)")

        let sensorEvent = SensorEvent(
            sensorID: accessory.uniqueIdentifier.uuidString,
            sensorType: "outlet",
            roomName: roomName,
            eventType: eventType,
            timestamp: timestamp,
            uploadStatus: .pending
        )
        modelContext.insert(sensorEvent)

        Task {
            guard let client = everMemOSClient else {
                logger.warning("⚠️ EverMemOSClient 未配置，跳过上传")
                return
            }
            do {
                logger.info("⬆️ 开始上传插座事件: \(roomName) \(eventType)")

                let content = powerOn ? "患者打开了\(roomName)的\(accessory.name)" : "患者关闭了\(roomName)的\(accessory.name)"

                let request = MemorizeRequest(
                    messageId: sensorEvent.eventID,
                    createTime: ISO8601DateFormatter().string(from: timestamp),
                    sender: "homekit_outlet",
                    content: content,
                    groupId: "homekit_outlet_sensors",
                    groupName: "电器使用记录",
                    senderName: "HomeKit 插座",
                    role: "system",
                    flush: true
                )

                logger.info("📤 上传内容: \(content)")

                let response = try await client.memorize(request)
                await MainActor.run {
                    sensorEvent.uploadStatus = .uploaded
                    try? modelContext.save()
                }
                logger.info("✅ 插座事件上传成功")
            } catch {
                await MainActor.run {
                    sensorEvent.uploadStatus = .failed
                    try? modelContext.save()
                }
                logger.error("❌ 插座事件上传失败: \(error.localizedDescription)")
            }
        }
    }
}

extension HomeKitPassiveEventService: @preconcurrency HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        logger.info("🏠 HomeManager 更新: \(manager.homes.count) 个家庭")
        refreshStatusFromAuthorization()
        guard status != .restricted else { return }
        if manager.homes.isEmpty {
            status = .waitingForHomes
            return
        }
        rebindHomes(manager.homes)
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        logger.info("➕ 添加家庭: \(home.name)")
        rebindHomes(manager.homes)
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        logger.info("➖ 移除家庭: \(home.name)")
        rebindHomes(manager.homes)
    }

    @available(iOS 13.0, *)
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        logger.info("🔐 授权状态更新: \(self.describeAuthorizationStatus(status), privacy: .public)")
        applyAuthorizationStatus(status)
        guard status.contains(.authorized) else { return }
        if manager.homes.isEmpty {
            self.status = .waitingForHomes
        } else {
            rebindHomes(manager.homes)
        }
    }
}

extension HomeKitPassiveEventService: @preconcurrency HMHomeDelegate {
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        bindAccessory(accessory, home: home)
        rebindHomes(homeManager.homes)
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        accessoryHomeMap.removeValue(forKey: accessory.uniqueIdentifier)
        rebindHomes(homeManager.homes)
    }

    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) {
        accessoryHomeMap[accessory.uniqueIdentifier] = home
    }
}

extension HomeKitPassiveEventService: @preconcurrency HMAccessoryDelegate {
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        logger.info("🔄 配件服务更新: \(accessory.name)")
        guard let home = accessoryHomeMap[accessory.uniqueIdentifier] else { return }
        bindAccessory(accessory, home: home)
    }

    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        logger.info("📡 特征值更新: \(accessory.name) - \(characteristic.characteristicType) = \(String(describing: characteristic.value))")
        ingestIfChanged(accessory: accessory, service: service, characteristic: characteristic)
    }
}
