import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "SchemaMigration")

struct SchemaMigration {

    private static let versionKey = "memoSchemaVersion"

    static func runIfNeeded(context: ModelContext) {
        let current = UserDefaults.standard.integer(forKey: versionKey)
        if current < 1 {
            migrateV0toV1(context: context)
        }
        if current < 2 {
            migrateV1toV2(context: context)
        }
    }

    // MARK: - v0 → v1: Room-based world maps

    private static func migrateV0toV1(context: ModelContext) {
        logger.info("Starting schema migration v0 → v1")

        do {
            // 1. Create a default room
            let defaultRoom = RoomProfile(name: "默认", emoji: "🏠", status: .ready)
            context.insert(defaultRoom)

            // 2. Copy sharedWorldMap.dat to the default room directory
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let baseDir = docs.appendingPathComponent("FindItemMaps", isDirectory: true)
            let sharedMapURL = baseDir.appendingPathComponent("sharedWorldMap.dat")

            if FileManager.default.fileExists(atPath: sharedMapURL.path) {
                let roomDir = baseDir.appendingPathComponent(defaultRoom.roomID, isDirectory: true)
                try FileManager.default.createDirectory(at: roomDir, withIntermediateDirectories: true)
                let destURL = roomDir.appendingPathComponent("worldMap.dat")
                try FileManager.default.copyItem(at: sharedMapURL, to: destURL)
                defaultRoom.lastScannedAt = Date()
                defaultRoom.lastMapSizeBytes = (try? Data(contentsOf: destURL))?.count ?? 0
                logger.info("Copied sharedWorldMap.dat to room \(defaultRoom.roomID)")
            } else {
                // No existing map — mark room as draft
                defaultRoom.statusEnum = .draft
                logger.info("No sharedWorldMap.dat found, default room set to draft")
            }

            // 3. Existing SpatialAnchors keep roomID = nil (no forced binding)

            try context.save()
            UserDefaults.standard.set(1, forKey: versionKey)
            logger.info("Schema migration v0 → v1 completed")
        } catch {
            logger.warning("Schema migration v0 → v1 failed: \(error.localizedDescription). Will retry next launch.")
        }
    }

    // MARK: - v1 → v2: Initialize memory card pool

    private static func migrateV1toV2(context: ModelContext) {
        logger.info("Starting schema migration v1 → v2")
        let service = DailyMemoryService()
        service.refreshCardPool(context: context)
        UserDefaults.standard.set(2, forKey: versionKey)
        logger.info("Schema migration v1 → v2 completed — initial card pool generated")
    }
}
