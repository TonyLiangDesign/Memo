import SwiftUI

/// Biometric unlock screen with PIN fallback
struct CaregiverAuthView: View {
    @Environment(AuthService.self) private var authService
    @State private var pin = ""
    @State private var showPINInput = false
    @State private var errorMessage = ""
    @State private var isSettingPIN = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.pink)

            Text(String(localized: "照护者模式"))
                .font(.largeTitle.bold())

            Text(String(localized: "需要验证身份"))
                .font(.title3)
                .foregroundStyle(.secondary)

            if showPINInput || isSettingPIN {
                pinInputSection
            } else {
                biometricSection
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding()
        .task { await tryBiometrics() }
    }

    private var pinInputSection: some View {
        VStack(spacing: 16) {
            Text(isSettingPIN ? String(localized: "设置4位PIN码") : String(localized: "输入PIN码"))
                .font(.headline)

            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .multilineTextAlignment(.center)
                .font(.title2)

            Button {
                if isSettingPIN {
                    setPIN()
                } else {
                    verifyPIN()
                }
            } label: {
                Text(isSettingPIN ? String(localized: "设置") : String(localized: "确认"))
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(pin.count != 4)
            .padding(.horizontal, 40)
        }
    }

    private var biometricSection: some View {
        VStack(spacing: 16) {
            Button {
                Task { await tryBiometrics() }
            } label: {
                Label(String(localized: "使用Face ID"), systemImage: "faceid")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .padding(.horizontal, 40)

            Button(String(localized: "使用PIN码")) {
                if authService.hasPIN {
                    showPINInput = true
                } else {
                    isSettingPIN = true
                }
            }
            .font(.callout)
        }
    }

    private func tryBiometrics() async {
        let success = await authService.authenticateWithBiometrics()
        if !success && !authService.hasPIN {
            isSettingPIN = true
        } else if !success {
            showPINInput = true
        }
    }

    private func verifyPIN() {
        if authService.verifyPIN(pin) {
            errorMessage = ""
        } else {
            errorMessage = String(localized: "PIN码错误")
            pin = ""
        }
    }

    private func setPIN() {
        guard pin.count == 4 else { return }
        authService.savePIN(pin)
        authService.isAuthenticated = true
    }
}