import Foundation
import SwiftUI

/// Observable role state manager — single source of truth for current role
@Observable
final class RoleManager {
    var currentRole: ActorRole?

    private let defaults: UserDefaults

    var hasSelectedRole: Bool {
        currentRole != nil
    }

    /// Convenience: current sender string for data attribution
    var senderID: String {
        currentRole == .caregiver ? "caregiver" : "patient"
    }

    var senderName: String {
        currentRole == .caregiver ? String(localized: "照护者") : String(localized: "患者")
    }

    var isPatient: Bool { currentRole == .patient }
    var isCaregiver: Bool { currentRole == .caregiver }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.string(forKey: "selectedRole"),
           let role = ActorRole(rawValue: saved) {
            currentRole = role
        }
    }

    func selectRole(_ role: ActorRole) {
        currentRole = role
        defaults.set(role.rawValue, forKey: "selectedRole")
    }

    /// Toggle between patient and caregiver
    func toggleRole() {
        switch currentRole {
        case .patient: selectRole(.caregiver)
        case .caregiver: selectRole(.patient)
        case nil: break
        }
    }

    func resetRole() {
        currentRole = nil
        defaults.removeObject(forKey: "selectedRole")
    }
}
