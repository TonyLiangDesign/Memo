import SwiftUI

/// Displays the app icon from the bundle at the given size with standard iOS rounded-rect styling.
struct AppIconView: View {
    var size: CGFloat = 80

    var body: some View {
        Group {
            if let icon = loadAppIcon() {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback if icon can't be loaded
                Image(systemName: "brain.head.profile")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.224, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func loadAppIcon() -> UIImage? {
        // Try loading from bundle icon files directly
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let lastIcon = files.last,
           let image = UIImage(named: lastIcon) {
            return image
        }
        // Fallback: try common icon names
        for name in ["AppIcon60x60@3x", "AppIcon76x76@2x", "AppIcon-1024", "AppIcon"] {
            if let image = UIImage(named: name) {
                return image
            }
        }
        return nil
    }
}
