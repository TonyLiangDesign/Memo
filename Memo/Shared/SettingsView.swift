import SwiftUI
import SwiftData
import EverMemOSKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "SettingsView")

// MARK: - Reusable API Key Field

/// Self-contained API key input row with reveal toggle, save, and delete.
private struct APIKeyField: View {
    let storedValue: String?
    let onSave: (String) -> Void
    let onDelete: () -> Void

    @State private var input = ""
    @State private var isRevealed = false

    private var isConfigured: Bool { storedValue != nil }

    /// What to display: user input takes priority, otherwise stored value.
    private var displayValue: String {
        input.isEmpty ? (storedValue ?? "") : input
    }

    /// True when the user has typed something different from the stored value.
    private var hasUnsavedInput: Bool {
        !input.isEmpty && input != storedValue
    }

    var body: some View {
        HStack {
            if isRevealed {
                TextField("API Key", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onAppear { if input.isEmpty, let v = storedValue { input = v } }
            } else {
                SecureField("API Key", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button {
                if !isRevealed && input.isEmpty, let v = storedValue {
                    input = v
                }
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }

        if isConfigured && input.isEmpty {
            HStack {
                Label(String(localized: "已配置"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button(String(localized: "删除"), role: .destructive) {
                    onDelete()
                    input = ""
                    isRevealed = false
                }
                .font(.callout)
            }
        }

        if hasUnsavedInput {
            Button(String(localized: "保存")) {
                onSave(input)
                input = ""
                isRevealed = false
            }
        }
    }
}

// MARK: - Settings View

/// Settings view — role switch, demo data reset, timezone
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RoleManager.self) private var roleManager
    @Environment(APIKeyStore.self) private var apiKeyStore
    @State private var showResetConfirm = false
    @State private var resetDone = false
    @State private var everMemOSBaseURL = ""
    @State private var selectedDeployment: DeploymentProfile = .cloud
    @State private var connectionStatus: ConnectionStatus = .idle

    private enum ConnectionStatus {
        case idle, testing, success, failure
    }

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "角色")) {
                    HStack {
                        Text(String(localized: "当前角色"))
                        Spacer()
                        Text(roleManager.currentRole == .patient ? String(localized: "患者") : String(localized: "照护者"))
                            .foregroundStyle(.secondary)
                    }

                    Button(String(localized: "切换角色")) {
                        roleManager.toggleRole()
                    }
                }

                everMemOSSection

                Section(header: Text(String(localized: "DeepSeek AI 对话")), footer: Text(String(localized: "用于「问一问」AI 对话功能"))) {
                    APIKeyField(
                        storedValue: apiKeyStore.deepSeekAPIKey,
                        onSave: { apiKeyStore.saveDeepSeekAPIKey($0) },
                        onDelete: { apiKeyStore.deleteDeepSeekAPIKey() }
                    )
                }

                Section(header: Text(String(localized: "Gemini AI 用药监控")), footer: Text(String(localized: "用于摄像头自动识别服药行为"))) {
                    APIKeyField(
                        storedValue: apiKeyStore.geminiAPIKey,
                        onSave: { apiKeyStore.saveGeminiAPIKey($0) },
                        onDelete: { apiKeyStore.deleteGeminiAPIKey() }
                    )
                }

                Section(String(localized: "演示")) {
                    Button(String(localized: "注入演示数据")) {
                        showResetConfirm = true
                    }

                    if resetDone {
                        Label(String(localized: "演示数据已注入"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section(String(localized: "关于")) {
                    HStack {
                        Text(String(localized: "版本"))
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "设置"))
            .roleSwitchToolbar()
            .alert(String(localized: "重置数据"), isPresented: $showResetConfirm) {
                Button(String(localized: "取消"), role: .cancel) {}
                Button(String(localized: "确认重置"), role: .destructive) {
                    DemoSeed.seed(context: modelContext)
                    resetDone = true
                }
            } message: {
                Text(String(localized: "将清除所有数据并注入演示数据"))
            }
        }
    }

    // MARK: - EverMemOS Section

    private var everMemOSSection: some View {
        Section(header: Text("EverMemOS"), footer: selectedDeployment == .local ? Text(String(localized: "本地模式需输入 Mac 局域网 IP（非 localhost），如 http://192.168.1.x:1995")) : nil) {
            Picker(String(localized: "部署模式"), selection: $selectedDeployment) {
                Text(String(localized: "云端")).tag(DeploymentProfile.cloud)
                Text(String(localized: "本地")).tag(DeploymentProfile.local)
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedDeployment) { _, newValue in
                apiKeyStore.saveDeploymentMode(newValue)
                everMemOSBaseURL = apiKeyStore.everMemOSBaseURL
                connectionStatus = .idle
            }

            TextField("Base URL", text: $everMemOSBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onAppear {
                    selectedDeployment = apiKeyStore.deploymentMode
                    everMemOSBaseURL = apiKeyStore.everMemOSBaseURL
                }

            if selectedDeployment == .cloud {
                APIKeyField(
                    storedValue: apiKeyStore.everMemOSToken,
                    onSave: { apiKeyStore.saveEverMemOSToken($0) },
                    onDelete: { apiKeyStore.deleteEverMemOSToken() }
                )
            }

            if everMemOSBaseURL != apiKeyStore.everMemOSBaseURL {
                Button(String(localized: "保存 Base URL")) {
                    apiKeyStore.saveEverMemOSBaseURL(everMemOSBaseURL)
                }
            }

            Button {
                testConnection()
            } label: {
                HStack {
                    Text(String(localized: "测试连接"))
                    Spacer()
                    switch connectionStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(connectionStatus == .testing)
        }
    }

    private func testConnection() {
        connectionStatus = .testing
        print("🔍 [Settings] Testing connection - deployment: \(apiKeyStore.deploymentMode.rawValue), baseURL: \(apiKeyStore.everMemOSBaseURL)")
        logger.info("🔍 [Settings] Testing connection - deployment: \(apiKeyStore.deploymentMode.rawValue), baseURL: \(apiKeyStore.everMemOSBaseURL)")

        guard let client = apiKeyStore.buildAPIClient() else {
            print("❌ [Settings] Failed to build API client")
            logger.error("❌ [Settings] Failed to build API client")
            connectionStatus = .failure
            return
        }

        print("✅ [Settings] API client built successfully")
        logger.info("✅ [Settings] API client built successfully")

        Task {
            print("🌐 [Settings] Calling isReachable()...")
            logger.info("🌐 [Settings] Calling isReachable()...")
            let reachable = await client.isReachable()
            print("📡 [Settings] isReachable result: \(reachable)")
            logger.info("📡 [Settings] isReachable result: \(reachable)")
            connectionStatus = reachable ? .success : .failure
        }
    }
}
