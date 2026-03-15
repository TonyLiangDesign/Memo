import Foundation
import HomeKit
import SwiftData
import UserNotifications
import os.log
import EverMemOSKit
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "HomeKitPassive")

// MARK: - Eve Energy Custom Characteristic UUIDs

/// Eve Energy exposes power metering via proprietary HomeKit characteristics.
/// These are NOT standard Apple-defined types — the Apple Home app ignores them,
/// but they are fully readable via the HomeKit framework.
private enum EveCharacteristic {
    static let watts       = "E863F10D-079E-48FF-8F27-9C2605A29F52"  // UInt16, raw / 10 = W
    static let amps        = "E863F126-079E-48FF-8F27-9C2605A29F52"  // UInt16, raw / 100 = A
    static let totalKWh    = "E863F10C-079E-48FF-8F27-9C2605A29F52"  // UInt32, raw / 1000 = kWh
    static let voltAmps    = "E863F110-079E-48FF-8F27-9C2605A29F52"  // UInt16, raw / 10 = VA
    static let voltage     = "E863F10A-079E-48FF-8F27-9C2605A29F52"  // UInt16, raw / 10 = V

    static let allUUIDs: Set<String> = [watts, amps, totalKWh, voltAmps, voltage]

    static func displayName(for uuid: String) -> String? {
        switch uuid.uppercased() {
        case watts:    return String(localized: "功率(W)")
        case amps:     return String(localized: "电流(A)")
        case totalKWh: return String(localized: "累计(kWh)")
        case voltAmps: return String(localized: "视在功率(VA)")
        case voltage:  return String(localized: "电压(V)")
        default:       return nil
        }
    }

    static func convertValue(uuid: String, raw: Int) -> Double {
        switch uuid.uppercased() {
        case watts, voltAmps, voltage: return Double(raw) / 10.0
        case amps:                     return Double(raw) / 100.0
        case totalKWh:                 return Double(raw) / 1000.0
        default:                       return Double(raw)
        }
    }

