import Foundation
import SwiftData

/// Caregiver-managed contact book entry used by the patient call-assist flow.
@Model
final class CareContact {
    @Attribute(.unique) var contactID: String
    var relation: String
    var realName: String
    var phoneNumber: String
    var aliases: String
    var createdAt: Date
    var updatedAt: Date

    // Face recognition metadata (embedding stored in FaceDataStore file system)
    var faceEnrolled: Bool = false
    var faceSampleCount: Int = 0
    var faceVersion: Int = 0
    var faceUpdatedAt: Date?

    init(
        contactID: String = UUID().uuidString,
        relation: String,
        realName: String,
        phoneNumber: String,
        aliases: String = ""
    ) {
        self.contactID = contactID
        self.relation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.realName = realName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phoneNumber = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

extension CareContact {
    var displayName: String {
        if relation.isEmpty { return realName }
        if realName.isEmpty { return relation }
        return "\(relation)（\(realName)）"
    }

    /// Name used in the confirmation sentence, e.g. "你的女儿（Annie）".
    var confirmationName: String {
        if relation.isEmpty { return realName }
        if realName.isEmpty { return "你的\(relation)" }
        return "你的\(relation)（\(realName)）"
    }

    /// Tokens used by local intent matching.
    var searchableNames: [String] {
        let separators = CharacterSet(charactersIn: ",，;；/|")
        let aliasTokens = aliases
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(([relation, realName] + aliasTokens).filter { !$0.isEmpty }))
    }

    var faceStatusText: String {
        if !faceEnrolled { return String(localized: "人脸识别未注册") }
        return String(localized: "人脸识别已注册")
    }

    /// Keep leading + for international numbers, strip all other non-digit characters.
    var dialableNumber: String {
        var result = ""
        for (idx, ch) in phoneNumber.enumerated() {
            if ch.isNumber {
                result.append(ch)
            } else if ch == "+", idx == 0 {
                result.append(ch)
            }
        }
        return result
    }
}
