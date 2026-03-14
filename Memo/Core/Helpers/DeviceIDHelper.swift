import Foundation

enum DeviceIDHelper {
    static func augment(userId: String, with deviceId: String?) -> String {
        guard let deviceId = deviceId else { return userId }
        return "\(userId)_\(deviceId)"
    }

    static func augment(groupId: String, with deviceId: String?) -> String {
        guard let deviceId = deviceId else { return groupId }
        return "\(groupId)_\(deviceId)"
    }
}
