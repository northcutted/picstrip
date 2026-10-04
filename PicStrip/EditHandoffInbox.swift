import Foundation
import Observation
import UserNotifications

// MARK: - EditHandoffInbox

/// Hears about the "Ready to Edit" notification an extension posts after
/// handing an item over (see `EditHandoffNotification`), and tells
/// `PicStripApp`, which owns the drain.
///
/// The notification center's delegate, set in `PicStripApp.init()`: a tap can
/// launch the app, and the response is only delivered to a delegate that is in
/// place before launch finishes.
@Observable
@MainActor
final class EditHandoffInbox: NSObject, UNUserNotificationCenterDelegate {

    /// A tap the app has not handled yet.  A pending value rather than an
    /// event, because on a cold launch it arrives before the scene exists.
    struct Tap: Equatable {
        let id = UUID()
        /// When the item the notification announced stops being eligible.
        let expires: Date?
    }

    private(set) var tap: Tap?

    /// Bumped when the notification fires while PicStrip is frontmost — the
    /// share sheet was opened from PicStrip itself — so the app opens the item
    /// without showing a banner for it.
    private(set) var foregroundArrivals = 0

    func tapHandled() {
        tap = nil
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        if request.identifier == EditHandoffNotification.identifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let expires = EditHandoffNotification.expiry(of: request.content.userInfo)
            Task { @MainActor in self.tap = Tap(expires: expires) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.identifier == EditHandoffNotification.identifier else {
            completionHandler([.banner, .list, .sound])
            return
        }
        Task { @MainActor in self.foregroundArrivals += 1 }
        completionHandler([])
    }
}
