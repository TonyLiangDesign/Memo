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
        self.hasGeminiKey = Self.load(key: Self.geminiKeychainKey) != nil || Self.builtInGeminiKey != nil
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
            baseURL: url,
            auth: auth,
            apiVersion: deploymentMode.apiVersion,
            statusPathSegment: deploymentMode.statusPathSegment,
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

    /// Returns Keychain-stored key if available, otherwise falls back to built-in key.
    var geminiAPIKey: String? {
        Self.load(key: Self.geminiKeychainKey) ?? Self.builtInGeminiKey
    }

    // Built-in Gemini key (XOR-obfuscated to avoid plaintext leaks in source/binary)
    private static let _gm: [UInt8] = [
        0xA8, 0xF8, 0x1E, 0xF5, 0xCC, 0x86, 0x7E, 0xDB, 0xF6, 0x19,
        0xA2, 0xF4, 0xAC, 0xF7, 0xE0, 0x09, 0xD8, 0xDB, 0x50, 0x1A,
        0x16, 0xA1, 0x3D, 0x0B, 0x72, 0x6F, 0xC6, 0x15, 0xEF, 0xB8,
        0x3A, 0x9C, 0xE5, 0xFF, 0xC2, 0xCC, 0x4E, 0xB3, 0x96
    ]
    private static let _gk: [UInt8] = [
        0xE9, 0xB1, 0x64, 0x94, 0x9F, 0xFF, 0x3C, 0xA2, 0xC4, 0x6A,
        0x90, 0xC7, 0xE9, 0xBD, 0xBA, 0x3E, 0x8F, 0xB0, 0x09, 0x56,
        0x42, 0xE8, 0x49, 0x40, 0x1A, 0x5E, 0x99, 0x5D, 0x83, 0xDC,
        0x50, 0xCB, 0x8B, 0xBA, 0x98, 0xF9, 0x39, 0xFB, 0xCF
    ]
    private static var builtInGeminiKey: String? {
        guard _gm.count == _gk.count else { return nil }
        let bytes = zip(_gk, _gm).map { $0 ^ $1 }
        return String(bytes: bytes, encoding: .utf8)
    }

    func saveGeminiAPIKey(_ value: String) {
        Self.save(key: Self.geminiKeychainKey, value: value)
        hasGeminiKey = true
    }

    func deleteGeminiAPIKey() {
        Self.delete(key: Self.geminiKeychainKey)
        hasGeminiKey = false
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
