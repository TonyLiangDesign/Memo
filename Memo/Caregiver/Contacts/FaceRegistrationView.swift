import SwiftUI
import SwiftData

/// Registration flow view: sample grid, generate embedding, manage face data.
struct FaceRegistrationView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var contact: CareContact

    @State private var phase: RegistrationPhase = .collecting
    @State private var showCamera = false
    @State private var showDeleteConfirm = false
    @State private var sampleImages: [CGImage] = []

    private let faceDataStore = FaceDataStore()
    private let embeddingService = FaceEmbeddingService()

    enum RegistrationPhase: Equatable {
        case collecting
        case readyToGenerate
        case generating(Float)
        case completed
        case error(String)

        static func == (lhs: RegistrationPhase, rhs: RegistrationPhase) -> Bool {
            switch (lhs, rhs) {
            case (.collecting, .collecting): return true
            case (.readyToGenerate, .readyToGenerate): return true
            case (.generating(let a), .generating(let b)): return a == b
            case (.completed, .completed): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private var sampleCount: Int { sampleImages.count }
    private var canGenerate: Bool { sampleCount >= 5 && embeddingService.isAvailable }

    var body: some View {
        List {
            sampleSection
            actionSection
            statusSection
        }
        .navigationTitle("人脸注册")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSamples() }
        .fullScreenCover(isPresented: $showCamera) {
            NavigationStack {
                FaceCaptureView(contactID: contact.contactID, faceDataStore: faceDataStore)
            }
            .onDisappear { loadSamples() }
        }
        .alert("删除全部人脸数据？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { deleteAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除所有样本照片和已生成的特征数据，此操作不可恢复。")
        }
    }

    // MARK: - Sections

    private var sampleSection: some View {
        Section {
            if sampleImages.isEmpty {
                ContentUnavailableView(
                    "暂无样本",
                    systemImage: "person.crop.rectangle.badge.plus",
                    description: Text("点击下方按钮开始采集人脸样本")
                )
                .listRowBackground(Color.clear)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(Array(sampleImages.enumerated()), id: \.offset) { _, image in
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if sampleCount < 10 {
                        Button {
                            showCamera = true
                        } label: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                                .frame(width: 60, height: 60)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("样本照片")
        } footer: {
            Text("已采集 \(sampleCount) 张，需要至少 5 张（最多 10 张）")
        }
    }

    private var actionSection: some View {
        Section {
            if sampleImages.isEmpty {
                Button {
                    showCamera = true
                } label: {
                    Label("开始采集", systemImage: "camera.fill")
                }
            } else {
                Button {
                    showCamera = true
                } label: {
                    Label("继续采集", systemImage: "camera.fill")
                }
                .disabled(sampleCount >= 10)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除全部", systemImage: "trash")
                }
            }

            if canGenerate {
                Button {
                    generateEmbedding()
                } label: {
                    Label("生成特征", systemImage: "cpu")
                }
                .disabled(isGenerating)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .collecting:
            EmptyView()
        case .readyToGenerate:
            Section {
                Label("样本充足，可以生成特征", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        case .generating(let progress):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("正在生成特征...")
                    ProgressView(value: progress)
                }
            }
        case .completed:
            Section {
                Label("特征已保存（v\(contact.faceVersion)，\(contact.faceSampleCount)张样本）",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .error(let msg):
            Section {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }

        if !embeddingService.isAvailable {
            Section {
                Label("人脸识别模型未加载，无法生成特征", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
    }

    // MARK: - Logic

    private var isGenerating: Bool {
        if case .generating = phase { return true }
        return false
    }

    private func loadSamples() {
        sampleImages = faceDataStore.loadSamples(for: contact.contactID)
        updatePhase()
    }

    private func updatePhase() {
        if contact.faceEnrolled {
            phase = .completed
        } else if sampleCount >= 5 {
            phase = .readyToGenerate
        } else {
            phase = .collecting
        }
    }

    private func generateEmbedding() {
        phase = .generating(0)

        Task {
            do {
                let embedding = try await embeddingService.generateReferenceEmbedding(
                    samples: sampleImages
                ) { progress in
                    Task { @MainActor in
                        // Guard: don't overwrite .completed with late progress callback
                        if case .generating = phase {
                            phase = .generating(progress)
                        }
                    }
                }

                try faceDataStore.saveReferenceEmbedding(embedding, contactID: contact.contactID)

                contact.faceEnrolled = true
                contact.faceSampleCount = sampleCount
                contact.faceVersion += 1
                contact.faceUpdatedAt = Date()
                contact.updatedAt = Date()
                try? modelContext.save()

                phase = .completed
            } catch {
                phase = .error("生成失败：\(error.localizedDescription)")
            }
        }
    }

    private func deleteAll() {
        try? faceDataStore.deleteAllData(for: contact.contactID)

        contact.faceEnrolled = false
        contact.faceSampleCount = 0
        contact.faceUpdatedAt = Date()
        contact.updatedAt = Date()
        try? modelContext.save()

        sampleImages = []
        phase = .collecting
    }
}
