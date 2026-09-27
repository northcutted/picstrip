//
//  PicStripApp.swift
//  PicStrip
//
//  Created by Eddie Northcutt on 5/2/26.
//

import AppIntents
import SwiftUI

// MARK: - PicStripApp

@main
struct PicStripApp: App {

    /// Shared view model threaded into ContentView and used by the URL handler.
    @State private var viewModel = ScrubberViewModel()
    @State private var isDrainingHandoff = false
    @State private var privacyShield = AppPrivacyShield()

    /// Receives requests from App Intents; see `IntentRouter`.
    @State private var intentRouter: IntentRouter

    init() {
        // Intents resolve `@AppDependency` values from this manager, and an intent
        // can run as soon as the process is up — so register before any scene.
        let router = IntentRouter()
        AppDependencyManager.shared.add(dependency: router)
        _intentRouter = State(initialValue: router)
        Task.detached {
            PrivateFileStore.exports.removeExpired()
            PrivateFileStore.removeLegacyReports()
            PrivateFileStore.handoffs?.removeExpired()
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
                        PrivateFileStore.exports.removeExpired()
                        PrivateFileStore.handoffs?.removeExpired()
                    }
                }
                .onChange(of: viewModel.sourceUIImage == nil) { _, empty in
                    if empty { drainPendingEdit() }
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // The Share Extension cannot open the app (extensions may not call
            // `open`), so it leaves the image in the App Group and the app picks
            // it up here, on every foreground transition.
            guard newPhase == .active else { return }
            drainPendingEdit()
        }
    }

    // MARK: - URL handling

    /// Handles `picstrip://edit-from-extension`.
    ///
    /// Nothing in PicStrip opens this URL today — the Share Extension relies on
    /// the `scenePhase` drain above — but the scheme stays registered so a
    /// shortcut or a future extension can bring the pending image up directly.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "picstrip",
              url.host?.lowercased() == "edit-from-extension"
        else { return }

        drainPendingEdit()
    }

    // MARK: - App group drain

    /// Reads and clears any image left by the Share Extension in the app group
    /// container, then loads it into the view model.
    ///
    /// Safe to call multiple times — the `fileExists` guard makes it idempotent.
    private func drainPendingEdit() {
        // Never replace an in-progress edit with another queued handoff.
        guard !isDrainingHandoff, viewModel.sourceUIImage == nil,
              !viewModel.isProcessing, !viewModel.showResizeOffer,
              let data = PrivateFileStore.handoffs?.consume() else { return }
        isDrainingHandoff = true
        Task { @MainActor in
            defer { isDrainingHandoff = false }
            await viewModel.loadData(data)
        }
    }
}
