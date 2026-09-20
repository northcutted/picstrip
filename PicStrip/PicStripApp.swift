//
//  PicStripApp.swift
//  PicStrip
//
//  Created by Eddie Northcutt on 5/2/26.
//

import AppIntents
import SwiftUI

// MARK: - App Group constants (shared with PicStripShareExtension)

enum PicStripAppGroup {
    static let identifier = "group.com.northcutt.PicStrip"
    static let pendingEditFilename = "pending-edit.data"

    /// File URL for the image written by the Share Extension's "Edit in PicStrip" action.
    static var pendingEditURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent(pendingEditFilename)
    }
}

// MARK: - PicStripApp

@main
struct PicStripApp: App {

    /// Shared view model threaded into ContentView and used by the URL handler.
    @State private var viewModel = ScrubberViewModel()

    /// Receives requests from App Intents; see `IntentRouter`.
    @State private var intentRouter: IntentRouter

    init() {
        // Intents resolve `@AppDependency` values from this manager, and an intent
        // can run as soon as the process is up — so register before any scene.
        let router = IntentRouter()
        AppDependencyManager.shared.add(dependency: router)
        _intentRouter = State(initialValue: router)
    }

    /// Aggregate scene phase — used to drain the app-group pending file when the
    /// app comes to the foreground regardless of how it was activated.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environment(intentRouter)
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
        guard let fileURL = PicStripAppGroup.pendingEditURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return }

        // Delete before loading so a crash during load doesn't replay the file.
        try? FileManager.default.removeItem(at: fileURL)

        Task { @MainActor in
            await viewModel.loadData(data)
        }
    }
}
