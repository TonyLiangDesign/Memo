import Foundation
import LocalAuthentication
import Security

/// FaceID/TouchID + 4-digit PIN fallback authentication
@Observable
final class AuthService {
    var isAuthenticated = false

    private let keychainKey = "com.memo.caregiver.pin"

    /// Attempt biometric auth, returns success
    func authenticateWithBiometrics() async -> Bool {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: String(localized: "解锁照护者模式")
            )
            if success { isAuthenticated = true }
            return success
        } catch {
            return false
        }
    }

    /// Verify PIN against stored value
    func verifyPIN(_ pin: String) -> Bool {
        guard let stored = loadPIN(), stored == pin else { return false }
        isAuthenticated = true
        return true
    }

    /// Save PIN to Keychain
    func savePIN(_ pin: String) {
        let data = Data(pin.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Check if PIN is set
    var hasPIN: Bool { loadPIN() != nil }

    func logout() { isAuthenticated = false }

    private func loadPIN() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
