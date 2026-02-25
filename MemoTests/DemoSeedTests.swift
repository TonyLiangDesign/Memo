import Testing
import Foundation
import SwiftData
@testable import Memo

@MainActor
private func makeSeedContainer() throws -> ModelContainer {
    let schema = Schema([
        MemoryEvent.self, EpisodicMemory.self, EventLog.self,
        Foresight.self, MedicationPlan.self, CareContact.self
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}

struct DemoSeedTests {

    @Test @MainActor func seedCreatesMedicationPlan() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext
        DemoSeed.seed(context: ctx)

        let plans = try ctx.fetch(FetchDescriptor<MedicationPlan>())
        #expect(plans.count == 1)
        #expect(plans[0].medicationName == "降压药")
    }

    @Test @MainActor func seedCreatesForesight() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext
        DemoSeed.seed(context: ctx)

        let foresights = try ctx.fetch(FetchDescriptor<Foresight>())
        #expect(foresights.count == 1)
        #expect(foresights[0].content == "服用降压药")
    }

    @Test @MainActor func seedCreatesMemoryEvents() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext
        DemoSeed.seed(context: ctx)

        let events = try ctx.fetch(FetchDescriptor<MemoryEvent>())
        #expect(events.count == 2)
    }

    @Test @MainActor func seedCreatesEventLogs() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext
        DemoSeed.seed(context: ctx)

        let logs = try ctx.fetch(FetchDescriptor<EventLog>())
        #expect(logs.count == 2)
    }

    @Test @MainActor func seedIsIdempotent() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext

        DemoSeed.seed(context: ctx)
        DemoSeed.seed(context: ctx)

        // Second seed should clear and re-create
        let events = try ctx.fetch(FetchDescriptor<MemoryEvent>())
        #expect(events.count == 2)
    }

    @Test @MainActor func seedCreatesContacts() throws {
        let container = try makeSeedContainer()
        let ctx = container.mainContext
        DemoSeed.seed(context: ctx)

        let contacts = try ctx.fetch(FetchDescriptor<CareContact>())
        #expect(contacts.count == 1)
        #expect(contacts[0].relation == "女儿")
        #expect(contacts[0].realName == "Annie")
    }
}
