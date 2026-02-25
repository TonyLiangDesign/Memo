import SwiftUI
import SwiftData

/// Edit/correct a memory event — caregiver can fix content and add reason
struct MemoryEditView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let event: MemoryEvent
    @State private var correctedContent: String = ""
    @State private var correctionReason: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("原始内容") {
                    Text(event.content)
                        .foregroundStyle(.secondary)
                }

                Section("更正内容") {
                    TextField("更正后的内容", text: $correctedContent)
                }

                Section("更正原因（可选）") {
                    TextField("例如：位置不对", text: $correctionReason)
                }
            }
            .navigationTitle("更正记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存更正") { save() }
                        .disabled(correctedContent.isEmpty)
                }
            }
            .onAppear {
                correctedContent = event.correctedContent ?? event.content
            }
        }
    }

    private func save() {
        event.correctedContent = correctedContent
        event.correctionReason = correctionReason.isEmpty ? nil : correctionReason
        event.reviewStatus = .corrected
        try? modelContext.save()
        dismiss()
    }
}