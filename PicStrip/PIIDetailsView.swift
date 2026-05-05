import SwiftUI

/// Half-sheet presenting all detected PII results.
///
/// Each row has two independent interaction zones:
///   - Leading/middle content area: tap to highlight bounding boxes on the image.
///   - Trailing: a checkmark circle that toggles the type in/out of `typesToRedact`.
struct PIIDetailsView: View {

    @Bindable var viewModel: ScrubberViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.detectedPII) { result in
                        resultRow(result)
                            .listRowBackground(
                                viewModel.selectedPIIResult == result
                                    ? Color.accentColor.opacity(0.1)
                                    : Color(UIColor.secondarySystemGroupedBackground)
                            )
                    }
                } header: {
                    let allSelected = viewModel.detectedPII.allSatisfy {
                        viewModel.typesToRedact.contains($0.type)
                    }
                    HStack {
                        Text("Detected Data")
                        Spacer()
                        Button(allSelected ? "Deselect All" : "Redact All") {
                            if allSelected {
                                viewModel.typesToRedact.removeAll()
                            } else {
                                viewModel.typesToRedact = Set(viewModel.detectedPII.map(\.type))
                            }
                        }
                        .textCase(.none)
                        .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Tap a row to locate the detection in the image. Selected items will be permanently blacked out on the exported image.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Detected Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { viewModel.activeSheet = nil }
                }
            }
        }
        .presentationDetents([.fraction(0.35), .medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    // MARK: - Row

    @ViewBuilder
    private func resultRow(_ result: DetectionResult) -> some View {
        let isRedacted = viewModel.typesToRedact.contains(result.type)

        HStack(spacing: 12) {

            // ── Leading: content area (tap → spatial highlight) ─────────
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    viewModel.selectedPIIResult = (viewModel.selectedPIIResult == result) ? nil : result
                }
            } label: {
                HStack(spacing: 12) {

                    // Confidence icon
                    Image(systemName: confidenceIcon(result.confidence))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(confidenceColor(result.confidence))
                        .frame(width: 26)
                        .accessibilityHidden(true)

                    // Labels
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.type.description)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)

                        if let snippet = result.instances.first?.snippet, !snippet.isEmpty {
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        Text("\(result.scorePercent)% match")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(confidenceColor(result.confidence))
                    }

                    Spacer(minLength: 4)

                    // Match count badge
                    if result.matchCount > 1 {
                        Text("\(result.matchCount)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                    }

                    // Scope icon — active when this row is highlighted
                    Image(systemName: "scope")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            viewModel.selectedPIIResult == result
                                ? Color.accentColor
                                : Color.secondary.opacity(0.4)
                        )
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Locate \(result.type.description) in photo, \(result.scorePercent)% match")

            // ── Trailing: redaction checkmark ───────────────────────────
            Button {
                if isRedacted {
                    viewModel.typesToRedact.remove(result.type)
                } else {
                    viewModel.typesToRedact.insert(result.type)
                }
            } label: {
                Image(systemName: isRedacted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isRedacted ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(isRedacted
                ? "Remove \(result.type.description) from redaction list"
                : "Add \(result.type.description) to redaction list")
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isRedacted)
        }
    }

    // MARK: - Helpers

    private func confidenceIcon(_ level: ConfidenceLevel) -> String {
        switch level {
        case .high:   return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low:    return "info.circle.fill"
        }
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        }
    }

}
