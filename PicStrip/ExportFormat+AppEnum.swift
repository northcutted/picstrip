import AppIntents

// MARK: - ExportFormat + AppEnum
//
// This file is compiled only in the main app target (PicStrip/).
// The share extension uses the shared PicStripCore export types directly and
// does not link AppIntents.

nonisolated extension ExportFormat: AppEnum {

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: LocalizedStringResource("Export Format"))
    }

    nonisolated static var caseDisplayRepresentations: [ExportFormat: DisplayRepresentation] {
        [
            .png: DisplayRepresentation(
                title: LocalizedStringResource("PNG"),
                subtitle: LocalizedStringResource("Maximum privacy — no format headers")
            ),
            .jpeg: DisplayRepresentation(
                title: LocalizedStringResource("JPEG"),
                subtitle: LocalizedStringResource("Reduced file size, standard compatibility")
            ),
            .heic: DisplayRepresentation(
                title: LocalizedStringResource("HEIC"),
                subtitle: LocalizedStringResource("High efficiency, Apple native")
            ),
            .original: DisplayRepresentation(
                title: LocalizedStringResource("Match Original"),
                subtitle: LocalizedStringResource("Keeps original format")
            )
        ]
    }
}
