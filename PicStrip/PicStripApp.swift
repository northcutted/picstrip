//
//  PicStripApp.swift
//  PicStrip
//
//  Created by Eddie Northcutt on 5/2/26.
//

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

    /// Aggregate scene phase — used to drain the app-group pending file when the
    /// app comes to the foreground regardless of how it was activated.
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Drain on every foreground transition so the image written by the
            // Share Extension is loaded even when extensionContext.open() was
            // silently blocked by the host app (e.g. Safari).
            guard newPhase == .active else { return }
            drainPendingEdit()
        }
    }

    // MARK: - URL handling

    /// Handles `picstrip://edit-from-extension` opened by the Share Extension.
    ///
    /// When the URL scheme open succeeds (e.g. when invoked from Photos), this
    /// fires immediately and `drainPendingEdit()` loads the file.  When the open
    /// is blocked (e.g. Safari), the `scenePhase` observer above provides the
    /// safety net on the next foreground transition.
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
