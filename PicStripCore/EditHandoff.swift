import Foundation
import UserNotifications

// MARK: - EditHandoffNotification

/// The notification that takes an item handed over by "Edit in PicStrip" into
/// the app.
///
/// An extension has no supported way to open its app, so after it writes the
/// handoff it posts this local notification: a tap opens PicStrip, which drains
/// the handoff when it becomes active, as it always has.  The notification is
/// the same for every item and says nothing about it — no file name, no
/// thumbnail — because it can show on a locked screen.  One fixed identifier
/// means a newer handoff replaces the notification instead of stacking up, and
/// the app can withdraw it once the item is open or gone.
nonisolated enum EditHandoffNotification {

    static let identifier = "com.northcutt.PicStrip.edit-handoff"

    /// When the handoff stops being eligible for import, in seconds since 1970.
    /// Lets the app tell an item that expired from one it already opened.
    static let expiryKey = "expires"

    /// Long enough for the sheet to close, so the banner shows over the host app.
    static let delay: TimeInterval = 0.5

    static func content(isVideo: Bool, expires: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Ready to Edit", comment: "Notification title after a photo or video was handed to PicStrip from the share sheet")
        content.body = isVideo
            ? String(localized: "Tap to open your video in PicStrip.", comment: "Notification body; the video is not named or shown")
            : String(localized: "Tap to open your photo in PicStrip.", comment: "Notification body; the photo is not named or shown")
        content.sound = .default
        content.userInfo = [expiryKey: expires.timeIntervalSince1970]
        return content
    }

    /// Asks for permission the first time, then posts.  `false` when
    /// notifications are off or the request failed: the caller then tells the
    /// user to open PicStrip themselves.
    @concurrent
    static func post(isVideo: Bool, expires: Date) async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return false
        @unknown default:
            return false
        }
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content(isVideo: isVideo, expires: expires),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        )
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    /// Withdraws the notification, delivered or still waiting to be.
    static func remove() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func expiry(of userInfo: [AnyHashable: Any]) -> Date? {
        (userInfo[expiryKey] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
    }

    /// Whether the item a tapped notification announced has expired.  Without
    /// an expiry the app just looks for the handoff.
    static func hasExpired(_ expires: Date?, now: Date = Date()) -> Bool {
        guard let expires else { return false }
        return now >= expires
    }
}

// MARK: - EditHandoff

/// The app's side of the handoff: takes what an extension left, and keeps the
/// notification from outliving it.
nonisolated enum EditHandoff {

    /// The oldest pending item.  The notification is withdrawn once an item is
    /// taken, and whenever nothing is left, so it never leads to an item that
    /// is gone.
    static func take(
        from store: PrivateFileStore?,
        movingVideosTo videos: PrivateFileStore = .exports,
        now: Date = Date(),
        withdraw: () -> Void = EditHandoffNotification.remove
    ) -> PrivateFileStore.PendingEdit? {
        guard let store else { return nil }
        let pending = store.consume(movingVideosTo: videos, now: now)
        if pending != nil || store.isEmpty { withdraw() }
        return pending
    }

    /// The expiry sweep: an item that expired takes its notification with it.
    static func removeExpired(
        from store: PrivateFileStore?,
        now: Date = Date(),
        withdraw: () -> Void = EditHandoffNotification.remove
    ) {
        guard let store else { return }
        store.removeExpired(now: now)
        if store.isEmpty { withdraw() }
    }
}
