import SwiftUI
import EverMemOSKit
import os.log

private let logger = Logger(subsystem: "com.MrPolpo.MemoCare", category: "SetupSheet")

/// First-launch setup sheet — auto or manual API key configuration.
struct SetupSheet: View {
    @Environment(APIKeyStore.self) private var apiKeyStore
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case choose    // initial: pick auto or manual
        case auto      // one-click import + verification
        case manual    // existing form-based entry
    }

    @State private var mode: Mode = .choose

    // Auto mode
    @State private var importPhase: AutoPhase = .idle
    @State private var serviceChecks: [ServiceCheck] = []

    // Manual mode
    @State private var selectedDeployment: DeploymentProfile = .cloud
    @State private var baseURL = ""
    @State private var everMemOSToken = ""
    @State private var deepSeekKey = ""
    @State private var geminiKey = ""
    @State private var connectionStatus: ConnectionStatus = .idle

    private static let remoteConfigURL = "https://gist.githubusercontent.com/TonyLiangDesign/abe148834fce4a5ce543bfd7ee9f1bfd/raw"

    private enum AutoPhase: Equatable {
        case idle, importing, imported(Int), verifying, done, failure(String)
    }

    private struct ServiceCheck: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        var status: CheckStatus = .pending
    }

    private enum CheckStatus {
        case pending, checking, success, failure
    }

    private enum ConnectionStatus {
        case idle, testing, success, failure
    }

    private var manualCanContinue: Bool {
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

                switch mode {
                case .choose:
                    chooseSection
                case .auto:
                    autoSection
                case .manual:
                    manualSections
                }
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
                Image(systemName: "key.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("初始配置")
                    .font(.title2.bold())
                Text(mode == .choose
                     ? "选择配置方式以启用核心功能"
                     : mode == .auto ? "正在自动配置…" : "手动填写 API 密钥")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Choose Mode

    private var chooseSection: some View {
        Group {
            Section(footer: Text("自动从服务器获取所有 API 密钥，有效期至 2026 年 4 月。")) {
                Button {
                    mode = .auto
                    startAutoImport()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title)
                            .foregroundStyle(.blue)
                        Text("自动配置")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Button {
                    mode = .manual
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("手动配置")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Auto Mode

    private var autoSection: some View {
        Group {
            Section {
                switch importPhase {
                case .idle, .importing:
                    HStack {
                        Text("正在导入配置…")
                        Spacer()
                        ProgressView()
                    }
                case .imported(let count):
                    Label("已导入 \(count) 项配置", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .verifying:
                    Label("正在验证服务…", systemImage: "network")
                case .done:
                    Label("所有服务配置完成", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .failure(let msg):
                    VStack(alignment: .leading, spacing: 4) {
                        Label("导入失败", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !serviceChecks.isEmpty {
                Section(header: Text("服务验证")) {
                    ForEach(serviceChecks) { check in
                        HStack {
                            Image(systemName: check.icon)
                                .frame(width: 24)
                                .foregroundStyle(.blue)
                            Text(check.name)
                            Spacer()
                            switch check.status {
                            case .pending:
                                Image(systemName: "circle")
                                    .foregroundStyle(.tertiary)
                            case .checking:
                                ProgressView()
                                    .controlSize(.small)
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failure:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            if case .done = importPhase {
                Section {
                    Button {
                        UserDefaults.standard.set(true, forKey: "com.memo.setupComplete")
                        dismiss()
                    } label: {
                        Text("开始使用")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }

            if case .failure = importPhase {
                Section {
                    Button("切换到手动配置") {
                        mode = .manual
                    }
                    Button("重试") {
                        startAutoImport()
                    }
                }
            }
        }
    }

    // MARK: - Manual Mode

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

            Section(header: Text("Gemini AI 用药监控"), footer: Text("选填。用于摄像头自动识别服药行为。")) {
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
                .disabled(!manualCanContinue)
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    mode = .auto
                    startAutoImport()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Text("切换到自动配置")
                    }
                }
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

    // MARK: - Auto Import Logic

    private func startAutoImport() {
        importPhase = .importing
        serviceChecks = []
        Task {
            do {
                logger.info("Starting auto import from: \(Self.remoteConfigURL)")
                let count = try await apiKeyStore.importFromURL(Self.remoteConfigURL)
                logger.info("Import succeeded: \(count) keys")
                importPhase = .imported(count)
                await runServiceChecks()
            } catch {
                logger.error("Import failed: \(error)")
                importPhase = .failure(error.localizedDescription)
            }
        }
    }

    private func runServiceChecks() async {
        // Build the list of checks based on what was imported
        var checks: [ServiceCheck] = []

        if apiKeyStore.hasEverMemOSToken || apiKeyStore.everMemOSBaseURL != DeploymentProfile.cloud.defaultBaseURL.absoluteString {
            checks.append(ServiceCheck(name: "EverMemOS", icon: "brain.head.profile.fill"))
        }
        if apiKeyStore.hasDeepSeekKey {
            checks.append(ServiceCheck(name: "DeepSeek AI", icon: "bubble.left.fill"))
        }
        if apiKeyStore.hasGeminiKey {
            checks.append(ServiceCheck(name: "Gemini AI", icon: "eye.fill"))
        }

        serviceChecks = checks
        importPhase = .verifying

        // Check each service sequentially with animation
        for i in checks.indices {
            serviceChecks[i].status = .checking
            let success = await verifyService(checks[i].name)
            try? await Task.sleep(for: .milliseconds(400)) // visual feedback
            serviceChecks[i].status = success ? .success : .failure
        }

        importPhase = .done
    }

    private func verifyService(_ name: String) async -> Bool {
        switch name {
        case "EverMemOS":
            guard let client = apiKeyStore.buildAPIClient() else { return false }
            return await client.isReachable()
        case "DeepSeek AI":
            return await verifyDeepSeek()
        case "Gemini AI":
            return await verifyGemini()
        default:
            return false
        }
    }

    private func verifyDeepSeek() async -> Bool {
        guard let apiKey = apiKeyStore.deepSeekAPIKey else { return false }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func verifyGemini() async -> Bool {
        guard let apiKey = apiKeyStore.geminiAPIKey else { return false }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Manual Mode Logic

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
