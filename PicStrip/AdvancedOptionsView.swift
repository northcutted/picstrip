import SwiftUI

struct AdvancedOptionsView: View {

    @Bindable var viewModel: ScrubberViewModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ExportPreset.allCases) { preset in
                Button {
                    viewModel.selectedPreset = preset
                } label: {
                    HStack(spacing: 12) {
                        // Format icon
                        Image(systemName: iconName(for: preset))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(viewModel.selectedPreset == preset ? Color.accentColor : .secondary)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                                .font(.subheadline)
                                .fontWeight(viewModel.selectedPreset == preset ? .semibold : .regular)
                                .foregroundStyle(.primary)
                            Text(preset.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if viewModel.selectedPreset == preset {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if preset != ExportPreset.allCases.last {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func iconName(for preset: ExportPreset) -> String {
        switch preset {
        case .matchSource:     return "doc.badge.arrow.up"
        case .highQualityJPEG: return "photo"
        case .webFriendlyJPEG: return "globe"
        case .losslessPNG:     return "lasso.badge.sparkles"
        case .heicOriginal:    return "apple.logo"
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        AdvancedOptionsView(viewModel: ScrubberViewModel())
            .padding()
    }
    .background(Color(.systemGroupedBackground))
}
