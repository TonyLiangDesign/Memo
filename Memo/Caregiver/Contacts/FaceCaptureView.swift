import SwiftUI
import AVFoundation

/// Camera view for capturing face samples with real-time detection overlay.
struct FaceCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: FaceCaptureViewModel

    init(contactID: String, faceDataStore: FaceDataStore) {
        _viewModel = State(initialValue: FaceCaptureViewModel(contactID: contactID, faceDataStore: faceDataStore))
    }

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: viewModel.captureSession)
                .ignoresSafeArea()

            // Face detection overlay
            GeometryReader { geo in
                if let rect = viewModel.detectedFaceRect {
                    // Convert Vision normalized coords (origin bottom-left) to SwiftUI (origin top-left)
                    let x = rect.origin.x * geo.size.width
                    let y = (1 - rect.origin.y - rect.height) * geo.size.height
                    let w = rect.width * geo.size.width
                    let h = rect.height * geo.size.height

                    RoundedRectangle(cornerRadius: 8)
                        .stroke(viewModel.faceQualityOK ? .green : .orange, lineWidth: 3)
                        .frame(width: w, height: h)
                        .position(x: x + w / 2, y: y + h / 2)
                }
            }

            // Controls overlay
            VStack {
                // Top bar
                HStack {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.5), in: Capsule())

                    Spacer()

                    Button {
                        viewModel.switchCamera()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 56)

                Spacer()

                // Quality message
                Text(viewModel.qualityMessage)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(viewModel.faceQualityOK ? Color.green.opacity(0.7) : Color.orange.opacity(0.7), in: Capsule())

                // Progress dots
                HStack(spacing: 6) {
                    Text("已采集：\(viewModel.capturedCount)/\(viewModel.minSamples)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    ForEach(0..<viewModel.minSamples, id: \.self) { i in
                        Circle()
                            .fill(i < viewModel.capturedCount ? Color.green : Color.white.opacity(0.4))
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.vertical, 8)

                HStack(spacing: 32) {
                    // Capture button
                    Button {
                        viewModel.captureCurrentFace()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 72, height: 72)
                            Circle()
                                .fill(viewModel.canCapture ? .white : .gray.opacity(0.5))
                                .frame(width: 60, height: 60)
                        }
                    }
                    .disabled(!viewModel.canCapture)

                    // Done button (visible when min samples reached)
                    if viewModel.isComplete {
                        Button("完成") {
                            dismiss()
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.green, in: Capsule())
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear { viewModel.startSession() }
        .onDisappear { viewModel.stopSession() }
        .navigationBarHidden(true)
    }
}

// MARK: - Camera Preview UIViewRepresentable

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
