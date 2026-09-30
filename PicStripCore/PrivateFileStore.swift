import Foundation

/// Owns only its dedicated directory. Files are protected, excluded from backup,
/// given neutral unique names, and retained for a bounded handoff lifetime.
nonisolated struct PrivateFileStore: Sendable {
    let directory: URL
    var lifetime: TimeInterval = 3_600
    var maximumBytes = ImageResourceBudget.editor.maximumBytes

    static var exports: PrivateFileStore {
        PrivateFileStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PicStripExports", isDirectory: true))
    }

    static var handoffs: PrivateFileStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.northcutt.PicStrip")
            .map { PrivateFileStore(directory: $0.appendingPathComponent("PendingEdits", isDirectory: true), lifetime: 900,
                                   maximumBytes: ImageResourceBudget.shareExtension.maximumBytes) }
    }

    func write(_ data: Data, extension fileExtension: String, now: Date = Date()) throws -> URL {
        guard data.count <= maximumBytes else { throw ImageResourceBudget.AdmissionError.fileTooLarge }
        let url = try reserve(extension: fileExtension, now: now)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return url
    }

    /// A new, unused file name in the protected directory, for a writer that
    /// produces its own file (a video export).  Nothing is created at the URL.
    func reserve(extension fileExtension: String, now: Date = Date()) throws -> URL {
        let allowed = Set([
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "avif", "dng", "json", "data",
            "mov", "mp4", "m4v"
        ])
        let suffix = allowed.contains(fileExtension.lowercased()) ? fileExtension.lowercased() : "data"
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        removeExpired(now: now)
        return directory.appendingPathComponent("PicStrip-\(UUID().uuidString).\(suffix)")
    }

    /// Copies a file into the protected directory — a video handed over by the
    /// photo picker, which is too large to hold in memory.
    func copy(_ source: URL, extension fileExtension: String, now: Date = Date()) throws -> URL {
        let url = try reserve(extension: fileExtension, now: now)
        try FileManager.default.copyItem(at: source, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now, .protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
        )
        return url
    }

    func remove(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeExpired(now: Date = Date()) {
        for url in files() {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) >= 0,
                  now.timeIntervalSince(modified) < lifetime else {
                remove(url)
                continue
            }
        }
    }

    /// Consume oldest first, preserving additional pending handoffs for later.
    /// Remove before decoding, so a failed import cannot replay sensitive bytes.
    func consume(now: Date = Date()) -> Data? {
        migrateLegacyHandoff(now: now)
        removeExpired(now: now)
        let pending = files().sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left < right
        }
        for url in pending {
            let data = try? ImageResourceBudget(maximumPixels: .infinity, maximumBytes: maximumBytes).read(url)
            remove(url)
            if let data { return data }
        }
        return nil
    }

    private func migrateLegacyHandoff(now: Date) {
        guard directory.lastPathComponent == "PendingEdits" else { return }
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("pending-edit.data")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        defer { try? FileManager.default.removeItem(at: legacy) }
        guard let modified = try? legacy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) >= 0, now.timeIntervalSince(modified) < lifetime,
              let data = try? ImageResourceBudget(maximumPixels: .infinity, maximumBytes: maximumBytes).read(legacy) else { return }
        _ = try? write(data, extension: "data", now: modified)
    }

    /// Remove only the old app-generated temporary report names, never files
    /// saved by the user elsewhere or unrelated files in the temporary directory.
    static func removeLegacyReports(in root: URL = FileManager.default.temporaryDirectory) {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            for prefix in ["PicStrip_Audit_", "PicStrip_BatchAudit_"] where stem.hasPrefix(prefix) {
                if UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
