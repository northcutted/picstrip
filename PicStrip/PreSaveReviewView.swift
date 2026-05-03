import SwiftUI

struct PreSaveReviewView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    /// Tracks which categories are expanded — all start collapsed.
    @State private var expandedCategories: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {

                // ── Fixed summary card ──────────────────────────────────
                summaryCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                // ── Collapsible category breakdown ──────────────────────
                if let metadata = viewModel.pendingStrippedMetadata, !metadata.isEmpty {
                    // Order categories by the canonical categoryMap order, same as the badge row.
                    let ordered = ImageProcessor.categoryMap.compactMap { entry -> (category: String, fields: [MetadataField])? in
                        let fields = metadata.fields.filter { $0.category == entry.category }
                        guard !fields.isEmpty else { return nil }
                        return (entry.category, fields)
                    }
                    List {
                        ForEach(ordered, id: \.category) { group in
                            categorySection(group.category, fields: group.fields)
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    Spacer()
                    emptyMetadataState
                    Spacer()
                }
            }
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
            .onChange(of: viewModel.showPreSaveReview) { _, newValue in
                if !newValue { dismiss() }
            }
        }
    }

    // MARK: - Summary card

    @ViewBuilder
    private var summaryCard: some View {
        VStack(spacing: 12) {

            if let metadata = viewModel.pendingStrippedMetadata {
                HStack(spacing: 10) {
                    Image(systemName: "shield.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    if metadata.isEmpty {
                        Text("No private metadata found")
                            .font(.subheadline.weight(.semibold))
                    } else {
                        Text("\(metadata.fields.count) field\(metadata.fields.count == 1 ? "" : "s") will be removed")
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
            }

            if viewModel.isProcessing {
                HStack {
                    Spacer()
                    ProgressView("Saving…")
                    Spacer()
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    Button {
                        Task { await viewModel.saveToPhotos(replacing: false) }
                    } label: {
                        Label("Save as New Photo", systemImage: "plus.square.on.square")
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
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Collapsible category section

    private func categorySection(_ category: String, fields: [MetadataField]) -> some View {
        let isExpanded = expandedCategories.contains(category)
        let color = metadataIconColor(for: category)

        return Section {
            if isExpanded {
                // Description callout — same as CategoryDetailPanel
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.top, 1)
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
                        // Color accent bar
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
                    // Icon
                    Image(systemName: metadataIconName(for: category))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 20)

                    // Name
                    Text(category)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)

                    // Field count badge
                    Text("\(fields.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.12), in: Capsule())

                    Spacer()

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(duration: 0.25), value: isExpanded)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)  // prevent List from uppercasing section headers
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

// MARK: - Preview

#Preview {
    PreSaveReviewView(viewModel: ScrubberViewModel())
}
