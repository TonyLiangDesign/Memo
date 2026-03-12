import SwiftUI
import SwiftData
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "MemoApp")

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
    @State private var showSetup = false

    init() {
        let aks = APIKeyStore()
        _apiKeyStore = State(initialValue: aks)
        _geminiMedicationService = State(initialValue: GeminiMedicationService(apiKeyStore: aks))

        let needsSetup = !UserDefaults.standard.bool(forKey: "com.memo.setupComplete")
        _showSetup = State(initialValue: needsSetup)
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
            .sheet(isPresented: $showSetup) {
                SetupSheet()
                    .environment(apiKeyStore)
            }
            .task {
                // Trigger network permission prompt early
                _ = try? await URLSession.shared.data(from: URL(string: "https://www.apple.com")!)

                let context = sharedModelContainer.mainContext
                SchemaMigration.runIfNeeded(context: context)
                dailyMemoryService.checkPendingPractice(context: context)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