    static func unit(for uuid: String) -> String {
        switch uuid.uppercased() {
        case watts:    return "W"
        case amps:     return "A"
        case totalKWh: return "kWh"
        case voltAmps: return "VA"
        case voltage:  return "V"
        default:       return ""
        }
    }
}

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
    private var lastUploadedEventByRoom: [String: String] = [:]
    private var accessoryHomeMap: [UUID: HMHome] = [:]

    private let groupID = "memo_homekit_passive_group"
    private let groupName = String(localized: "Memo 家居被动事件")
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

        // Request notification permission for power alerts
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                logger.info("🔔 通知权限已授予")
            } else {
                logger.warning("🔔 通知权限未授予: \(String(describing: error))")
            }
        }

        refreshStatusFromAuthorization()
        probeHomes(reason: "start")
    }

    func updateClient(_ client: EverMemOSClient?) {
        everMemOSClient = client
        logger.info("🔄 EverMemOSClient 已更新: \(client != nil ? "已配置" : "未配置")")
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
                    roomName: accessory.room?.name ?? String(localized: "未分配"),
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
        let isOutletAccessory = accessory.category.categoryType == HMAccessoryCategoryTypeOutlet
            || accessory.name.contains("Hot Water")

        // Dump ALL characteristics for outlet devices (Eve Energy, etc.) for debugging
        if isOutletAccessory {
            dumpAllCharacteristics(accessory)
            probeOutletInUse(accessory)
        }

        for service in accessory.services {
            for characteristic in service.characteristics {
                // 对于插座设备，显示所有特征值以便调试
                if isOutletAccessory {
                    logger.info("🔍 设备特征: \(accessory.name) - \(service.name)")
                    logger.info("   UUID: \(characteristic.characteristicType)")
                    logger.info("   值: \(String(describing: characteristic.value))")
                    logger.info("   可读: \(characteristic.properties.contains(HMCharacteristicPropertyReadable))")
                    logger.info("   可写: \(characteristic.properties.contains(HMCharacteristicPropertyWritable))")
                    logger.info("   支持通知: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")
                }

                // 对于 Motion 和 Outlet 配件，监听所有特征值（包括未知的 Matter 特征）
                // 对于其他配件，只监听标准特征值
                let shouldMonitor = isMotionAccessory || isOutletAccessory || Self.isSupportedCharacteristic(characteristic)
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
                            logger.warning("HomeKit readValue failed: \(error.localizedDescription, privacy: .public) [\(characteristic.characteristicType, privacy: .public)]")
                            return
                        }
                        // Log raw data for outlet binary characteristics
                        if isOutletAccessory, let data = characteristic.value as? Data {
                            let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                            logger.info("📦 \(accessory.name, privacy: .public) | \(characteristic.characteristicType, privacy: .public) 读取到 Data(\(data.count)bytes): \(hex, privacy: .public)")
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
            || EveCharacteristic.allUUIDs.contains(characteristic.characteristicType.uppercased())
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

            // Send local notification when device starts drawing power
            if let on = boolValue(characteristic.value), on {
                sendPowerOnNotification(accessory: accessory)
            }
        }

        // Eve Energy custom power characteristics — log detailed readings
        let upperUUID = characteristic.characteristicType.uppercased()
        if EveCharacteristic.allUUIDs.contains(upperUUID) {
            handleEveEnergyReading(accessory: accessory, characteristic: characteristic)
            return  // Eve power readings don't generate memory events
        }

        guard let signalText = buildSignalText(accessory: accessory, characteristic: characteristic) else {
            return
        }
        persistPassiveEvent(signalText)
    }

    private func buildSignalText(accessory: HMAccessory, characteristic: HMCharacteristic) -> String? {
        let location = accessory.room?.name ?? accessoryHomeMap[accessory.uniqueIdentifier]?.name ?? String(localized: "未分配房间")
        let prefix = String(localized: "HomeKit 被动事件：\(accessory.name)（\(location)）")

        switch characteristic.characteristicType {
        case HMCharacteristicTypeMotionDetected:
            guard let motion = boolValue(characteristic.value), motion else { return nil }
            return String(localized: "\(prefix)检测到活动。")
        case HMCharacteristicTypeContactState:
            guard let raw = intValue(characteristic.value) else { return nil }
            // 0 = contact detected (closed), 1 = no contact (open)
            return raw == 1 ? String(localized: "\(prefix)已打开。") : String(localized: "\(prefix)已关闭。")
        case HMCharacteristicTypePowerState:
            guard let on = boolValue(characteristic.value) else { return nil }
            return on ? String(localized: "\(prefix)已开启电源。") : String(localized: "\(prefix)已关闭电源。")
        case HMCharacteristicTypeOutletInUse:
            guard let inUse = boolValue(characteristic.value) else { return nil }
            return inUse ? String(localized: "\(prefix)处于用电状态。") : String(localized: "\(prefix)结束用电状态。")
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
            role: "assistant",
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

    // MARK: - Probe Hidden Characteristics

    /// Force-probe OutletInUse (0x26) even if not listed in service enumeration.
    /// Also probe all known Eve custom UUIDs and other power-related characteristics.
    private func probeOutletInUse(_ accessory: HMAccessory) {
        logger.info("🔎 [Probe] 开始强制探测 \(accessory.name, privacy: .public) 的隐藏特征...")

        // Collect all characteristics from all services for direct reading
        let outletInUseUUID = "00000026-0000-1000-8000-0026BB765291"

        // Check all services for OutletInUse that might have been missed
        for service in accessory.services {
            for characteristic in service.characteristics {
                let uuid = characteristic.characteristicType.uppercased()

                if uuid == outletInUseUUID {
                    logger.info("🔎 [Probe] ✅ 找到 OutletInUse! 服务: \(service.name, privacy: .public)")
                    logger.info("🔎 [Probe]    值: \(String(describing: characteristic.value), privacy: .public)")
                    logger.info("🔎 [Probe]    可读: \(characteristic.properties.contains(HMCharacteristicPropertyReadable))")
                    logger.info("🔎 [Probe]    通知: \(characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification))")

                    if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                        characteristic.readValue { error in
                            if let error {
                                logger.warning("🔎 [Probe] OutletInUse 读取失败: \(error.localizedDescription)")
                            } else {
                                logger.info("🔎 [Probe] OutletInUse 读取成功: \(String(describing: characteristic.value), privacy: .public)")
                            }
                        }
                    }

                    if characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) {
                        characteristic.enableNotification(true) { error in
                            if let error {
                                logger.warning("🔎 [Probe] OutletInUse 通知订阅失败: \(error.localizedDescription)")
                            } else {
                                logger.info("🔎 [Probe] OutletInUse 通知订阅成功")
                            }
                        }
                    }
                    return
                }
            }
        }

        logger.info("🔎 [Probe] ❌ 未在任何服务中找到 OutletInUse (0x26)")

        // Also try reading the Outlet service (0x47) PowerState with fresh read
        // to see current real-time value
        for service in accessory.services where service.serviceType == "00000047-0000-1000-8000-0026BB765291" {
            logger.info("🔎 [Probe] 找到 Outlet 服务，列出所有特征:")
            for characteristic in service.characteristics {
                let uuid = characteristic.characteristicType.uppercased()
                let stdName = Self.standardCharacteristicName(uuid) ?? "未知"
                logger.info("🔎 [Probe]   \(uuid, privacy: .public) (\(stdName, privacy: .public)) = \(String(describing: characteristic.value), privacy: .public)")

                // Force re-read every characteristic in outlet service
                if characteristic.properties.contains(HMCharacteristicPropertyReadable) {
                    characteristic.readValue { error in
                        if let error {
                            logger.info("🔎 [Probe]   重新读取 \(uuid, privacy: .public) 失败: \(error.localizedDescription)")
                        } else {
                            logger.info("🔎 [Probe]   重新读取 \(uuid, privacy: .public) = \(String(describing: characteristic.value), privacy: .public)")
                        }
                    }
                }
            }
        }

        // List ALL characteristic UUIDs across all services for completeness
        logger.info("🔎 [Probe] 设备所有特征 UUID 完整列表:")
        for service in accessory.services {
            for characteristic in service.characteristics {
                logger.info("🔎 [Probe]   \(service.serviceType, privacy: .public) → \(characteristic.characteristicType, privacy: .public)")
            }
        }
    }

    // MARK: - Eve Energy Power Monitoring

    /// Handle Eve Energy custom power readings
    private func handleEveEnergyReading(accessory: HMAccessory, characteristic: HMCharacteristic) {
        let uuid = characteristic.characteristicType.uppercased()
        let name = EveCharacteristic.displayName(for: uuid) ?? "未知"
        let unit = EveCharacteristic.unit(for: uuid)
        let roomName = accessory.room?.name ?? "未分配"

        if let raw = (characteristic.value as? NSNumber)?.intValue {
            let converted = EveCharacteristic.convertValue(uuid: uuid, raw: raw)
            logger.info("⚡️ [Eve] \(accessory.name, privacy: .public) [\(roomName, privacy: .public)] \(name, privacy: .public): \(converted) \(unit, privacy: .public) (raw=\(raw))")

            // Watts > 1W means device is actively consuming power
            if uuid == EveCharacteristic.watts && converted > 1.0 {
                logger.info("⚡️ [Eve] \(accessory.name, privacy: .public) 正在耗电: \(converted)W")
            }
        } else {
            logger.info("⚡️ [Eve] \(accessory.name, privacy: .public) [\(roomName, privacy: .public)] \(name, privacy: .public): \(String(describing: characteristic.value), privacy: .public)")
        }
    }

    /// Dump ALL characteristics of an accessory for debugging
    private func dumpAllCharacteristics(_ accessory: HMAccessory) {
        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        logger.info("🔌 [Outlet Debug] 设备: \(accessory.name, privacy: .public)")
        logger.info("   房间: \(accessory.room?.name ?? "未分配", privacy: .public)")
        logger.info("   可达: \(accessory.isReachable)")
        logger.info("   类别: \(accessory.category.categoryType, privacy: .public)")
        logger.info("   服务数量: \(accessory.services.count)")

        var eveCharCount = 0
        var hasOutletInUse = false
        var hasPowerState = false

        for (i, service) in accessory.services.enumerated() {
            logger.info("   📦 [\(i)] 服务: \(service.name, privacy: .public) | type: \(service.serviceType, privacy: .public)")

            for (j, characteristic) in service.characteristics.enumerated() {
                let uuid = characteristic.characteristicType.uppercased()
                let eveName = EveCharacteristic.displayName(for: uuid)
                let stdName = Self.standardCharacteristicName(uuid)
                let readable = characteristic.properties.contains(HMCharacteristicPropertyReadable)
                let writable = characteristic.properties.contains(HMCharacteristicPropertyWritable)
                let notifiable = characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification)

                var label = ""
                if let eveName {
                    label = " ★ Eve \(eveName)"
                    eveCharCount += 1
                } else if let stdName {
                    label = " (\(stdName))"
                }

                if uuid == "00000026-0000-1000-8000-0026BB765291" { hasOutletInUse = true }
                if uuid == "00000025-0000-1000-8000-0026BB765291" { hasPowerState = true }

                logger.info("      [\(j)] \(characteristic.characteristicType, privacy: .public)\(label, privacy: .public)")
                logger.info("          值: \(String(describing: characteristic.value), privacy: .public) | R:\(readable) W:\(writable) N:\(notifiable)")

                if let eveName, let raw = (characteristic.value as? NSNumber)?.intValue {
                    let converted = EveCharacteristic.convertValue(uuid: uuid, raw: raw)
                    let unit = EveCharacteristic.unit(for: uuid)
                    logger.info("          → \(converted) \(unit, privacy: .public)")
                }
            }
        }

        logger.info("   📊 总结: Eve私有特征=\(eveCharCount) OutletInUse=\(hasOutletInUse) PowerState=\(hasPowerState)")
        if eveCharCount == 0 {
            logger.info("   ⚠️ 无Eve私有功率特征 — 可能已升级Matter或固件不支持")
        }
        if !hasOutletInUse {
            logger.info("   ⚠️ 无OutletInUse特征 — 将依赖PowerState检测通电")
        }
        logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    /// Map common HomeKit characteristic UUIDs to human-readable names
    private static func standardCharacteristicName(_ uuid: String) -> String? {
        // Standard HomeKit characteristic type UUIDs (short form)
        switch uuid {
        case "00000025-0000-1000-8000-0026BB765291": return "PowerState 电源开关"
        case "00000026-0000-1000-8000-0026BB765291": return "OutletInUse 正在用电"
        case "00000023-0000-1000-8000-0026BB765291": return "Name 名称"
        case "00000030-0000-1000-8000-0026BB765291": return "SerialNumber 序列号"
        case "00000020-0000-1000-8000-0026BB765291": return "Manufacturer 厂商"
        case "00000021-0000-1000-8000-0026BB765291": return "Model 型号"
        case "00000052-0000-1000-8000-0026BB765291": return "FirmwareRevision 固件版本"
        case "00000037-0000-1000-8000-0026BB765291": return "Version"
        case "00000220-0000-1000-8000-0026BB765291": return "ProductData"
        case "000000A6-0000-1000-8000-0026BB765291": return "AccessoryFlags"
        case "00000079-0000-1000-8000-0026BB765291": return "StatusActive"
        default: return nil
        }
    }

    /// Send a local notification when an outlet/device starts drawing power
    private func sendPowerOnNotification(accessory: HMAccessory) {
        let roomName = accessory.room?.name ?? "未分配"
        let content = UNMutableNotificationContent()
        content.title = "设备通电"
        content.body = "\(accessory.name)（\(roomName)）开始用电"
        content.sound = .default
        content.categoryIdentifier = "HOMEKIT_POWER"

        let request = UNNotificationRequest(
            identifier: "power_on_\(accessory.uniqueIdentifier.uuidString)_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("❌ 本地通知发送失败: \(error.localizedDescription)")
            } else {
                logger.info("🔔 通电通知已发送: \(accessory.name, privacy: .public) [\(roomName, privacy: .public)]")
            }
        }
    }

    private func uploadMotionEvent(accessory: HMAccessory, characteristic: HMCharacteristic) {
        guard let motionDetected = boolValue(characteristic.value) else { return }
        guard let modelContext else { return }

        let roomName = accessory.room?.name ?? accessoryHomeMap[accessory.uniqueIdentifier]?.name ?? "未分配房间"
        let eventType = motionDetected ? "detected" : "cleared"

        // Skip if same event type for this room
        let roomKey = "\(roomName)_motion"
        if lastUploadedEventByRoom[roomKey] == eventType {
            return
        }
        lastUploadedEventByRoom[roomKey] = eventType

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
                let isEnglish = Locale.current.language.languageCode?.identifier == "en"
                let content: String
                if eventType == "detected" {
                    content = isEnglish ? "Patient entered \(roomName)" : "患者进入\(roomName)"
                } else {
                    content = isEnglish ? "Patient left \(roomName)" : "患者离开\(roomName)"
                }

                let deviceID = DeviceIDManager.shared.deviceID
                let augmentedSender = DeviceIDHelper.augment(userId: "homekit_sensor", with: deviceID)
                let augmentedGroupID = DeviceIDHelper.augment(groupId: "homekit_motion_sensors", with: deviceID)
                let request = MemorizeRequest(
                    messageId: sensorEvent.eventID,
                    createTime: ISO8601DateFormatter().string(from: timestamp),
                    sender: augmentedSender,
                    content: content,
                    groupId: augmentedGroupID,
                    groupName: "房间活动记录",
                    senderName: "HomeKit 传感器",
                    role: "assistant",
                    flush: true
                )

                logger.info("📤 上传内容: \(content)")

                _ = try? await client.memorize(request)
                await MainActor.run {
                    sensorEvent.uploadStatus = .uploaded
                    self.lastEventSummary = content
                    try? modelContext.save()
                }
                logger.info("✅ 传感器事件上传成功")

                // Clear after 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    if self.lastEventSummary == content {
                        self.lastEventSummary = nil
                    }
                }
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

        // Skip if same event type for this outlet
        let outletKey = "\(accessory.uniqueIdentifier.uuidString)_outlet"
        if lastUploadedEventByRoom[outletKey] == eventType {
            return
        }
        lastUploadedEventByRoom[outletKey] = eventType

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

                let isEnglish = Locale.current.language.languageCode?.identifier == "en"
                let content = powerOn
                    ? (isEnglish ? "Patient turned on \(accessory.name) in \(roomName)" : "患者打开了\(roomName)的\(accessory.name)")
                    : (isEnglish ? "Patient turned off \(accessory.name) in \(roomName)" : "患者关闭了\(roomName)的\(accessory.name)")

                let deviceID = DeviceIDManager.shared.deviceID
                let augmentedSender = DeviceIDHelper.augment(userId: "homekit_outlet", with: deviceID)
                let augmentedGroupID = DeviceIDHelper.augment(groupId: "homekit_outlet_sensors", with: deviceID)
                let request = MemorizeRequest(
                    messageId: sensorEvent.eventID,
                    createTime: ISO8601DateFormatter().string(from: timestamp),
                    sender: augmentedSender,
                    content: content,
                    groupId: augmentedGroupID,
                    groupName: "电器使用记录",
                    senderName: "HomeKit 插座",
                    role: "assistant",
                    flush: true
                )

                logger.info("📤 上传内容: \(content)")

                _ = try? await client.memorize(request)
                await MainActor.run {
                    sensorEvent.uploadStatus = .uploaded
                    self.lastEventSummary = content
                    try? modelContext.save()
                }
                logger.info("✅ 插座事件上传成功")

                // Clear after 5 seconds
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await MainActor.run {
                    if self.lastEventSummary == content {
                        self.lastEventSummary = nil
                    }
                }
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
        let uuid = characteristic.characteristicType.uppercased()
        let eveName = EveCharacteristic.displayName(for: uuid)
        let stdName = Self.standardCharacteristicName(uuid)

        if let eveName {
            if let raw = (characteristic.value as? NSNumber)?.intValue {
                let converted = EveCharacteristic.convertValue(uuid: uuid, raw: raw)
                let unit = EveCharacteristic.unit(for: uuid)
                logger.info("📡 [Eve] \(accessory.name, privacy: .public) \(eveName, privacy: .public) 更新: \(converted) \(unit, privacy: .public)")
            } else {
                logger.info("📡 [Eve] \(accessory.name, privacy: .public) \(eveName, privacy: .public) 更新: \(String(describing: characteristic.value), privacy: .public)")
            }
        } else if let stdName {
            logger.info("📡 \(accessory.name, privacy: .public) | \(stdName, privacy: .public) = \(String(describing: characteristic.value), privacy: .public)")
        } else {
            // Unknown characteristic — dump raw data in detail (might be Matter energy data)
            let valueDesc: String
            if let data = characteristic.value as? Data {
                let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
                valueDesc = "Data(\(data.count)bytes): \(hex)"
            } else if let num = characteristic.value as? NSNumber {
                valueDesc = "NSNumber: \(num) (int=\(num.intValue) float=\(num.floatValue))"
            } else {
                valueDesc = "\(String(describing: characteristic.value)) [type: \(type(of: characteristic.value))]"
            }
            logger.info("📡🔬 \(accessory.name, privacy: .public) | 未知特征 \(characteristic.characteristicType, privacy: .public) = \(valueDesc, privacy: .public)")
        }

        ingestIfChanged(accessory: accessory, service: service, characteristic: characteristic)
    }
}
