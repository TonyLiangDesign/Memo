import SwiftUI
import SwiftData

/// Memory review list — shows pending review events for caregiver
struct MemoryReviewListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryEvent.deviceTime, order: .reverse)
    private var allEvents: [MemoryEvent]

    @State private var editingEvent: MemoryEvent?

    private var pendingEvents: [MemoryEvent] {
        allEvents.filter { $0.reviewStatus != .deleted }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(pendingEvents, id: \.eventID) { event in
                    eventRow(event)
                }
            }
            .overlay {
                if pendingEvents.isEmpty {
                    ContentUnavailableView(
                        "暂无记忆",
                        systemImage: "brain",
                        description: Text("患者记录的内容会出现在这里")
                    )
                }
            }
            .navigationTitle("记忆审核")
            .roleSwitchToolbar()
            .sheet(item: $editingEvent) { event in
                MemoryEditView(event: event)
            }
        }
    }

    private func eventRow(_ event: MemoryEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.deviceTime.relativeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ReviewStatusBadge(status: event.reviewStatus)
            }

            Text(event.displayContent)
                .font(.body)

            if let corrected = event.correctedContent {
                HStack(spacing: 4) {
                    Image(systemName: "pencil.line")
                    Text("原文：\(event.content)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if event.reviewStatus == .pendingReview {
                    Button("批准") { approve(event) }
                        .buttonStyle(.bordered)
                        .tint(.green)
                }
                Button("更正") { editingEvent = event }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                Button("删除") { deleteEvent(event) }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func approve(_ event: MemoryEvent) {
        event.reviewStatus = .approved
        try? modelContext.save()
    }

    private func deleteEvent(_ event: MemoryEvent) {
        event.reviewStatus = .deleted
        try? modelContext.save()
    }
}