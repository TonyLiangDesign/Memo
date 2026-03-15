@preconcurrency import AVFoundation
import Vision
import CoreGraphics
import CoreImage
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "FaceCapture")

/// Thread-safe frame buffer accessed from both processing queue and main actor.
private final class FrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _sampleBuffer: CMSampleBuffer?
    private var _faceObservation: VNFaceObservation?

    func store(sampleBuffer: CMSampleBuffer, observation: VNFaceObservation?) {
        lock.lock()
        _sampleBuffer = sampleBuffer
        _faceObservation = observation
        lock.unlock()
    }

    func load() -> (sampleBuffer: CMSampleBuffer, observation: VNFaceObservation?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let sb = _sampleBuffer else { return nil }
        return (sb, _faceObservation)
    }
}

/// Manages AVCaptureSession + Vision face detection for face sample collection.
@Observable @MainActor
final class FaceCaptureViewModel: NSObject {

    // MARK: - Public State

    var detectedFaceRect: CGRect?
    var faceQualityOK: Bool = false
    var capturedCount: Int = 0
    var qualityMessage: String = ""
    var isSessionRunning: Bool = false

    var canCapture: Bool { faceQualityOK && capturedCount < maxSamples }
    var isComplete: Bool { capturedCount >= minSamples }
    var isFull: Bool { capturedCount >= maxSamples }

    let minSamples = 5
    let maxSamples = 10

    // MARK: - Dependencies

    private let contactID: String
    private let faceDataStore: FaceDataStore

    // MARK: - Camera

    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.MrPolpo.Memo.faceCapture", qos: .userInteractive)
    private var usingFrontCamera = false
    nonisolated(unsafe) private var _cachedOrientation: CGImagePropertyOrientation = .right

    // MARK: - Frame State

    private let frameBuffer = FrameBuffer()

    // MARK: - Delegate Adapter

    private var delegateAdapter: CaptureDelegate?

    // MARK: - Init

    init(contactID: String, faceDataStore: FaceDataStore) {
        self.contactID = contactID
        self.faceDataStore = faceDataStore
        super.init()
        self.capturedCount = faceDataStore.sampleCount(for: contactID)
        self.delegateAdapter = CaptureDelegate { [weak self] sampleBuffer in
            self?.handleNewFrame(sampleBuffer)
        }
    }

    // MARK: - Session Lifecycle

    func startSession() {
        guard !isSessionRunning else { return }
        setupSession(front: true)  // Use front camera by default to match LiveMode
        let session = captureSession
        processingQueue.async {
            session.startRunning()
        }
        isSessionRunning = true
    }

    func stopSession() {
        guard isSessionRunning else { return }
        let session = captureSession
        processingQueue.async {
            session.stopRunning()
        }
        isSessionRunning = false
    }

    func switchCamera() {
        usingFrontCamera.toggle()
        setupSession(front: usingFrontCamera)
        let session = captureSession
        processingQueue.async {
            session.startRunning()
        }
    }

    // MARK: - Capture

    func captureCurrentFace() {
        guard canCapture else { return }

        guard let frame = frameBuffer.load(),
              let faceObs = frame.observation,
              let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) else { return }

        let contactID = self.contactID
        let store = self.faceDataStore
        let orientation: CGImagePropertyOrientation = usingFrontCamera ? .leftMirrored : .right

        processingQueue.async {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            let fullWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
            let fullHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

            // Expand bounding box by 30% for better alignment
            let bbox = faceObs.boundingBox
            let expandFactor: CGFloat = 0.3
            let expandedRect = CGRect(
                x: max(0, bbox.origin.x - bbox.width * expandFactor / 2),
                y: max(0, bbox.origin.y - bbox.height * expandFactor / 2),
                width: min(1, bbox.width * (1 + expandFactor)),
                height: min(1, bbox.height * (1 + expandFactor))
            )

            let cropRect = CGRect(
                x: expandedRect.origin.x * fullWidth,
                y: expandedRect.origin.y * fullHeight,
                width: expandedRect.width * fullWidth,
                height: expandedRect.height * fullHeight
            )

            let cropped = ciImage.cropped(to: cropRect)
            guard let cgImage = context.createCGImage(cropped, from: cropped.extent) else {
                logger.warning("Failed to create CGImage from cropped face")
                return
            }

            let index = store.sampleCount(for: contactID)
            do {
                _ = try store.saveSample(cgImage, contactID: contactID, index: index, orientation: orientation)
                let newCount = store.sampleCount(for: contactID)
                Task { @MainActor [weak self] in
                    self?.capturedCount = newCount
                    logger.info("Captured face sample \(newCount) for \(contactID)")
                }
            } catch {
                logger.error("Failed to save face sample: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private: Frame Handling (called from processingQueue via delegate)

    nonisolated private func handleNewFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let orientation = _cachedOrientation
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let request = VNDetectFaceLandmarksRequest()

        do {
            try handler.perform([request])
        } catch {
            return
        }

        let faces = request.results ?? []
        let observation = faces.first

        frameBuffer.store(sampleBuffer: sampleBuffer, observation: observation)

        let quality = Self.assessQuality(faces: faces)

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.detectedFaceRect = observation?.boundingBox
            self.faceQualityOK = quality.ok
            self.qualityMessage = quality.message
        }
    }

    // MARK: - Private: Session Setup

    private func setupSession(front: Bool) {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        captureSession.sessionPreset = .high

        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            logger.error("Failed to get \(front ? "front" : "back") camera")
            return
        }

        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        if !captureSession.outputs.contains(videoOutput) {
            videoOutput.setSampleBufferDelegate(delegateAdapter, queue: processingQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
        }

        // Rotate pixel buffer to portrait so Vision coords match preview
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = front
        }

        _cachedOrientation = front ? .leftMirrored : .right
    }

    // MARK: - Private: Quality Assessment

    private struct QualityResult: Sendable {
        let ok: Bool
        let message: String
    }

    nonisolated private static func assessQuality(faces: [VNFaceObservation]) -> QualityResult {
        guard !faces.isEmpty else {
            return QualityResult(ok: false, message: String(localized: "未检测到人脸"))
        }
        guard faces.count == 1 else {
            return QualityResult(ok: false, message: String(localized: "检测到多张人脸，请确保画面中只有一人"))
        }
        let face = faces[0]
        let bbox = face.boundingBox

        let area = bbox.width * bbox.height
        guard area > 0.08 else {
            return QualityResult(ok: false, message: String(localized: "人脸太小，请靠近一些"))
        }

        let centerX = bbox.midX
        let centerY = bbox.midY
        guard centerX > 0.15 && centerX < 0.85 && centerY > 0.15 && centerY < 0.85 else {
            return QualityResult(ok: false, message: String(localized: "请将人脸移至画面中央"))
        }

        guard face.landmarks != nil else {
            return QualityResult(ok: false, message: String(localized: "无法检测到面部特征点，请正对镜头"))
        }

        return QualityResult(ok: true, message: String(localized: "质量良好，可以拍摄"))
    }
}

// MARK: - Non-isolated AVCaptureVideoDataOutputSampleBufferDelegate

private final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}
