import UIKit

/// Cover the entire window, including presented review/help/share sheets, before
/// iOS captures the inactive app. Restoring activity removes only our own covers.
@MainActor
final class AppPrivacyShield {
    private var covers: [UIView] = []

    func conceal() {
        guard covers.isEmpty else { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .filter { !$0.isHidden }
        for window in windows {
            let cover = UIView(frame: window.bounds)
            cover.backgroundColor = .systemBackground
            cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cover.accessibilityIdentifier = "privacyShield"
            cover.isAccessibilityElement = true
            cover.accessibilityLabel = String(localized: "Photo hidden while PicStrip is inactive")
            let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
            icon.tintColor = .systemTeal
            icon.contentMode = .scaleAspectFit
            icon.translatesAutoresizingMaskIntoConstraints = false
            cover.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 64),
                icon.heightAnchor.constraint(equalToConstant: 72)
            ])
            window.addSubview(cover)
            covers.append(cover)
        }
    }

    func reveal() {
        covers.forEach { $0.removeFromSuperview() }
        covers.removeAll()
    }
}
