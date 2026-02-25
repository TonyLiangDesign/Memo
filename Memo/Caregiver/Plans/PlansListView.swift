import SwiftUI
import SwiftData

/// Medication plans list — shows today's plans with confirmation status
struct PlansListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MedicationPlan.scheduledTime)
    private var plans: [MedicationPlan]

    @State private var showAddPlan = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(plans, id: \.planID) { plan in
                    planRow(plan)
                }
                .onDelete(perform: deletePlans)
            }
            .overlay {
                if plans.isEmpty {
                    ContentUnavailableView(
                        "暂无计划",
                        systemImage: "pills",
                        description: Text("点击右上角添加用药计划")
                    )
                }
            }
            .navigationTitle("计划")
            .roleSwitchToolbar()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddPlan = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddPlan) {
                AddPlanView()
            }
        }
    }

    private func planRow(_ plan: MedicationPlan) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.medicationName)
                    .font(.headline)
                Text("计划时间：\(plan.scheduledTime.timeOnlyString)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if plan.repeatDaily {
                    Text("每日重复")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
            if plan.isConfirmed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.title2)
            }
        }
    }

    private func deletePlans(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(plans[index])
        }
    }
}