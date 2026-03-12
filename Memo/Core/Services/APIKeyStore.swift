import Foundation
import Security
import EverMemOSKit

/// Keychain-backed API key storage
@Observable @MainActor
final class APIKeyStore {
    var hasEverMemOSToken: Bool
    var hasDeepSeekKey: Bool
    var hasGeminiKey: Bool
    var deploymentMode: DeploymentProfile

    private static let everMemOSTokenKey = "com.memo.api.evermemos.token"
    private static let deepSeekKeychainKey = "com.memo.api.deepseek"
    private static let geminiKeychainKey = "com.memo.api.gemini"
    private static let baseURLKeyPrefix = "com.memo.evermemos.baseURL"
    private static let deploymentModeKey = "com.memo.evermemos.deploymentMode"

    init() {
        self.hasEverMemOSToken = Self.load(key: Self.everMemOSTokenKey) != nil
        self.hasDeepSeekKey = Self.load(key: Self.deepSeekKeychainKey) != nil
        self.hasGeminiKey = Self.load(key: Self.geminiKeychainKey) != nil
        let raw = UserDefaults.standard.string(forKey: Self.deploymentModeKey) ?? "cloud"
        self.deploymentMode = DeploymentProfile(rawValue: raw) ?? .cloud
        Self.migrateBaseURLKeyIfNeeded()
    }

    /// One-time migration: move legacy single base URL key to the correct per-mode key.
    private static func migrateBaseURLKeyIfNeeded() {
        let legacyKey = baseURLKeyPrefix
        let cloudKey = "\(baseURLKeyPrefix).cloud"
        let localKey = "\(baseURLKeyPrefix).local"

        // Fix: if cloud key got a localhost URL from bad migration, remove it
        if let cloudVal = UserDefaults.standard.string(forKey: cloudKey),
           cloudVal.contains("localhost") || cloudVal.hasPrefix("http://") {
            UserDefaults.standard.removeObject(forKey: cloudKey)
        }

        // Migrate legacy key to the right per-mode key
        if let oldValue = UserDefaults.standard.string(forKey: legacyKey) {
            let isLocal = oldValue.contains("localhost") || oldValue.contains("192.168") || oldValue.contains("10.0")
            let targetKey = isLocal ? localKey : cloudKey
            if UserDefaults.standard.string(forKey: targetKey) == nil {
                UserDefaults.standard.set(oldValue, forKey: targetKey)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    // MARK: - Deployment Mode

    func saveDeploymentMode(_ mode: DeploymentProfile) {
        deploymentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.deploymentModeKey)
    }

    // MARK: - API Client Factory

    func buildAPIClient() -> EverMemOSClient? {
        guard let url = URL(string: everMemOSBaseURL) else { return nil }

        let auth: AuthProvider
        if deploymentMode.requiresAuth {
            guard let token = everMemOSToken else { return nil }
            auth = BearerTokenAuth(token: token)
        } else {
            auth = NoAuth()
        }

        let config = Configuration(
            profile: deploymentMode,
            baseURL: url,
            auth: auth,
            logLevel: .debug
        )
        return EverMemOSClient(config: config)
    }

    // MARK: - EverMemOS Token

    var everMemOSToken: String? {
        Self.load(key: Self.everMemOSTokenKey)
    }

    var everMemOSBaseURL: String {
        UserDefaults.standard.string(forKey: baseURLKey)
            ?? deploymentMode.defaultBaseURL.absoluteString
    }

    private var baseURLKey: String {
        "\(Self.baseURLKeyPrefix).\(deploymentMode.rawValue)"
    }

    func saveEverMemOSToken(_ value: String) {
        Self.save(key: Self.everMemOSTokenKey, value: value)
        hasEverMemOSToken = true
    }

    func deleteEverMemOSToken() {
        Self.delete(key: Self.everMemOSTokenKey)
        hasEverMemOSToken = false
    }

    func saveEverMemOSBaseURL(_ value: String) {
        UserDefaults.standard.set(value, forKey: baseURLKey)
    }

    // MARK: - DeepSeek API Key

    var deepSeekAPIKey: String? {
        Self.load(key: Self.deepSeekKeychainKey)
    }

    func saveDeepSeekAPIKey(_ value: String) {
        Self.save(key: Self.deepSeekKeychainKey, value: value)
        hasDeepSeekKey = true
    }

    func deleteDeepSeekAPIKey() {
        Self.delete(key: Self.deepSeekKeychainKey)
        hasDeepSeekKey = false
    }

    // MARK: - Gemini API Key

    var geminiAPIKey: String? {
        Self.load(key: Self.geminiKeychainKey)
    }

    func saveGeminiAPIKey(_ value: String) {
        Self.save(key: Self.geminiKeychainKey, value: value)
        hasGeminiKey = true
    }

    func deleteGeminiAPIKey() {
        Self.delete(key: Self.geminiKeychainKey)
        hasGeminiKey = false
    }

    // MARK: - Remote Config Import

    struct RemoteConfig: Codable {
        let version: Int
        let app: String
        let keys: [String: String]
    }

    enum ImportError: LocalizedError {
        case invalidURL
        case networkError(Error)
        case invalidFormat
        case wrongApp(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的 URL"
            case .networkError(let e): return "网络错误: \(e.localizedDescription)"
            case .invalidFormat: return "配置格式无效"
            case .wrongApp(let app): return "配置属于 \(app)，不适用于本 App"
            }
        }
    }

    func importFromURL(_ urlString: String) async throws -> Int {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ImportError.invalidURL
        }

        let data: Data
        do {
            let (d, _) = try await URLSession.shared.data(from: url)
            data = d
        } catch {
            throw ImportError.networkError(error)
        }

        guard let config = try? JSONDecoder().decode(RemoteConfig.self, from: data) else {
            throw ImportError.invalidFormat
        }

        guard config.app.lowercased() == "memocare" else {
            throw ImportError.wrongApp(config.app)
        }

        var imported = 0
        for (key, value) in config.keys {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            switch key {
            case "deepseek":
                saveDeepSeekAPIKey(trimmed)
                imported += 1
            case "gemini":
                saveGeminiAPIKey(trimmed)
                imported += 1
            case "evermemos_token":
                saveEverMemOSToken(trimmed)
                imported += 1
            case "evermemos_base_url":
                saveEverMemOSBaseURL(trimmed)
                imported += 1
            case "evermemos_deployment":
                if let mode = DeploymentProfile(rawValue: trimmed) {
                    saveDeploymentMode(mode)
                    imported += 1
                }
            default:
                break
            }
        }
        return imported
    }

    // MARK: - Keychain Helpers

    private static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
