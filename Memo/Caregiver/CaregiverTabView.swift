import SwiftUI
import SwiftData

/// Caregiver tab container — protected by AuthService (biometric/PIN)
/// AuthService is injected from MemoApp level so auth persists across role switches
struct CaregiverTabView: View {
    @Environment(AuthService.self) private var authService
    @Environment(RoleManager.self) private var roleManager
    @Environment(APIKeyStore.self) private var apiKeyStore
    @Environment(HomeKitPassiveEventService.self) private var homeKitService
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if authService.isAuthenticated {
                authenticatedContent
            } else {
                CaregiverAuthView()
            }
        }
        .task {
            let client = apiKeyStore.buildAPIClient()
            homeKitService.start(context: modelContext, client: client)
        }
    }

    private var authenticatedContent: some View {
        TabView {
            RecommendationsView()
                .tabItem {
                    Label("今日建议", systemImage: "lightbulb.fill")
                }

            PlansListView()
                .tabItem {
                    Label("计划", systemImage: "pills.fill")
                }

            ContactsListView()
                .tabItem {
                    Label("联系人", systemImage: "person.2.fill")
                }

            RoomListView()
                .tabItem {
                    Label("空间建档", systemImage: "map.fill")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape.fill")
                }
        }
    }
}
