import CoreML
import CoreGraphics
import CoreImage
import Vision
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "FaceEmbedding")

/// CoreML-based face embedding service using ArcFace (w600k_r50).
/// Generates 512-dim L2-normalized embeddings from aligned face images.
final class FaceEmbeddingService: @unchecked Sendable {

    private let model: MLModel?

    /// Standard ArcFace 112×112 alignment template coordinates.
    private static let templateLandmarks: [(x: Double, y: Double)] = [
        (38.2946, 51.6963),  // left eye
        (73.5318, 51.5014),  // right eye
        (56.0252, 71.7366),  // nose tip
        (41.5493, 92.3655),  // left mouth corner
        (70.7299, 92.2041),  // right mouth corner
    ]

    static let embeddingDimension = 512

    /// Model file name (without extension) expected in the app bundle.
    private static let modelName = "ArcFaceW600K"

    init() {
        // Load .mlmodelc from bundle (compiled from .mlpackage by Xcode)
        if let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            do {
                self.model = try MLModel(contentsOf: url, configuration: config)
                logger.info("ArcFace model loaded successfully")
            } catch {
                self.model = nil
                logger.error("ArcFace model failed to load: \(error.localizedDescription)")
            }
        } else {
            self.model = nil
            logger.error("ArcFace model not found in bundle — face recognition degraded to detection-only")
        }
    }

    var isAvailable: Bool { model != nil }

    // MARK: - Embedding Generation

    /// Generate a 512-dim embedding from a full image containing a face.
    /// Performs face detection, landmark alignment, and model inference.
    func generateEmbedding(from pixelBuffer: CVPixelBuffer) async throws -> (embedding: [Float], boundingBox: CGRect)? {
        guard let model else { throw FaceEmbeddingError.modelNotAvailable }

        // 1. Detect face + landmarks
        guard let detection = try await detectFaceWithLandmarks(pixelBuffer: pixelBuffer) else {
            return nil
        }

        // 2. Align to 112×112
        let aligned = try alignFace(
            pixelBuffer: pixelBuffer,
            landmarks: detection.landmarks,
            boundingBox: detection.boundingBox
        )

        // 3. Preprocess and infer
        let embedding = try infer(alignedFace: aligned, model: model)

        return (embedding: embedding, boundingBox: detection.boundingBox)
    }

    /// Generate embeddings for ALL detected faces in a frame.
    /// Returns one (embedding, boundingBox) tuple per face found.
    func generateEmbeddings(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) async throws -> [(embedding: [Float], boundingBox: CGRect)] {
        guard let model else { throw FaceEmbeddingError.modelNotAvailable }

        let detections = try await detectFaces(in: pixelBuffer, orientation: orientation)
        guard !detections.isEmpty else { return [] }

        var results: [(embedding: [Float], boundingBox: CGRect)] = []
        for detection in detections {
            let aligned = try alignFace(
                pixelBuffer: pixelBuffer,
                landmarks: detection.landmarks,
                boundingBox: detection.boundingBox,
                orientation: orientation
            )
            let embedding = try infer(alignedFace: aligned, model: model)
            results.append((embedding: embedding, boundingBox: detection.boundingBox))
        }

        return results
    }

    /// Generate embedding from a pre-cropped face CGImage (used during registration).
    func generateEmbedding(faceImage: CGImage) async throws -> [Float] {
        guard let model else { throw FaceEmbeddingError.modelNotAvailable }

        // Detect landmarks within the cropped face image
        let ciImage = CIImage(cgImage: faceImage)
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        try handler.perform([request])

        guard let observation = request.results?.first,
              let landmarks = observation.landmarks else {
            // If no landmarks in crop, just resize to 112×112 without alignment
            let resized = resizeImage(faceImage, to: CGSize(width: 112, height: 112))
            return try infer(alignedFace: resized, model: model)
        }

        // Extract 5-point landmarks in image coordinates
        let faceRect = observation.boundingBox
        let w = CGFloat(faceImage.width)
        let h = CGFloat(faceImage.height)
        let srcPoints = extractFivePoints(landmarks: landmarks, faceBBox: faceRect, imageWidth: w, imageHeight: h)

        // Compute affine and align
        let aligned = applyAffineAlignment(image: faceImage, srcPoints: srcPoints)
        return try infer(alignedFace: aligned, model: model)
    }

    /// Generate average reference embedding from multiple face samples.
    func generateReferenceEmbedding(samples: [CGImage], progress: ((Float) -> Void)? = nil) async throws -> [Float] {
        guard !samples.isEmpty else { throw FaceEmbeddingError.noSamples }

        var embeddings: [[Float]] = []
        for (i, sample) in samples.enumerated() {
            let emb = try await generateEmbedding(faceImage: sample)
            embeddings.append(emb)
            progress?(Float(i + 1) / Float(samples.count))
        }

        // Average all embeddings
        let dim = Self.embeddingDimension
        var avg = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            vDSP_vadd(avg, 1, emb, 1, &avg, 1, vDSP_Length(dim))
        }
        var divisor = Float(embeddings.count)
        vDSP_vsdiv(avg, 1, &divisor, &avg, 1, vDSP_Length(dim))

        // L2 normalize
        l2Normalize(&avg)

        return avg
    }

    // MARK: - Similarity

    /// Cosine similarity between two L2-normalized embeddings (= dot product).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    // MARK: - Face Detection (Public)

    struct FaceDetection {
        let boundingBox: CGRect          // Normalized coordinates (Vision format)
        let landmarks: VNFaceLandmarks2D
        let faceArea: Float              // Fraction of image area
    }

    /// Detect faces with landmarks in a pixel buffer. Returns all faces found.
    func detectFaces(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right) async throws -> [FaceDetection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let request = VNDetectFaceLandmarksRequest()
        try handler.perform([request])

        guard let results = request.results else { return [] }

        return results.compactMap { obs in
            guard let landmarks = obs.landmarks else { return nil }
            let bbox = obs.boundingBox
            let area = Float(bbox.width * bbox.height)
            return FaceDetection(boundingBox: bbox, landmarks: landmarks, faceArea: area)
        }
    }

    // MARK: - Private: Detection

    private func detectFaceWithLandmarks(pixelBuffer: CVPixelBuffer) async throws -> FaceDetection? {
        let detections = try await detectFaces(in: pixelBuffer)
        // Return the largest face
        return detections.max(by: { $0.faceArea < $1.faceArea })
    }

    // MARK: - Private: Alignment

    private func extractFivePoints(
        landmarks: VNFaceLandmarks2D,
        faceBBox: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [(x: Double, y: Double)] {
        func convert(_ points: [CGPoint]?) -> CGPoint? {
            guard let pts = points, !pts.isEmpty else { return nil }
            let avg = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            // Points are relative to faceBBox in normalized coords
            let nx = faceBBox.origin.x + (avg.x / CGFloat(pts.count)) * faceBBox.width
            let ny = faceBBox.origin.y + (avg.y / CGFloat(pts.count)) * faceBBox.height
            // Convert from Vision coords (origin bottom-left) to image coords (origin top-left)
            return CGPoint(x: nx * imageWidth, y: (1 - ny) * imageHeight)
        }

        let leftEye = convert(landmarks.leftEye?.normalizedPoints) ?? CGPoint(x: 0.3 * imageWidth, y: 0.35 * imageHeight)
        let rightEye = convert(landmarks.rightEye?.normalizedPoints) ?? CGPoint(x: 0.7 * imageWidth, y: 0.35 * imageHeight)
        let nose = convert(landmarks.nose?.normalizedPoints) ?? CGPoint(x: 0.5 * imageWidth, y: 0.55 * imageHeight)

        let outerLips = landmarks.outerLips?.normalizedPoints
        let leftMouth: CGPoint
        let rightMouth: CGPoint
        if let lips = outerLips, lips.count >= 2 {
            let sorted = lips.sorted { $0.x < $1.x }
            let leftRaw = sorted.first!
            let rightRaw = sorted.last!
            let lx = faceBBox.origin.x + leftRaw.x * faceBBox.width
            let ly = faceBBox.origin.y + leftRaw.y * faceBBox.height
            let rx = faceBBox.origin.x + rightRaw.x * faceBBox.width
            let ry = faceBBox.origin.y + rightRaw.y * faceBBox.height
            leftMouth = CGPoint(x: lx * imageWidth, y: (1 - ly) * imageHeight)
            rightMouth = CGPoint(x: rx * imageWidth, y: (1 - ry) * imageHeight)
        } else {
            leftMouth = CGPoint(x: 0.35 * imageWidth, y: 0.75 * imageHeight)
            rightMouth = CGPoint(x: 0.65 * imageWidth, y: 0.75 * imageHeight)
        }

        return [
            (x: Double(leftEye.x), y: Double(leftEye.y)),
            (x: Double(rightEye.x), y: Double(rightEye.y)),
            (x: Double(nose.x), y: Double(nose.y)),
            (x: Double(leftMouth.x), y: Double(leftMouth.y)),
            (x: Double(rightMouth.x), y: Double(rightMouth.y)),
        ]
    }

    private func alignFace(
        pixelBuffer: CVPixelBuffer,
        landmarks: VNFaceLandmarks2D,
        boundingBox: CGRect,
        orientation: CGImagePropertyOrientation = .right
    ) throws -> CGImage {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // Compute oriented image dimensions based on orientation
        let imgWidth: CGFloat
        let imgHeight: CGFloat
        switch orientation {
        case .up, .down, .upMirrored, .downMirrored:
            imgWidth = width
            imgHeight = height
        default: // .left, .right, .leftMirrored, .rightMirrored
            imgWidth = height
            imgHeight = width
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight)) else {
            throw FaceEmbeddingError.imageConversionFailed
        }

        let srcPoints = extractFivePoints(
            landmarks: landmarks,
            faceBBox: boundingBox,
            imageWidth: imgWidth,
            imageHeight: imgHeight
        )

        return applyAffineAlignment(image: cgImage, srcPoints: srcPoints)
    }

    /// Apply affine transform to align source landmarks to ArcFace template, producing 112×112 image.
    private func applyAffineAlignment(image: CGImage, srcPoints: [(x: Double, y: Double)]) -> CGImage {
        let dst = Self.templateLandmarks
        let transform = estimateAffineTransform(src: srcPoints, dst: dst)

        let size = 112
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return resizeImage(image, to: CGSize(width: 112, height: 112))
        }

        ctx.concatenate(transform)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return ctx.makeImage() ?? resizeImage(image, to: CGSize(width: 112, height: 112))
    }

    /// Estimate affine transform using least-squares (src → dst).
    private func estimateAffineTransform(
        src: [(x: Double, y: Double)],
        dst: [(x: Double, y: Double)]
    ) -> CGAffineTransform {
        // Solve for [a, b, tx; c, d, ty] using least squares
        // dst_x = a * src_x + b * src_y + tx
        // dst_y = c * src_x + d * src_y + ty
        let n = min(src.count, dst.count)
        guard n >= 3 else { return .identity }

        // Build matrices for least squares: A * params = B
        // For x: [src_x, src_y, 1] * [a, b, tx]^T = dst_x
        // For y: [src_x, src_y, 1] * [c, d, ty]^T = dst_y
        var A = [Double](repeating: 0, count: n * 3)
        var Bx = [Double](repeating: 0, count: n)
        var By = [Double](repeating: 0, count: n)

        for i in 0..<n {
            A[i * 3 + 0] = src[i].x
            A[i * 3 + 1] = src[i].y
            A[i * 3 + 2] = 1.0
            Bx[i] = dst[i].x
            By[i] = dst[i].y
        }

        // Solve using normal equations: (A^T A) x = A^T b
        let paramsX = solveLinearLeastSquares(A: A, b: Bx, m: n, n: 3)
        let paramsY = solveLinearLeastSquares(A: A, b: By, m: n, n: 3)

        guard let px = paramsX, let py = paramsY else { return .identity }

        // CGAffineTransform: [a, c, b, d, tx, ty]
        return CGAffineTransform(a: px[0], b: py[0], c: px[1], d: py[1], tx: px[2], ty: py[2])
    }

    /// Solve A*x = b using normal equations (A^T A x = A^T b).
    private func solveLinearLeastSquares(A: [Double], b: [Double], m: Int, n: Int) -> [Double]? {
        // A^T A (n x n)
        var ATA = [Double](repeating: 0, count: n * n)
        // A^T b (n x 1)
        var ATb = [Double](repeating: 0, count: n)

        for i in 0..<n {
            for j in 0..<n {
                var sum = 0.0
                for k in 0..<m {
                    sum += A[k * n + i] * A[k * n + j]
                }
                ATA[i * n + j] = sum
            }
            var sum = 0.0
            for k in 0..<m {
                sum += A[k * n + i] * b[k]
            }
            ATb[i] = sum
        }

        // Solve 3x3 system using Cramer's rule
        guard n == 3 else { return nil }
        let det = ATA[0] * (ATA[4] * ATA[8] - ATA[5] * ATA[7])
                - ATA[1] * (ATA[3] * ATA[8] - ATA[5] * ATA[6])
                + ATA[2] * (ATA[3] * ATA[7] - ATA[4] * ATA[6])
        guard abs(det) > 1e-10 else { return nil }

        let invDet = 1.0 / det
        // Inverse of 3x3 matrix
        var inv = [Double](repeating: 0, count: 9)
        inv[0] = (ATA[4] * ATA[8] - ATA[5] * ATA[7]) * invDet
        inv[1] = (ATA[2] * ATA[7] - ATA[1] * ATA[8]) * invDet
        inv[2] = (ATA[1] * ATA[5] - ATA[2] * ATA[4]) * invDet
        inv[3] = (ATA[5] * ATA[6] - ATA[3] * ATA[8]) * invDet
        inv[4] = (ATA[0] * ATA[8] - ATA[2] * ATA[6]) * invDet
        inv[5] = (ATA[2] * ATA[3] - ATA[0] * ATA[5]) * invDet
        inv[6] = (ATA[3] * ATA[7] - ATA[4] * ATA[6]) * invDet
        inv[7] = (ATA[1] * ATA[6] - ATA[0] * ATA[7]) * invDet
        inv[8] = (ATA[0] * ATA[4] - ATA[1] * ATA[3]) * invDet

        var result = [Double](repeating: 0, count: 3)
        for i in 0..<3 {
            result[i] = inv[i * 3 + 0] * ATb[0] + inv[i * 3 + 1] * ATb[1] + inv[i * 3 + 2] * ATb[2]
        }
        return result
    }

    // MARK: - Private: Inference

    private func infer(alignedFace: CGImage, model: MLModel) throws -> [Float] {
        // Create MLMultiArray [1, 3, 112, 112] NCHW
        let shape: [NSNumber] = [1, 3, 112, 112]
        let input = try MLMultiArray(shape: shape, dataType: .float32)

        // Get pixel data from a guaranteed-RGBA bitmap context
        let width = 112
        let height = 112
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FaceEmbeddingError.imageConversionFailed
        }
        ctx.interpolationQuality = .high
        ctx.draw(alignedFace, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = ctx.data else {
            throw FaceEmbeddingError.imageConversionFailed
        }
        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = width * 4

        // Fill NCHW with BGR order, normalized to [-1, 1]
        // ArcFace trained with OpenCV BGR order
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let r = Float(ptr[offset])     // R
                let g = Float(ptr[offset + 1]) // G
                let b = Float(ptr[offset + 2]) // B

                // BGR order: channel 0=B, 1=G, 2=R
                let idx0 = y * width + x                       // B channel
                let idx1 = width * height + y * width + x      // G channel
                let idx2 = 2 * width * height + y * width + x  // R channel

                input[idx0] = NSNumber(value: (b - 127.5) / 127.5)
                input[idx1] = NSNumber(value: (g - 127.5) / 127.5)
                input[idx2] = NSNumber(value: (r - 127.5) / 127.5)
            }
        }

        // Determine the input feature name from model description
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)])

        // Run inference
        let prediction = try model.prediction(from: provider)

        // Extract output embedding — try common output names
        let outputNames = ["output", "683"] + Array(model.modelDescription.outputDescriptionsByName.keys)
        var outputArray: MLMultiArray?
        for name in outputNames {
            if let val = prediction.featureValue(for: name)?.multiArrayValue {
                outputArray = val
                break
            }
        }

        guard let output = outputArray else {
            throw FaceEmbeddingError.inferenceOutputMissing
        }

        var embedding = [Float](repeating: 0, count: Self.embeddingDimension)
        let count = min(output.count, Self.embeddingDimension)
        for i in 0..<count {
            embedding[i] = output[i].floatValue
        }

        // L2 normalize
        l2Normalize(&embedding)

        return embedding
    }

    // MARK: - Private: Image Utilities

    private func resizeImage(_ image: CGImage, to size: CGSize) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage() ?? image
    }

    // MARK: - Private: Math

    private func l2Normalize(_ v: inout [Float]) {
        var sumSq: Float = 0
        vDSP_dotpr(v, 1, v, 1, &sumSq, vDSP_Length(v.count))
        let norm = sqrt(sumSq)
        guard norm > 1e-10 else { return }
        var d = norm
        vDSP_vsdiv(v, 1, &d, &v, 1, vDSP_Length(v.count))
    }
}

// MARK: - Errors

enum FaceEmbeddingError: LocalizedError {
    case modelNotAvailable
    case imageConversionFailed
    case inferenceOutputMissing
    case noSamples

    var errorDescription: String? {
        switch self {
        case .modelNotAvailable: return String(localized: "人脸识别模型未加载")
        case .imageConversionFailed: return String(localized: "图片转换失败")
        case .inferenceOutputMissing: return String(localized: "模型推理输出缺失")
        case .noSamples: return String(localized: "无样本图片")
        }
    }
}
