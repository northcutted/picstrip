import AppIntents

// MARK: - ExportFormat + AppEnum
//
// This file is compiled only in the main app target (PicStrip/).
// The Share Extension has its own ExportPreset.swift copy in
// PicStripShareExtension/ and does NOT link AppIntents.

extension ExportFormat: AppEnum {

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Export Format")
    }

    nonisolated static var caseDisplayRepresentations: [ExportFormat: DisplayRepresentation] {
        [
            .png:      DisplayRepresentation(
                title: "PNG",
                subtitle: "Maximum privacy — no format headers"
            ),
            .jpeg:     DisplayRepresentation(
                title: "JPEG",
                subtitle: "Reduced file size, standard compatibility"
            ),
            .heic:     DisplayRepresentation(
                title: "HEIC",
                subtitle: "High efficiency, Apple native"
            ),
            .original: DisplayRepresentation(
                title: "Match Original",
                subtitle: "Keeps original format"
            ),
        ]
    }
}
