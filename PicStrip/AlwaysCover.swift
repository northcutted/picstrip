import Foundation
import Observation
import SwiftUI

// MARK: - AlwaysCoverList

/// Words and phrases the user wants covered in every photo — their name, a
/// plate, a street — wherever PicStrip can read them.
///
/// The one thing PicStrip keeps between launches, so it is kept narrowly: a
/// single file in the app's own container, encrypted while the phone is locked,
/// left out of backups, and never shared with the extension or sent anywhere.
@Observable
@MainActor
final class AlwaysCoverList {

    static let shared = AlwaysCoverList(fileURL: AlwaysCoverList.defaultFileURL)

    /// In the order the user added them.
    private(set) var terms: [String] = []

    /// `nil` keeps the list in memory only (tests, previews).
    @ObservationIgnored private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        terms = Self.load(from: fileURL)
    }

    /// Between 2 and 60 characters with at least one letter or digit: shorter
    /// would cover half the photo, longer is never read on one line.
    nonisolated static func isValid(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...60).contains(trimmed.count) && trimmed.contains { $0.isLetter || $0.isNumber }
    }

    /// Adds `term` unless it is invalid or already listed (ignoring case);
    /// returns whether it was added.
    @discardableResult
    func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(trimmed),
              !terms.contains(where: { $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return false }
        terms.append(trimmed)
        save()
        return true
    }

    func remove(atOffsets offsets: IndexSet) {
        terms.remove(atOffsets: offsets)
        save()
    }

    // MARK: Storage

    private static var defaultFileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AlwaysCover.json")
    }

    private static func load(from url: URL?) -> [String] {
        guard let url, let data = try? Data(contentsOf: url),
              let terms = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return terms.filter(isValid)
    }

    private func save() {
        guard var url = fileURL else { return }
        do {
            if terms.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }
            try JSONEncoder().encode(terms).write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // The list still works for this session; it just is not remembered.
        }
    }
}

// MARK: - AlwaysCoverView

/// Adds and removes Always Cover words and phrases.
struct AlwaysCoverView: View {
    @Bindable var list: AlwaysCoverList
    @Environment(\.dismiss) private var dismiss
    @State private var newTerm = ""
    @FocusState private var isAdding: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a word or phrase", text: $newTerm)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($isAdding)
                            .onSubmit(add)
                            .accessibilityIdentifier("alwaysCoverField")
                        Button("Add", action: add)
                            .disabled(!AlwaysCoverList.isValid(newTerm))
                            .accessibilityIdentifier("alwaysCoverAddButton")
                    }
                } footer: {
                    Text("PicStrip covers these wherever it can read them: in the editor, in batches and in the live camera. Your name, a license plate or your street, for example.")
                }

                if !list.terms.isEmpty {
                    Section("Always Cover") {
                        ForEach(list.terms, id: \.self) { term in
                            Label(term, systemImage: PIIType.alwaysCover.symbolName)
                        }
                        .onDelete { list.remove(atOffsets: $0) }
                    }
                }

                Section {
                    Label("Kept only on this device, encrypted while it is locked and left out of backups.", systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Always Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !list.terms.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
        }
    }

    private func add() {
        if list.add(newTerm) { newTerm = "" }
        isAdding = true
    }
}
