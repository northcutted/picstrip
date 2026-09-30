import SwiftUI
import UIKit

struct PreSaveReviewView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    /// Tracks which categories are expanded — all start collapsed.
    @State private var expandedCategories: Set<String> = []
    @State private var showAdvanced: Bool = false
    @State private var showFullPreview = false
    /// `true` while the preview is held down to show the original.
    @GestureState private var isComparing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var auditURL: URL?

    // MARK: - Derived counts (source of truth: original image only)

    /// Privacy fields from the *original* image that will be stripped —
    /// structural fields (PixelWidth, Orientation, etc.) are excluded at this
    /// level so they never appear in counts or expanded rows.
    private var originalOrdered: [(category: String, fields: [MetadataField])] {
        guard let source = viewModel.allSourceMetadata, !source.isEmpty else { return [] }
        return ImageProcessor.categoryMap.compactMap { entry in
            let fields = source.fields.filter {
                $0.category == entry.category && viewModel.isRemoved($0)
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
            // Separate rows keep review controls reachable at every text size.
            List {
                // Full summary + save card
                Section {
                    summaryCard
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section { ScanCoverageView(viewModel: viewModel) }
                Section { sharingActions }

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryShareAction
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.bar)
            }
            .sensoryFeedback(.success, trigger: viewModel.canExport) { _, ready in ready && !reduceMotion }
            .navigationTitle("Review & Share")
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
            .fullScreenCover(isPresented: $showFullPreview) {
                if let data = viewModel.processedData {
                    ReviewPreviewView(data: data, original: viewModel.sourceUIImage)
                }
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(
                get: { auditURL != nil },
                set: { if !$0 { clearAudit() } }
            )) {
                if let url = auditURL {
                    ActivityView(activityItems: [url], onCompletion: { _ in clearAudit() })
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
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "shield.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                }

                if totalRemovalCount == 0 {
                    Text("No changes selected")
                        .font(.subheadline.weight(.semibold))
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your sharing summary")
                            .font(.subheadline.weight(.semibold))

                        if viewModel.sharingSummary.locationRemoved {
                            Label("Location removed", systemImage: "location.slash")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .labelStyle(ReviewLabelStyle())
                                .accessibilityIdentifier("locationRemovedLabel")
                        }

                        if originalMetadataCount > 0 {
                            Label(
                                "^[\(originalMetadataCount) privacy field](inflect: true) stripped",
                                systemImage: "tag.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(ReviewLabelStyle())
                        }

                        if visualRedactionCount > 0 {
                            Label(
                                "^[\(visualRedactionCount) visual region](inflect: true) redacted",
                                systemImage: "eye.slash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(ReviewLabelStyle())
                        }

                        Label("Processed on your device", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(ReviewLabelStyle())
                    }
                }

                Spacer()
            }

            if let previewImage {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Final preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("savePreviewLabel")

                    comparablePreview(previewImage)
                    if viewModel.sourceUIImage != nil {
                        Text("Touch and hold to compare with the original")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                    Button {
                        showFullPreview = true
                    } label: {
                        Label("Inspect full image", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(ReviewLabelStyle())
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inspectFullImageButton")
                }
            }

        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The cleaned image, or — only while it is held down — the original, so the
    /// difference is one gesture away but never the resting state.
    private func comparablePreview(_ cleaned: UIImage) -> some View {
        let original = viewModel.sourceUIImage
        let showsOriginal = isComparing && original != nil
        return Image(uiImage: showsOriginal ? original ?? cleaned : cleaned)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: 290)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                if showsOriginal {
                    Text("Original")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // Holding, not a quick touch: scrolling past the preview must not
                // flash the original.
                LongPressGesture(minimumDuration: 0.2)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($isComparing) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    },
                isEnabled: original != nil
            )
            .sensoryFeedback(.selection, trigger: isComparing)
            .accessibilityLabel(showsOriginal ? "Original" : "Final preview")
            .accessibilityHint(original != nil ? "Touch and hold to compare with the original" : "")
            .accessibilityIdentifier("savePreviewImage")
    }

    @ViewBuilder
    private var primaryShareAction: some View {
        if let processed = viewModel.shareImage {
            ShareLink(
                item: processed,
                preview: SharePreview(
                    "Scrubbed Image",
                    image: previewImage.map { Image(uiImage: $0) } ?? Image(systemName: "photo")
                )
            ) {
                Label("Share cleaned image", systemImage: "square.and.arrow.up")
                    .labelStyle(ReviewLabelStyle())
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("shareCleanedImageButton")
            .disabled(!viewModel.canExport)
        }
    }

    @ViewBuilder
    private var sharingActions: some View {
        VStack(spacing: 12) {
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
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("saveAsNewPhotoButton")
                    .disabled(!viewModel.canExport)

                    // Only library photos have an original to replace; images from
                    // Files, drag and drop, paste, or the Share Extension do not.
                    if viewModel.canReplaceOriginal {
                        Button(role: .destructive) {
                            Task { await viewModel.saveToPhotos(replacing: true) }
                        } label: {
                            Label("Replace Original", systemImage: "arrow.triangle.2.circlepath")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .tint(.red)
                        .disabled(!viewModel.canExport)
                    }

                    DisclosureGroup("Report details") {
                        Text("This report contains field names and counts, never the original metadata values or detected text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Export Findings (JSON)") {
                            auditURL = viewModel.generateAuditJSON()
                        }
                        .frame(minHeight: 44)
                    }
                    .font(.footnote)

                    if viewModel.livePhotoItem != nil {
                        livePhotoMotionToggle
                    }

                    if originalMetadataCount > 0, !(viewModel.keepsLivePhotoMotion && viewModel.canKeepLivePhotoMotion) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text("The cleaned copy is a still image. Keep your original if you need Live Photo motion or editing history.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("The cleaned copy is a still image. Keep your original if you need Live Photo motion or editing history.")
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Live Photo motion

    private var livePhotoMotionToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep Live Photo motion", isOn: $viewModel.keepsLivePhotoMotion)
                .font(.subheadline)
                .disabled(!viewModel.canKeepLivePhotoMotion)
                .accessibilityIdentifier("keepLivePhotoMotionToggle")
            Text(viewModel.canKeepLivePhotoMotion
                 ? "Saved with its hidden details removed. The motion is not covered, so check it shows nothing private."
                 : "Only without covered details, and not as PNG: the motion would still show them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
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

                    Text(metadataCategoryDisplayName(for: category))
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
            .accessibilityLabel(Text(verbatim: metadataCategoryDisplayName(for: category)))
            .accessibilityValue(
                isExpanded
                    ? "^[\(fields.count) field](inflect: true), expanded"
                    : "^[\(fields.count) field](inflect: true), collapsed"
            )
            .accessibilityHint(isExpanded ? "Double tap to collapse" : "Double tap to expand")
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
                    if let confidence = summary.confidence {
                        Text(confidence.matchLabel)
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
            Text("Check the photo before sharing. Automatic detection can miss details.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func clearAudit() {
        PrivateFileStore.exports.remove(auditURL)
        auditURL = nil
    }
}

// MARK: - ActivityView

/// Thin wrapper around `UIActivityViewController` for presenting the iOS share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var onCompletion: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onCompletion(completed) }
        return controller
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

/// At accessibility sizes, decorative icons should not consume the text column.
private struct ReviewLabelStyle: LabelStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            configuration.title
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
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
