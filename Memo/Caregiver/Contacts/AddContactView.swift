import SwiftUI
import SwiftData

/// Create a caregiver contact entry.
struct AddContactView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var relation = ""
    @State private var realName = ""
    @State private var phoneNumber = ""
    @State private var aliases = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("联系人信息") {
                    TextField("关系（例：女儿）", text: $relation)
                    TextField("真实姓名（例：Annie）", text: $realName)
                    TextField("电话号码", text: $phoneNumber)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.phonePad)
                    TextField("别名（可选，逗号分隔）", text: $aliases)
                }
            }
            .navigationTitle("新增联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let hasName = !relation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !realName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPhone = !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasName && hasPhone
    }

    private func save() {
        let contact = CareContact(
            relation: relation,
            realName: realName,
            phoneNumber: phoneNumber,
            aliases: aliases
        )
        modelContext.insert(contact)
        try? modelContext.save()
        dismiss()
    }
}
