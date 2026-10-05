//
//  PicStripApp.swift
//  PicStrip
//
//  Created by Eddie Northcutt on 5/2/26.
//

import AppIntents
import SwiftUI
import UserNotifications

// MARK: - PicStripApp

@main
struct PicStripApp: App {

    /// Shared view model threaded into ContentView and used by the URL handler.
    @State private var viewModel = ScrubberViewModel()
    @State private var isDrainingHandoff = false
    @State private var privacyShield = AppPrivacyShield()

    /// Receives requests from App Intents; see `IntentRouter`.
    @State private var intentRouter: IntentRouter

    /// Taps on the notification an extension posts after "Edit in PicStrip".
    @State private var handoffInbox: EditHandoffInbox

    init() {
        // Intents resolve `@AppDependency` values from this manager, and an intent
        // can run as soon as the process is up — so register before any scene.
        let router = IntentRouter()
        AppDependencyManager.shared.add(dependency: router)
        _intentRouter = State(initialValue: router)
        // A tap that launches the app is delivered only to a delegate set
        // before launch finishes.
        let inbox = EditHandoffInbox()
        UNUserNotificationCenter.current().delegate = inbox
        _handoffInbox = State(initialValue: inbox)
        Task.detached {
            PrivateFileStore.exports.removeExpired()
            PrivateFileStore.removeLegacyReports()
            EditHandoff.removeExpired(from: PrivateFileStore.handoffs)
        }
    }

    /// Aggregate scene phase — used to drain the app-group pending file when the
    /// app comes to the foreground regardless of how it was activated.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environment(intentRouter)
                // At most once a session, after a clean success; see `ReviewPromptGate`.
                .requestsReview(when: viewModel.reviewPrompt)
                .transaction { transaction in
                    if reduceMotion {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    privacyShield.conceal()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    privacyShield.reveal()
                }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        guard !Task.isCancelled else { return }
                        await Self.removeExpiredFiles()
                    }
                }
                .onChange(of: viewModel.sourceUIImage == nil) { _, empty in
                    if empty { drainPendingEdit() }
                }
                .onChange(of: handoffInbox.tap, initial: true) { _, tap in
                    openTappedHandoff(tap)
                }
                .onChange(of: handoffInbox.foregroundArrivals) {
                    drainPendingEdit()
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // An extension cannot open the app (extensions may not call `open`),
            // so "Edit in PicStrip" leaves the image or video in the App Group and
            // posts a notification; tapping it, or opening PicStrip any other
            // way, brings the app here, where every foreground transition
            // picks the item up.
            guard newPhase == .active else { return }
            drainPendingEdit()
        }
    }

    // MARK: - URL handling

    /// Handles `picstrip://edit-from-extension`.
    ///
    /// Nothing in PicStrip opens this URL today — the Share Extension relies on
    /// its notification and the `scenePhase` drain above — but the scheme stays
    /// registered so a shortcut can bring the pending image up directly.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "picstrip",
              url.host?.lowercased() == "edit-from-extension"
        else { return }

        drainPendingEdit()
    }

    // MARK: - App group drain

    /// A tap on the "Ready to Edit" notification.  The activation it caused
    /// has usually opened the item already; drain again in case it has not.
    /// The handoff is deleted when it expires, so say so rather than open to
    /// an empty screen.
    private func openTappedHandoff(_ tap: EditHandoffInbox.Tap?) {
        guard let tap else { return }
        handoffInbox.tapHandled()
        guard EditHandoffNotification.hasExpired(tap.expires) else {
            drainPendingEdit()
            return
        }
        // Like a failed load: the alert shows when no photo is open.
        if viewModel.sourceUIImage == nil, !viewModel.isProcessing {
            viewModel.errorMessage = String(
                localized: "That item expired. Share it to PicStrip again.",
                comment: "Shown when the notification is tapped after the 15-minute handoff expired"
            )
        }
    }

    /// Takes the oldest image or video an extension left in the app group
    /// container: an image is loaded into the editor, a video opened in the
    /// video cleaner (`ContentView` waits if another video is open there).
    ///
    /// Safe to call multiple times — `isDrainingHandoff` lets one run at a time.
    private func drainPendingEdit() {
        // Never replace an in-progress edit with another queued handoff.
        guard !isDrainingHandoff, viewModel.sourceUIImage == nil,
              !viewModel.isProcessing, !viewModel.showResizeOffer,
              intentRouter.requestedVideo == nil else { return }
        isDrainingHandoff = true
        Task { @MainActor in
            defer { isDrainingHandoff = false }
            switch await Self.takePendingEdit() {
            case .image(let data): await viewModel.loadData(data)
            case .video(let url): intentRouter.requestVideo(url)
            case nil: break
            }
        }
    }

    /// The oldest pending handoff; its notification is withdrawn with it.
    /// This lists the App Group folder and reads the file on every activation,
    /// so it runs off the main actor.
    @concurrent
    nonisolated private static func takePendingEdit() async -> PrivateFileStore.PendingEdit? {
        EditHandoff.take(from: PrivateFileStore.handoffs)
    }

    /// The periodic sweep of expired exports and handoffs, off the main actor.
    @concurrent
    nonisolated private static func removeExpiredFiles() async {
        PrivateFileStore.exports.removeExpired()
        EditHandoff.removeExpired(from: PrivateFileStore.handoffs)
    }
}
