import SwiftUI

/// Reusable toolbar button for switching roles.
/// Shows the opposite role's icon — tap to toggle.
struct RoleSwitchToolbar: ViewModifier {
    @Environment(RoleManager.self) private var roleManager

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation {
                        roleManager.toggleRole()
                    }
                } label: {
                    Label(
                        roleManager.isPatient ? "切换到照护者" : "切换到患者",
                        systemImage: roleManager.isPatient
                            ? "heart.fill"
                            : "person.fill"
                    )
                }
            }
        }
    }
}

extension View {
    func roleSwitchToolbar() -> some View {
        modifier(RoleSwitchToolbar())
    }
}
