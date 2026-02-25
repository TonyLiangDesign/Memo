import Testing
import Foundation
@testable import Memo

struct RoleManagerTests {

    /// Each test gets its own UserDefaults suite — fully isolated
    private func freshManager() -> RoleManager {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return RoleManager(defaults: suite)
    }

    @Test func initialStateIsNil() {
        let manager = freshManager()
        #expect(manager.currentRole == nil)
        #expect(manager.hasSelectedRole == false)
    }

    @Test func selectPatient() {
        let manager = freshManager()
        manager.selectRole(.patient)
        #expect(manager.currentRole == .patient)
        #expect(manager.hasSelectedRole == true)
        #expect(manager.senderID == "patient")
        #expect(manager.senderName == "患者")
        #expect(manager.isPatient == true)
        #expect(manager.isCaregiver == false)
    }

    @Test func selectCaregiver() {
        let manager = freshManager()
        manager.selectRole(.caregiver)
        #expect(manager.currentRole == .caregiver)
        #expect(manager.senderID == "caregiver")
        #expect(manager.senderName == "照护者")
        #expect(manager.isPatient == false)
        #expect(manager.isCaregiver == true)
    }

    @Test func toggleFromPatientToCaregiver() {
        let manager = freshManager()
        manager.selectRole(.patient)
        manager.toggleRole()
        #expect(manager.currentRole == .caregiver)
    }

    @Test func toggleFromCaregiverToPatient() {
        let manager = freshManager()
        manager.selectRole(.caregiver)
        manager.toggleRole()
        #expect(manager.currentRole == .patient)
    }

    @Test func toggleFromNilDoesNothing() {
        let manager = freshManager()
        manager.toggleRole()
        #expect(manager.currentRole == nil)
    }

    @Test func resetRole() {
        let suite = UserDefaults(suiteName: "test-reset-\(UUID().uuidString)")!
        let manager = RoleManager(defaults: suite)
        manager.selectRole(.patient)
        manager.resetRole()
        #expect(manager.currentRole == nil)
        #expect(manager.hasSelectedRole == false)
        #expect(suite.string(forKey: "selectedRole") == nil)
    }

    @Test func persistenceViaUserDefaults() {
        let suite = UserDefaults(suiteName: "test-persist-\(UUID().uuidString)")!
        let manager1 = RoleManager(defaults: suite)
        manager1.selectRole(.caregiver)

        let manager2 = RoleManager(defaults: suite)
        #expect(manager2.currentRole == .caregiver)
    }

    @Test func senderIDDefaultsToPatientWhenNil() {
        let manager = freshManager()
        #expect(manager.senderID == "patient")
        #expect(manager.senderName == "患者")
    }
}