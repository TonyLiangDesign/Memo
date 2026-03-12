import ARKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "ARMultiplexer")

/// Forwards ARSessionDelegate callbacks to multiple registered delegates.
/// Solves ARKit's single-delegate limitation by acting as a fan-out proxy.
final class ARSessionDelegateMultiplexer: NSObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: - Weak Wrapper

    private struct WeakDelegate {
        weak var value: (any ARSessionDelegate)?
    }

    // MARK: - Storage

    private var delegates: [WeakDelegate] = []
    private let lock = NSLock()

    // MARK: - Registration

    @MainActor
    func addDelegate(_ delegate: any ARSessionDelegate) {
        lock.lock()
        defer { lock.unlock() }

        // Avoid duplicates
        delegates.removeAll { $0.value === nil || $0.value === delegate as AnyObject }
        delegates.append(WeakDelegate(value: delegate))
        logger.debug("addDelegate: now \(self.delegates.count) delegate(s)")
    }

    @MainActor
    func removeDelegate(_ delegate: any ARSessionDelegate) {
        lock.lock()
        defer { lock.unlock() }

        delegates.removeAll { $0.value === nil || $0.value === delegate as AnyObject }
        logger.debug("removeDelegate: now \(self.delegates.count) delegate(s)")
    }

    @MainActor
    func attach(to session: ARSession) {
        session.delegate = self
        logger.info("Multiplexer attached to ARSession")
    }

    // MARK: - Snapshot

    private func snapshot() -> [any ARSessionDelegate] {
        lock.lock()
        defer { lock.unlock() }

        delegates.removeAll { $0.value === nil }
        return delegates.compactMap { $0.value }
    }

    // MARK: - ARSessionDelegate Forwarding

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        for d in snapshot() { d.session?(session, didUpdate: frame) }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for d in snapshot() { d.session?(session, didAdd: anchors) }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for d in snapshot() { d.session?(session, didUpdate: anchors) }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for d in snapshot() { d.session?(session, didRemove: anchors) }
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        for d in snapshot() { d.session?(session, cameraDidChangeTrackingState: camera) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        for d in snapshot() { d.session?(session, didFailWithError: error) }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        for d in snapshot() { d.sessionWasInterrupted?(session) }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        for d in snapshot() { d.sessionInterruptionEnded?(session) }
    }
}
