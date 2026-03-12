import ARKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "FrameProvider")

// MARK: - Frame Input

/// Lightweight snapshot of an AR frame for downstream consumers.
struct FrameInput: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let timestamp: TimeInterval
    let cameraTransform: simd_float4x4?
    let worldMappingStatus: ARFrame.WorldMappingStatus
    /// Image orientation for Vision/CoreImage processing.
    /// Rear camera = .right, front camera = .leftMirrored
    let imageOrientation: CGImagePropertyOrientation
}

// MARK: - Frame Provider

/// Receives AR frames via the multiplexer, throttles to ~15fps,
/// and exposes the latest frame for synchronous reading plus an async signal stream.
final class FrameProvider: NSObject, ARSessionDelegate, @unchecked Sendable {

    // MARK: - Public State

    /// Latest frame, protected by lock. Consumers read synchronously.
    var latestFrame: FrameInput? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _latestFrame
    }

    /// Signal stream: yields `Void` whenever a new throttled frame arrives.
    /// Use `.bufferingNewest(1)` so slow consumers skip stale signals.
    let frameSignal: AsyncStream<Void>

    // MARK: - Private

    private var _latestFrame: FrameInput?
    private let frameLock = NSLock()

    /// Set to true when using front camera (ARFaceTrackingConfiguration).
    /// Affects imageOrientation in emitted FrameInput.
    var usingFrontCamera: Bool = false

    private let throttleInterval: TimeInterval = 1.0 / 15.0  // ~15fps
    private var lastEmitTime: TimeInterval = 0
    private var emitCount: Int = 0
    private var rawFrameCount: Int = 0

    private let signalContinuation: AsyncStream<Void>.Continuation

    // MARK: - Init

    override init() {
        var cont: AsyncStream<Void>.Continuation!
        frameSignal = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        signalContinuation = cont
        super.init()
    }

    deinit {
        signalContinuation.finish()
    }

    // MARK: - Multiplexer Integration

    @MainActor
    func attach(to multiplexer: ARSessionDelegateMultiplexer) {
        multiplexer.addDelegate(self)
        logger.info("FrameProvider attached to multiplexer")
    }

    @MainActor
    func detach(from multiplexer: ARSessionDelegateMultiplexer) {
        multiplexer.removeDelegate(self)
        logger.info("FrameProvider detached from multiplexer")
    }

    // MARK: - ARSessionDelegate

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        rawFrameCount += 1
        let now = frame.timestamp
        guard now - lastEmitTime >= throttleInterval else { return }
        lastEmitTime = now
        emitCount += 1

        let orientation: CGImagePropertyOrientation = usingFrontCamera ? .leftMirrored : .right
        let input = FrameInput(
            pixelBuffer: frame.capturedImage,
            timestamp: now,
            cameraTransform: frame.camera.transform,
            worldMappingStatus: frame.worldMappingStatus,
            imageOrientation: orientation
        )

        frameLock.lock()
        _latestFrame = input
        frameLock.unlock()

        signalContinuation.yield()

        // Log every 150 emitted frames (~10s at 15fps)
        if emitCount % 150 == 0 {
            let bufW = CVPixelBufferGetWidth(frame.capturedImage)
            let bufH = CVPixelBufferGetHeight(frame.capturedImage)
            logger.info("[FrameProvider] emitted=\(self.emitCount) raw=\(self.rawFrameCount) resolution=\(bufW)x\(bufH) tracking=\(String(describing: frame.camera.trackingState))")
        }
    }
}

// MARK: - Frame Consumer Protocol

/// Frame consumer protocol. All services that process AR frames conform to this.
/// Orchestrator (M2) will manage consumer registration, frame rate allocation, and lifecycle.
@MainActor
protocol FrameConsumer: AnyObject {
    /// Unique identifier for logging and scheduling.
    var consumerID: String { get }

    /// Desired frame rate (fps). Orchestrator will throttle dispatch accordingly.
    var desiredFrameRate: Double { get }

    /// Whether the consumer is paused. Orchestrator skips paused consumers.
    var isPaused: Bool { get }

    /// Process a single frame. Called by Orchestrator at the appropriate throttle interval.
    func processFrame(_ frame: FrameInput) async

    /// Pause consumption (e.g. during AR session reset).
    func pause()

    /// Resume consumption.
    func resume()
}
