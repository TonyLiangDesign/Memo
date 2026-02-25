import SwiftUI

/// First-launch role selection: "我是患者" / "我是照护者"
struct RoleSwitcherView: View {
    @Environment(RoleManager.self) private var roleManager

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("欢迎使用")
                .font(.largeTitle.bold())

            Text("请选择您的角色")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(spacing: 16) {
                roleButton(
                    role: .patient,
                    label: "我是患者",
                    icon: "person.fill",
                    color: .blue
                )
                roleButton(
                    role: .caregiver,
                    label: "我是照护者",
                    icon: "heart.fill",
                    color: .pink
                )
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private func roleButton(
        role: ActorRole, label: String, icon: String, color: Color
    ) -> some View {
        Button {
            roleManager.selectRole(role)
        } label: {
            Label(label, systemImage: icon)
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
    }
}