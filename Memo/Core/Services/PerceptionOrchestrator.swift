import ARKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "PerceptionOrchestrator")

@Observable @MainActor
final class PerceptionOrchestrator {

    // MARK: - Public (injected at init)

    let frameProvider: FrameProvider
    let stateStore: PerceptionStateStore

    // MARK: - Consumer Registry

    private struct WeakConsumer {
        weak var value: (any FrameConsumer)?
    }

    private var consumers: [String: WeakConsumer] = [:]
    private var lastDispatchTime: [String: TimeInterval] = [:]
    /// Per-consumer in-flight guard: skip dispatch while still processing previous frame
    private var isProcessing: Set<String> = []
    /// Frame counter for periodic stats logging
    private var frameCount: Int = 0

    // MARK: - Dispatch

    private var dispatchTask: Task<Void, Never>?
    var isRunning = false

    // MARK: - Session Disruption

    private var sessionObserver: SessionObserver?
    private var disruptionTimestamp: Date?
    private var recoveryTimeoutTask: Task<Void, Never>?
    private let recoveryTimeout: TimeInterval = 15

    // MARK: - Init

    init(frameProvider: FrameProvider, stateStore: PerceptionStateStore) {
        self.frameProvider = frameProvider
        self.stateStore = stateStore
    }

    // MARK: - Consumer Registration

    func register(_ consumer: any FrameConsumer) {
        consumers[consumer.consumerID] = WeakConsumer(value: consumer)
        lastDispatchTime[consumer.consumerID] = 0
        logger.info("Registered consumer: \(consumer.consumerID) @ \(consumer.desiredFrameRate)fps")
    }

    func unregister(_ consumer: any FrameConsumer) {
        consumers.removeValue(forKey: consumer.consumerID)
        lastDispatchTime.removeValue(forKey: consumer.consumerID)
        isProcessing.remove(consumer.consumerID)
        logger.info("Unregistered consumer: \(consumer.consumerID)")
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        dispatchTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.frameProvider.frameSignal {
                guard !Task.isCancelled else { break }
                guard let frame = self.frameProvider.latestFrame else { continue }
                await self.dispatchFrame(frame)
            }
            await MainActor.run { [weak self] in self?.isRunning = false }
        }
        logger.info("PerceptionOrchestrator started")
    }

    func stop() {
        dispatchTask?.cancel()
        dispatchTask = nil
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        isRunning = false
        consumers.removeAll()
        lastDispatchTime.removeAll()
        isProcessing.removeAll()
        disruptionTimestamp = nil
        logger.info("PerceptionOrchestrator stopped")
    }

    // MARK: - Frame Dispatch (concurrent + per-consumer in-flight guard)

    private func dispatchFrame(_ frame: FrameInput) async {
        // Prune dead weak refs
        let beforeCount = consumers.count
        consumers = consumers.filter { $0.value.value != nil }
        let prunedCount = beforeCount - consumers.count

        frameCount += 1

        // Log stats every 60 frames (~4s at 15fps)
        if frameCount % 60 == 0 {
            let active = consumers.filter { $0.value.value?.isPaused == false }.map(\.key)
            let paused = consumers.filter { $0.value.value?.isPaused == true }.map(\.key)
            let processing = Array(isProcessing)
            logger.info("[Dispatch] frame#\(self.frameCount) | consumers: active=\(active) paused=\(paused) inflight=\(processing) pruned=\(prunedCount)")
        }

        var dispatched: [String] = []

        await withTaskGroup(of: Void.self) { group in
            for (id, weak) in consumers {
                guard let consumer = weak.value, !consumer.isPaused else { continue }
                guard !isProcessing.contains(id) else { continue }

                let interval = 1.0 / consumer.desiredFrameRate
                let last = lastDispatchTime[id] ?? 0
                guard frame.timestamp - last >= interval else { continue }

                lastDispatchTime[id] = frame.timestamp
                isProcessing.insert(id)
                dispatched.append(id)

                group.addTask { [weak self] in
                    await consumer.processFrame(frame)
                    await MainActor.run { self?.isProcessing.remove(id) }
                }
            }
        }

        // Log each actual dispatch (every 30 frames to avoid spam)
        if frameCount % 30 == 0 && !dispatched.isEmpty {
            logger.debug("[Dispatch] Dispatched to: \(dispatched)")
        }
    }

    // MARK: - Session Disruption

    func notifySessionWillReset(reason: String) {
        for (_, weak) in consumers { weak.value?.pause() }
        stateStore.handle(.sessionDisrupted(reason: reason))
        disruptionTimestamp = Date()
        startRecoveryTimeout()
        logger.info("Session disrupted: \(reason)")
    }

    func notifySessionDidRecover() {
        guard stateStore.isSessionDisrupted else { return }
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = nil
        disruptionTimestamp = nil
        for (_, weak) in consumers { weak.value?.resume() }
        stateStore.handle(.sessionRecovered)
        logger.info("Session recovered")
    }

    private func startRecoveryTimeout() {
        recoveryTimeoutTask?.cancel()
        recoveryTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.recoveryTimeout ?? 15))
            guard !Task.isCancelled else { return }
            guard let self, self.stateStore.isSessionDisrupted else { return }
            logger.warning("Recovery timeout — force recovering after \(self.recoveryTimeout)s")
            self.notifySessionDidRecover()
        }
    }

    // MARK: - Multiplexer Integration

    func attach(to multiplexer: ARSessionDelegateMultiplexer) {
        frameProvider.attach(to: multiplexer)
        let observer = SessionObserver(orchestrator: self)
        multiplexer.addDelegate(observer)
        sessionObserver = observer
    }

    func detach(from multiplexer: ARSessionDelegateMultiplexer) {
        frameProvider.detach(from: multiplexer)
        if let observer = sessionObserver {
            multiplexer.removeDelegate(observer)
            sessionObserver = nil
        }
    }
}

// MARK: - Session Observer (ARSessionDelegate for auto-recovery)

private final class SessionObserver: NSObject, ARSessionDelegate, @unchecked Sendable {
    weak var orchestrator: PerceptionOrchestrator?

    init(orchestrator: PerceptionOrchestrator) {
        self.orchestrator = orchestrator
        super.init()
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor [weak self] in
            guard let orch = self?.orchestrator else { return }
            logger.info("[SessionObserver] trackingState → \(String(describing: camera.trackingState)), isDisrupted=\(orch.stateStore.isSessionDisrupted)")
            if case .normal = camera.trackingState, orch.stateStore.isSessionDisrupted {
                logger.info("[SessionObserver] Tracking normal + disrupted → triggering recovery")
                orch.notifySessionDidRecover()
            }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            logger.info("[SessionObserver] sessionWasInterrupted")
            self?.orchestrator?.notifySessionWillReset(reason: "System interruption")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            logger.info("[SessionObserver] sessionInterruptionEnded")
            self?.orchestrator?.notifySessionDidRecover()
        }
    }
}
