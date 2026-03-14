import SwiftUI
import RealityKit
import ARKit
import EverMemOSKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "RecordFeature")

/// Extracted record (记一记) business logic kernel.
/// Manages the capture → recognize → save → sync pipeline independently of any particular UI shell.
@Observable @MainActor
final class RecordFeature {

    // MARK: - Phase

    enum Phase: Equatable {
        case ready
        case capturing
        case recognized(GeminiItemResult)
        case saving
        case success(item: String, room: String?)
        case error(String)
    }

    var phase: Phase = .ready

    // MARK: - Capture Pipeline

    /// Full capture-and-record pipeline: snapshot AR frame → Gemini recognition → place anchor → save world map → sync to EverMemOS.
    func capture(
        arView: ARView,
        findManager: FindItemManager,
        geminiService: GeminiMedicationService,
        apiClient: EverMemOSClient?,
        roomID: String? = nil,
        roomName: String? = nil
    ) {
        phase = .capturing
        let anchorResult = findManager.placeAnchor(in: arView, lateral: -0.15)

        Task {
            guard let frame = arView.session.currentFrame else {
                phase = .error(String(localized: "无法获取相机画面")); return
            }
            guard let result = await geminiService.analyzeFrame(frame.capturedImage) else {
                phase = .error(String(localized: "识别失败")); return
            }
            phase = .recognized(result)

            guard let (anchorID, transform) = anchorResult else {
                phase = .error(String(localized: "无法放置空间锚点")); return
            }
            arView.scene.addAnchor(
                FindItemARContainer.createMarkerEntity(
                    name: "\(result.emoji) \(result.item)", at: transform
                )
            )
            phase = .saving
            do {
                try await findManager.saveItem(
                    name: result.item, emoji: result.emoji,
                    anchorID: anchorID, roomID: roomID, in: arView
                )
                phase = .success(item: "\(result.emoji) \(result.item)", room: roomName)
                memorizeToEverMemOS(result, roomName: roomName, client: apiClient)
                try? await Task.sleep(for: .seconds(2))
                phase = .ready
                findManager.anchorPlaced = false
                findManager.worldMapSaved = false
                arView.scene.anchors.removeAll()
            } catch {
                phase = .error(String(localized: "保存失败：\(error.localizedDescription)"))
            }
        }
    }

    // MARK: - EverMemOS Sync

    private func memorizeToEverMemOS(_ result: GeminiItemResult, roomName: String?, client: EverMemOSClient?) {
        guard let client else {
            logger.warning("[Memorize] No API client configured")
            return
        }
        let locationPart = roomName.map { "，放置在\($0)" } ?? ""
        let content = "患者记录了一个物品：\(result.emoji) \(result.item)\(locationPart)。场景描述：\(result.description)"
        logger.info("[Memorize] Recording item: \(result.emoji) \(result.item), room: \(roomName ?? "nil")")
        let deviceID = DeviceIDManager.shared.deviceID
        Task.detached {
            let augmentedSender = DeviceIDHelper.augment(userId: "patient", with: deviceID)
            let augmentedGroupID = DeviceIDHelper.augment(groupId: "memo_patient_default_group", with: deviceID)
            let req = MemorizeRequest(
                messageId: UUID().uuidString,
                createTime: ISO8601DateFormatter().string(from: Date()),
                sender: augmentedSender,
                content: content,
                groupId: augmentedGroupID,
                groupName: String(localized: "Memo 患者记忆"),
                senderName: String(localized: "患者"),
                role: "user",
                flush: true
            )
            do {
                let result = try await client.memorize(req)
                logger.info("[Memorize] Success: \(result.message ?? "ok")")
            } catch {
                logger.error("[Memorize] Failed: \(error.localizedDescription)")
            }
        }
    }
}
