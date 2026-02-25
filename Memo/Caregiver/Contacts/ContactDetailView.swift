import SwiftUI
import SwiftData

/// Contact detail view with inline editing and face registration entry point.
struct ContactDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var contact: CareContact

    @State private var isEditing = false
    @State private var editRelation = ""
    @State private var editRealName = ""
    @State private var editPhoneNumber = ""
    @State private var editAliases = ""

    var body: some View {
        List {
            Section("基本信息") {
                if isEditing {
                    TextField("关系（例：女儿）", text: $editRelation)
                    TextField("真实姓名（例：Annie）", text: $editRealName)
                    TextField("电话号码", text: $editPhoneNumber)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.phonePad)
                    TextField("别名（可选，逗号分隔）", text: $editAliases)
                } else {
                    LabeledContent("关系", value: contact.relation)
                    LabeledContent("姓名", value: contact.realName)
                    LabeledContent("电话", value: contact.phoneNumber)
                    if !contact.aliases.isEmpty {
                        LabeledContent("别名", value: contact.aliases)
                    }
                }
            }

            Section("人脸识别") {
                HStack {
                    Image(systemName: contact.faceEnrolled ? "face.smiling.fill" : "face.dashed")
                        .foregroundStyle(contact.faceEnrolled ? .green : .secondary)
                    Text(contact.faceStatusText)
                }

                NavigationLink {
                    FaceRegistrationView(contact: contact)
                } label: {
                    Label(contact.faceEnrolled ? "管理人脸" : "注册人脸",
                          systemImage: "person.crop.rectangle.badge.plus")
                }
            }
        }
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button("保存") { saveEdits() }
                        .disabled(!canSave)
                } else {
                    Button("编辑") { startEditing() }
                }
            }
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isEditing = false }
                }
            }
        }
    }

    private var canSave: Bool {
        let hasName = !editRelation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !editRealName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhone = !editPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasPhone
    }

    private func startEditing() {
        editRelation = contact.relation
        editRealName = contact.realName
        editPhoneNumber = contact.phoneNumber
        editAliases = contact.aliases
        isEditing = true
    }

    private func saveEdits() {
        contact.relation = editRelation.trimmingCharacters(in: .whitespacesAndNewlines)
        contact.realName = editRealName.trimmingCharacters(in: .whitespacesAndNewlines)
        contact.phoneNumber = editPhoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        contact.aliases = editAliases.trimmingCharacters(in: .whitespacesAndNewlines)
        contact.updatedAt = Date()
        try? modelContext.save()
        isEditing = false
    }
}
