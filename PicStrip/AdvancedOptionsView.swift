import SwiftUI

struct AdvancedOptionsView: View {

    @Bindable var viewModel: ScrubberViewModel

    /// True when PII has been detected — used to surface the PNG recommendation.
    var hasPII: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ExportFormat.allCases.enumerated()), id: \.element.id) { index, format in
                formatRow(format)

                if index < ExportFormat.allCases.count - 1 {
                    Divider()
                        .padding(.leading, 44)
                }
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Row

    @ViewBuilder
    private func formatRow(_ format: ExportFormat) -> some View {
        let isSelected = viewModel.selectedExportFormat == format
        let showBadge  = format == .png && hasPII

        Button {
            viewModel.selectedExportFormat = format
        } label: {
            HStack(alignment: .top, spacing: 12) {

                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.green : Color.secondary)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                // Text stack
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(format.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        if showBadge {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green, in: Capsule())
                        }
                    }

                    Text(format.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(format.title)\(showBadge ? ", Recommended" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 20) {
            AdvancedOptionsView(viewModel: ScrubberViewModel(), hasPII: false)
            AdvancedOptionsView(viewModel: ScrubberViewModel(), hasPII: true)
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
}
