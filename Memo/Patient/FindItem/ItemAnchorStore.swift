import ARKit
import Foundation
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "ItemAnchorStore")

// MARK: - Item Anchor Store (SwiftData)

@Observable @MainActor
final class ItemAnchorStore {

    private(set) var items: [SpatialAnchor] = []
    private let modelContext: ModelContext
    private let baseDir: URL

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseDir = docs.appendingPathComponent("FindItemMaps", isDirectory: true)
        ensureDirectoryExists()
        loadItems()
        cleanupLegacyFiles()
    }

    var hasItems: Bool { !items.isEmpty }

    // MARK: - Shared World Map I/O

    private var sharedMapURL: URL { baseDir.appendingPathComponent("sharedWorldMap.dat") }

    func saveSharedWorldMap(data: Data) throws {
        try data.write(to: sharedMapURL, options: .atomic)
        logger.info("Saved shared world map (\(data.count) bytes)")
    }

    func loadSharedWorldMap() -> Data? {
        guard FileManager.default.fileExists(atPath: sharedMapURL.path) else { return nil }
        return try? Data(contentsOf: sharedMapURL)
    }

    // MARK: - Room World Map I/O

    func roomMapURL(for roomID: String) -> URL {
        baseDir.appendingPathComponent(roomID, isDirectory: true)
            .appendingPathComponent("worldMap.dat")
    }

    func saveRoomWorldMap(roomID: String, data: Data) throws {
        let maxSize = 100 * 1024 * 1024 // 100 MB
        guard data.count <= maxSize else {
            throw FindItemMapError.mapTooLarge(data.count)
        }
        let dir = baseDir.appendingPathComponent(roomID, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("worldMap.dat")
        try data.write(to: url, options: .atomic)
        try (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
        logger.info("Saved room world map for \(roomID) (\(data.count) bytes)")
    }

    func loadRoomWorldMap(roomID: String) -> Data? {
        let url = roomMapURL(for: roomID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Validate the data can be deserialized
        if (try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)) == nil {
            logger.warning("Room world map for \(roomID) failed validation — returning nil")
            return nil
        }
        return data
    }

    func deleteRoomWorldMap(roomID: String) {
        let dir = baseDir.appendingPathComponent(roomID, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        logger.info("Deleted room world map directory for \(roomID)")
    }

    func roomMapSizeBytes(roomID: String) -> Int {
        let url = roomMapURL(for: roomID)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    // MARK: - Room-based Item Query

    func items(forRoom roomID: String?) -> [SpatialAnchor] {
        items.filter { $0.roomID == roomID }
    }

    // MARK: - Item CRUD

    func addItem(name: String, emoji: String, anchorID: String,
                 posX: Float, posY: Float, posZ: Float,
                 rotX: Float, rotY: Float, rotZ: Float, rotW: Float,
                 confidence: Float, mappingStatus: String, roomID: String? = nil) {
        let anchor = SpatialAnchor(
            anchorID: anchorID, itemName: name, emoji: emoji,
            posX: posX, posY: posY, posZ: posZ,
            rotX: rotX, rotY: rotY, rotZ: rotZ, rotW: rotW,
            confidence: confidence, mappingStatus: mappingStatus, roomID: roomID
        )
        modelContext.insert(anchor)
        try? modelContext.save()
        loadItems()
        logger.info("Added item: \(emoji) \(name) -> \(anchorID)")
    }

    func deleteItem(anchorID: String) {
        guard let anchor = items.first(where: { $0.anchorID == anchorID }) else { return }
        modelContext.delete(anchor)
        try? modelContext.save()
        loadItems()
        logger.info("Deleted item: \(anchor.itemName)")
    }

    // MARK: - Private

    private func loadItems() {
        let descriptor = FetchDescriptor<SpatialAnchor>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        items = (try? modelContext.fetch(descriptor)) ?? []
        logger.info("Loaded \(self.items.count) spatial anchors")
    }

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: baseDir.path) {
            try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        }
    }

    private func cleanupLegacyFiles() {
        let fm = FileManager.default
        // Remove legacy anchors.json
        let jsonFile = baseDir.appendingPathComponent("anchors.json")
        if fm.fileExists(atPath: jsonFile.path) {
            try? fm.removeItem(at: jsonFile)
            logger.info("Removed legacy anchors.json")
        }
        // Remove legacy per-item worldMap_*.dat files
        guard let files = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("worldMap_") {
            try? fm.removeItem(at: file)
            logger.info("Removed legacy map: \(file.lastPathComponent)")
        }
    }
}

// MARK: - Errors

enum FindItemMapError: LocalizedError {
    case mapTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .mapTooLarge(let bytes):
            String(localized: "世界地图文件过大（\(bytes / 1024 / 1024) MB），请减少扫描范围")
        }
    }
}
