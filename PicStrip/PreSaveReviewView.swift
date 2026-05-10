import SwiftUI
import UIKit

struct PreSaveReviewView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    /// Tracks which categories are expanded — all start collapsed.
    @State private var expandedCategories: Set<String> = []
    @State private var showAdvanced: Bool = false
    @State private var auditURL: URL?

    // MARK: - Derived counts (source of truth: original image only)

    /// Privacy fields from the *original* image that will be stripped —
    /// structural fields (PixelWidth, Orientation, etc.) are excluded at this
    /// level so they never appear in counts or expanded rows.
    private var originalOrdered: [(category: String, fields: [MetadataField])] {
        guard let source = viewModel.allSourceMetadata, !source.isEmpty else { return [] }
        return ImageProcessor.categoryMap.compactMap { entry in
            let fields = source.fields.filter {
                $0.category == entry.category &&
                !$0.isStructural &&
                ImageProcessor.shouldReportStripped(
                    category: $0.category,
                    key: $0.key,
                    isStructural: $0.isStructural,
                    config: viewModel.stripConfig
                )
            }
            return fields.isEmpty ? nil : (entry.category, fields)
        }
    }

    private var originalMetadataCount: Int {
        originalOrdered.flatMap(\.fields).count
    }

    private var redactedRegions: [RedactionRegion] {
        viewModel.enabledRedactionRegions
    }

    private var visualRedactionCount: Int {
        redactedRegions.count
    }

    private var totalRemovalCount: Int { originalMetadataCount + visualRedactionCount }

    private var hasPII: Bool { !redactedRegions.isEmpty }

    private var previewImage: UIImage? {
        viewModel.reviewPreviewUIImage
    }

    var body: some View {
        NavigationStack {
            // ── Single scrollable List — full card (preview + save) at
            //    top, collapsible breakdown below. ──────────────────────
            List {
                // Full summary + save card
                Section {
                    summaryCard
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                // Collapsible breakdown
                if !redactedRegions.isEmpty {
                    redactionSection
                }
                if !originalOrdered.isEmpty {
                    Section("Metadata Removed") {
                        ForEach(originalOrdered, id: \.category) { group in
                            categorySection(group.category, fields: group.fields)
                        }
                    }
                }
                if originalOrdered.isEmpty && redactedRegions.isEmpty {
                    Section {
                        emptyMetadataState
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review & Save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert(
                "Original Not Found",
                isPresented: $viewModel.showReplaceUnavailableAlert
            ) {
                Button("Save as New Photo") {
                    Task { await viewModel.saveToPhotos(replacing: false) }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The original photo could not be identified. It may be stored in iCloud and not yet downloaded. Would you like to save as a new photo instead?")
            }
            .onChange(of: viewModel.activeSheet) { _, newValue in
                if newValue != .preSave { dismiss() }
            }
            .sheet(isPresented: $showAdvanced) {
                NavigationStack {
                    ScrollView {
                        AdvancedOptionsView(viewModel: viewModel, hasPII: hasPII)
                            .padding()
                    }
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle("Export Format")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showAdvanced = false }
                        }
                    }
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(
                get: { auditURL != nil },
                set: { if !$0 { auditURL = nil } }
            )) {
                if let url = auditURL {
                    ActivityView(activityItems: [url])
                        .ignoresSafeArea()
                }
            }
        }
    }

    // MARK: - Summary card (overview + preview + save actions)

    @ViewBuilder
    private var summaryCard: some View {
        VStack(spacing: 12) {

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                if totalRemovalCount == 0 {
                    Text("No sensitive data found")
                        .font(.subheadline.weight(.semibold))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Cleaning & Redacting")
                            .font(.subheadline.weight(.semibold))

                        if originalMetadataCount > 0 {
                            Label(
                                "^[\(originalMetadataCount) privacy field](inflect: true) stripped",
                                systemImage: "tag.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if visualRedactionCount > 0 {
                            Label(
                                "^[\(visualRedactionCount) visual region](inflect: true) redacted",
                                systemImage: "eye.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()
            }

            if let previewImage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(visualRedactionCount > 0 ? "Preview with redactions" : "Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("savePreviewLabel")

                    ZoomableImagePreview(
                        image: previewImage,
                        showZoomHint: false,
                        accessibilityIdentifier: "savePreviewImage"
                    )
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }

            Divider()

            if viewModel.isProcessing {
                HStack {
                    Spacer()
                    ProgressView("Saving…")
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {

                    // Export format picker — opens as a sheet to avoid List layout jump
                    Button {
                        showAdvanced = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up.on.square")
                                .font(.subheadline)
                            Text("Export Format")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(viewModel.selectedExportFormat.title)
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    Button {
                        Task { await viewModel.saveToPhotos(replacing: false) }
                    } label: {
                        Label("Save as New Photo", systemImage: "plus.square.on.square")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.white)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        Task { await viewModel.saveToPhotos(replacing: true) }
                    } label: {
                        Label("Replace Original", systemImage: "arrow.triangle.2.circlepath")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.red)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)

                    if let processed = viewModel.processedData {
                        ShareLink(
                            item: processed,
                            preview: SharePreview(
                                "Scrubbed Image",
                                image: previewImage.map { Image(uiImage: $0) } ?? Image(systemName: "photo")
                            )
                        ) {
                            Label("Share Image", systemImage: "square.and.arrow.up")
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.secondary)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(.secondary)
                    }

                    Button {
                        auditURL = viewModel.generateAuditJSON()
                    } label: {
                        Label("Export Findings (JSON)", systemImage: "doc.text.magnifyingglass")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.secondary)

                    if originalMetadataCount > 0 {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text("Metadata removal is permanent. The saved image will lose Live Photo motion data, GPS location, camera model, and editing history.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Warning: Metadata removal is permanent. The saved image will lose Live Photo motion data, GPS location, camera model, and editing history.")
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Collapsible category section

    private func categorySection(_ category: String, fields: [MetadataField]) -> some View {
        let isExpanded = expandedCategories.contains(category)
        let color      = metadataIconColor(for: category)

        return Section {
            if isExpanded {
                // Description callout — same as CategoryDetailPanel
                HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                    Text(metadataCategoryDescription(for: category))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(0.18), lineWidth: 0.5))
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                ForEach(fields) { field in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(0.5))
                            .frame(width: 3)
                            .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field.key)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(field.value)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        } header: {
            Button {
                withAnimation(.spring(duration: 0.3, bounce: 0.1)) {
                    if isExpanded {
                        expandedCategories.remove(category)
                    } else {
                        expandedCategories.insert(category)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: metadataIconName(for: category))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 20)
                        .accessibilityHidden(true)

                    Text(category)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(color)

                    Text("\(fields.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12), in: Capsule())

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(duration: 0.25), value: isExpanded)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .accessibilityLabel("\(category), \(fields.count) field\(fields.count == 1 ? "" : "s"), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
        }
    }

    // MARK: - Visual Redactions section

    @ViewBuilder
    private var redactionSection: some View {
        Section("Visual Redactions") {
            ForEach(redactionSummaries, id: \.name) { summary in
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(summary.name)
                        .foregroundStyle(.primary)
                    Spacer()
                    if let confidence = summary.confidence, let score = summary.score {
                        Text(score, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(confidenceColor(confidence))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(confidenceColor(confidence).opacity(0.10), in: Capsule())
                    }
                    Text("^[\(summary.count) region](inflect: true)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var redactionSummaries: [RedactionSummary] {
        Dictionary(grouping: redactedRegions, by: \.displayName)
            .map { name, regions in
                let strongest = regions.compactMap(\.score).max()
                return RedactionSummary(
                    name: name,
                    count: regions.count,
                    score: strongest
                )
            }
            .sorted { $0.name < $1.name }
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        }
    }

    // MARK: - Empty state

    private var emptyMetadataState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Image is already clean")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ActivityView

/// Thin wrapper around `UIActivityViewController` for presenting the iOS share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

private struct RedactionSummary {
    let name: String
    let count: Int
    let score: Double?

    var confidence: ConfidenceLevel? {
        score.map(ConfidenceLevel.init(score:))
    }

}

// MARK: - Preview

#Preview {
    PreSaveReviewView(viewModel: ScrubberViewModel())
}
