import Foundation

struct ContactCallIntent {
    let contact: CareContact
    let matchedToken: String
}

/// Local parser for "contact/call someone" requests.
enum ContactCallIntentResolver {
    private static let cleanupSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    private static let explicitCallKeywords = [
        "联系", "联络", "拨打", "打给", "call", "phone"
    ]

    static func resolve(text: String, contacts: [CareContact]) -> ContactCallIntent? {
        let normalizedText = normalize(text)
        guard containsCallIntent(normalizedText), !contacts.isEmpty else { return nil }

        var bestMatch: ContactCallIntent?
        var bestScore = 0

        for contact in contacts {
            let tokens = expandedTokens(for: contact)
            for token in tokens {
                guard normalizedText.contains(token.normalized) else { continue }
                if token.normalized.count > bestScore {
                    bestScore = token.normalized.count
                    bestMatch = ContactCallIntent(contact: contact, matchedToken: token.raw)
                }
            }
        }

        return bestMatch
    }

    private static func containsCallIntent(_ text: String) -> Bool {
        if explicitCallKeywords.contains(where: { text.contains($0) }) {
            return true
        }
        return text.contains("电话") && (text.contains("打") || text.contains("联系"))
    }

    private static func expandedTokens(for contact: CareContact) -> [(raw: String, normalized: String)] {
        var tokens: [String] = []
        for name in contact.searchableNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            tokens.append(trimmed)
            if !trimmed.hasPrefix("我") {
                tokens.append("我\(trimmed)")
            }
            if !trimmed.hasPrefix("你") {
                tokens.append("你\(trimmed)")
            }
        }

        let unique = Array(Set(tokens))
        return unique.compactMap { raw in
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return nil }
            return (raw: raw, normalized: normalized)
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: cleanupSet)
            .joined()
    }
}
