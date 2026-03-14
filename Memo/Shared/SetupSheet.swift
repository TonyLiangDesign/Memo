import SwiftUI
import EverMemOSKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "SetupSheet")

/// First-launch setup sheet — manual API key configuration.
struct SetupSheet: View {
    @Environment(APIKeyStore.self) private var apiKeyStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDeployment: DeploymentProfile = .cloud
    @State private var baseURL = ""
    @State private var everMemOSToken = ""
    @State private var deepSeekKey = ""
    @State private var geminiKey = ""
    @State private var connectionStatus: ConnectionStatus = .idle

    private enum ConnectionStatus {
        case idle, testing, success, failure
    }

    private var canContinue: Bool {
        guard !deepSeekKey.isEmpty || apiKeyStore.hasDeepSeekKey else { return false }
        if selectedDeployment == .cloud {
            return !everMemOSToken.isEmpty || apiKeyStore.hasEverMemOSToken
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                manualSections
            }
            .navigationTitle("欢迎")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .onAppear {
                selectedDeployment = apiKeyStore.deploymentMode
                baseURL = apiKeyStore.everMemOSBaseURL
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                AppIconView(size: 80)
                Text("初始配置")
                    .font(.title2.bold())
                Text("填写 API 密钥以启用核心功能")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Manual Sections

    private var manualSections: some View {
        Group {
            Section(header: Text("EverMemOS 记忆服务"), footer: everMemOSFooter) {
                Picker("部署模式", selection: $selectedDeployment) {
                    Text("云端").tag(DeploymentProfile.cloud)
                    Text("本地").tag(DeploymentProfile.local)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedDeployment) { _, newValue in
                    baseURL = newValue.defaultBaseURL.absoluteString
                }

                TextField("Base URL", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if selectedDeployment == .cloud {
                    SecureField("EverMemOS API Token", text: $everMemOSToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Button {
                    testConnection()
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        switch connectionStatus {
                        case .idle: EmptyView()
                        case .testing: ProgressView()
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

            Section(header: Text("DeepSeek AI 对话"), footer: Text("必填。用于「问一问」AI 对话功能。")) {
                SecureField("DeepSeek API Key", text: $deepSeekKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section(header: Text("Gemini AI 用药监控"), footer: Text("选填。已内置默认密钥，如需使用自己的密钥可在此覆盖。")) {
                SecureField("Gemini API Key", text: $geminiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Button {
                    saveAll()
                } label: {
                    Text("完成配置")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
                .listRowBackground(Color.clear)
            }
        }
    }

    @ViewBuilder
    private var everMemOSFooter: some View {
        if selectedDeployment == .local {
            Text("本地模式需输入 Mac 局域网 IP（非 localhost），如 http://192.168.1.x:1995")
        } else {
            Text("云端模式需填写 API Token。")
        }
    }

    // MARK: - Actions

    private func testConnection() {
        connectionStatus = .testing
        apiKeyStore.saveDeploymentMode(selectedDeployment)
        apiKeyStore.saveEverMemOSBaseURL(baseURL)
        if !everMemOSToken.isEmpty {
            apiKeyStore.saveEverMemOSToken(everMemOSToken)
        }
        guard let client = apiKeyStore.buildAPIClient() else {
            connectionStatus = .failure
            return
        }
        Task {
            let reachable = await client.isReachable()
            connectionStatus = reachable ? .success : .failure
        }
    }

    private func saveAll() {
        apiKeyStore.saveDeploymentMode(selectedDeployment)
        apiKeyStore.saveEverMemOSBaseURL(baseURL)
        if !everMemOSToken.isEmpty {
            apiKeyStore.saveEverMemOSToken(everMemOSToken)
        }
        if !deepSeekKey.isEmpty {
            apiKeyStore.saveDeepSeekAPIKey(deepSeekKey)
        }
        if !geminiKey.isEmpty {
            apiKeyStore.saveGeminiAPIKey(geminiKey)
        }
        UserDefaults.standard.set(true, forKey: "com.memo.setupComplete")
        dismiss()
    }
}
