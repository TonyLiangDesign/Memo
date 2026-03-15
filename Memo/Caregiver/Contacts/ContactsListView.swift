import SwiftUI
import SwiftData

/// Caregiver contact book list.
struct ContactsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CareContact.updatedAt, order: .reverse)
    private var contacts: [CareContact]

    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(contacts, id: \.contactID) { contact in
                    NavigationLink(value: contact.contactID) {
                        contactRow(contact)
                    }
                }
                .onDelete(perform: deleteContacts)
            }
            .navigationDestination(for: String.self) { contactID in
                if let contact = contacts.first(where: { $0.contactID == contactID }) {
                    ContactDetailView(contact: contact)
                }
            }
            .overlay {
                if contacts.isEmpty {
                    ContentUnavailableView(
                        String(localized: "暂无联系人"),
                        systemImage: "person.2",
                        description: Text(String(localized: "点击右上角添加家人或紧急联系人"))
                    )
                }
            }
            .navigationTitle(String(localized: "联系人"))
            .roleSwitchToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddContactView()
            }
        }
    }

    private func contactRow(_ contact: CareContact) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.displayName)
                    .font(.headline)

                if !contact.aliases.isEmpty {
                    Text(String(localized: "别名：\(contact.aliases)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func deleteContacts(at offsets: IndexSet) {
        let faceDataStore = FaceDataStore()
        for idx in offsets {
            let contact = contacts[idx]
            // Cascade delete face data files
            try? faceDataStore.deleteAllData(for: contact.contactID)
            modelContext.delete(contact)
        }
        try? modelContext.save()
    }
}
