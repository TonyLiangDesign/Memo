import Foundation

/// Manages unique device identifier for multi-user support
@Observable
final class DeviceIDManager {
    static let shared = DeviceIDManager()

    private static let deviceIDKey = "com.memo.deviceID"

    /// Unique device identifier (persisted in UserDefaults)
    let deviceID: String

    init() {
        if let existing = UserDefaults.standard.string(forKey: Self.deviceIDKey) {
            self.deviceID = existing
        } else {
            let newID = UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(String(newID), forKey: Self.deviceIDKey)
            self.deviceID = String(newID)
        }
    }

    /// User ID with device suffix
    func userID(for role: String) -> String {
        "\(role)_\(deviceID)"
    }

    /// Group ID with device suffix
    func groupID(for role: String) -> String {
        "memo_\(role)_\(deviceID)"
    }
}
