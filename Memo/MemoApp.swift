import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.Memo", category: "MemoApp")

@main
struct MemoApp: App {
    @State private var roleManager = RoleManager()
    @State private var authService = AuthService()
    @State private var speechService = SpeechService()
    @State private var tts = SpeechSynthesisService()
    @State private var apiKeyStore = APIKeyStore()
    @State private var geminiMedicationService: GeminiMedicationService
    @State private var patientModeManager = PatientModeManager()
    @State private var homeKitPassiveEventService = HomeKitPassiveEventService()
    @State private var dailyMemoryService = DailyMemoryService()

    init() {
        let aks = APIKeyStore()
        _apiKeyStore = State(initialValue: aks)
        _geminiMedicationService = State(initialValue: GeminiMedicationService(apiKeyStore: aks))

        // Force PIN to 7777 for dev convenience
        let auth = AuthService()
        auth.savePIN("7777")
        _authService = State(initialValue: auth)
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MemoryEvent.self,
            EpisodicMemory.self,
            EventLog.self,
            Foresight.self,
            MedicationPlan.self,
            SpatialAnchor.self,
            CareContact.self,
            RoomProfile.self,
            CaregiverRecommendation.self,
            MemoryCard.self,
            PracticeSession.self,
            SensorEvent.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            Group {
                if let role = roleManager.currentRole {
                    switch role {
                    case .patient:
                        PatientRootView()
                    case .caregiver:
                        CaregiverTabView()
                    }
                } else {
                    RoleSwitcherView()
                }
            }
            .environment(roleManager)
            .environment(authService)
            .environment(speechService)
            .environment(tts)
            .environment(apiKeyStore)
            .environment(geminiMedicationService)
            .environment(patientModeManager)
            .environment(homeKitPassiveEventService)
            .environment(dailyMemoryService)
            .task {
                let context = sharedModelContainer.mainContext
                SchemaMigration.runIfNeeded(context: context)
                let client = apiKeyStore.buildAPIClient()
                homeKitPassiveEventService.start(context: context, client: client)
                dailyMemoryService.checkPendingPractice(context: context)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
