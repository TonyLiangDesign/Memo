import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "FaceDataStore")

/// File-system store for face samples and reference embeddings.
/// Layout: ~/Documents/FaceData/{contactID}/
///   samples/sample_0.jpg ... sample_9.jpg
///   reference_embedding.bin  (512 × Float32 = 2048 bytes)
final class FaceDataStore {

    private let baseDir: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        baseDir = docs.appendingPathComponent("FaceData", isDirectory: true)
        ensureDirectoryExists(baseDir)
    }

    // MARK: - Directories

    func contactDirectory(for contactID: String) -> URL {
        baseDir.appendingPathComponent(contactID, isDirectory: true)
    }

    func samplesDirectory(for contactID: String) -> URL {
        contactDirectory(for: contactID)
            .appendingPathComponent("samples", isDirectory: true)
    }

    // MARK: - Sample I/O

    func saveSample(_ image: CGImage, contactID: String, index: Int, orientation: CGImagePropertyOrientation = .up) throws -> URL {
        let dir = samplesDirectory(for: contactID)
        ensureDirectoryExists(dir)

        let url = dir.appendingPathComponent("sample_\(index).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw FaceDataError.writeFailed("Cannot create image destination")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8,
            kCGImagePropertyOrientation: orientation.rawValue
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FaceDataError.writeFailed("Failed to write JPEG")
        }

        try setFileProtection(url)
        logger.info("Saved face sample \(index) for contact \(contactID) with orientation \(orientation.rawValue)")
        return url
    }

    func loadSamples(for contactID: String) -> [(image: CGImage, orientation: CGImagePropertyOrientation)] {
        let dir = samplesDirectory(for: contactID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        var samples: [(image: CGImage, orientation: CGImagePropertyOrientation)] = []
        for i in 0..<10 {
            let url = dir.appendingPathComponent("sample_\(i).jpg")
            guard fm.fileExists(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }

            let orientation: CGImagePropertyOrientation
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let orientationValue = props[kCGImagePropertyOrientation] as? UInt32 {
                orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
            } else {
                orientation = .up
            }

            samples.append((image: image, orientation: orientation))
        }
        return samples
    }

    func sampleCount(for contactID: String) -> Int {
        let dir = samplesDirectory(for: contactID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return 0 }

        var count = 0
        for i in 0..<10 {
            let url = dir.appendingPathComponent("sample_\(i).jpg")
            if fm.fileExists(atPath: url.path) { count += 1 }
        }
        return count
    }

    func deleteSamples(for contactID: String) throws {
        let dir = samplesDirectory(for: contactID)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
            logger.info("Deleted samples for contact \(contactID)")
        }
    }

    // MARK: - Embedding I/O

    private func embeddingURL(for contactID: String) -> URL {
        contactDirectory(for: contactID)
            .appendingPathComponent("reference_embedding.bin")
    }

    func saveReferenceEmbedding(_ embedding: [Float], contactID: String) throws {
        let dir = contactDirectory(for: contactID)
        ensureDirectoryExists(dir)

        let url = embeddingURL(for: contactID)
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
        try setFileProtection(url)
        logger.info("Saved reference embedding for contact \(contactID) (\(embedding.count) dims, \(data.count) bytes)")
    }

    func loadReferenceEmbedding(contactID: String) -> [Float]? {
        let url = embeddingURL(for: contactID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return nil }

        let embedding = data.withUnsafeBytes { ptr -> [Float] in
            let floatPtr = ptr.bindMemory(to: Float.self)
            return Array(floatPtr)
        }
        return embedding
    }

    // MARK: - Bulk Load

    /// Load all registered embeddings (called at patient-mode startup).
    func loadAllEmbeddings() -> [(contactID: String, embedding: [Float])] {
        let fm = FileManager.default
        guard let contactDirs = try? fm.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var results: [(contactID: String, embedding: [Float])] = []
        for dir in contactDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let contactID = dir.lastPathComponent
            if let emb = loadReferenceEmbedding(contactID: contactID) {
                results.append((contactID: contactID, embedding: emb))
            }
        }
        logger.info("Loaded \(results.count) registered face embeddings")
        return results
    }

    // MARK: - Cleanup

    func deleteAllData(for contactID: String) throws {
        let dir = contactDirectory(for: contactID)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
            logger.info("Deleted all face data for contact \(contactID)")
        }
    }

    // MARK: - Private

    private func ensureDirectoryExists(_ dir: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func setFileProtection(_ url: URL) throws {
        try (url as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication,
            forKey: .fileProtectionKey
        )
    }
}

// MARK: - Errors

enum FaceDataError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let msg): return String(localized: "人脸数据写入失败：\(msg)")
        }
    }
}
