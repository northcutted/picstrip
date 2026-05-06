import SwiftUI

/// Inline expanding panel that slides up over the bottom of the image region
/// when a metadata badge is tapped.
///
/// Shows:
///  1. A header with category icon, name, field count, and a dismiss button.
///  2. A plain-English description of what this category is and why to strip it.
///  3. A per-field toggle list — strip (default) or keep.
///  4. Bulk "Strip All" / "Keep All" convenience buttons.
struct CategoryDetailPanel: View {

    let category: String
    let fields: [MetadataField]
    @Binding var stripConfig: StripConfig
    let onDismiss: () -> Void

    private var color: Color { metadataIconColor(for: category) }
    private var supportsPreservation: Bool { ImageProcessor.canPreserveMetadata(category: category) }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            // Header
            HStack(spacing: 10) {
                Image(systemName: metadataIconName(for: category))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(category)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    let strippableCount = fields.filter { !$0.isStructural }.count
                    Text("^[\(strippableCount) field](inflect: true) found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Close \(category) details")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider().padding(.horizontal, 16)

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {

                    // Description callout
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(color)
                            .padding(.top, 1)
                            .accessibilityHidden(true)
                        Text(metadataCategoryDescription(for: category))
                            .font(.subheadline)
                            .foregroundStyle(.primary.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    // Strip All / Keep All segmented control
                    if supportsPreservation {
                        bulkSegmentedControl
                            .padding(.horizontal, 16)
                    }

                    // Per-field toggles
                    VStack(spacing: 0) {
                        ForEach(fields) { field in
                            fieldRow(field)
                            if field.id != fields.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .frame(maxHeight: 340)
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: -4)
    }

    // MARK: - Field row

    @ViewBuilder
    private func fieldRow(_ field: MetadataField) -> some View {
        if field.isStructural {
            structuralFieldRow(field)
        } else if !supportsPreservation {
            unsupportedPreservationFieldRow(field)
        } else {
            strippableFieldRow(field)
        }
    }

    /// A standard strippable field — shows a per-field toggle.
    private func strippableFieldRow(_ field: MetadataField) -> some View {
        let compoundKey = "\(category).\(field.key)"
        let isStripping = stripConfig.fieldOverrides[compoundKey] != false

        return Toggle(isOn: Binding(
            get: { isStripping },
            set: { newValue in
                if newValue {
                    stripConfig.fieldOverrides.removeValue(forKey: compoundKey)
                } else {
                    stripConfig.fieldOverrides[compoundKey] = false
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.key)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isStripping ? .primary : .secondary)
                Text(field.value)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.vertical, 8)
        }
        .tint(color)
        .padding(.horizontal, 14)
        .accessibilityLabel("Strip \(field.key)")
    }

    /// A structural field — read-only, lock icon, explanatory caption.
    private func structuralFieldRow(_ field: MetadataField) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.key)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(field.value)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Text("Standard file format header required for display. Does not contain personal data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .padding(.vertical, 8)

            Spacer()

            Image(systemName: "lock.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .opacity(0.7)
    }

    /// A privacy field in a metadata dictionary ImageIO cannot safely re-inject.
    private func unsupportedPreservationFieldRow(_ field: MetadataField) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.key)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(field.value)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Text("Cannot be preserved during safe re-encoding.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .padding(.vertical, 8)

            Spacer()

            Image(systemName: "lock.slash.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .opacity(0.7)
    }

    // MARK: - Bulk segmented control

    private var bulkSegmentedControl: some View {
        HStack(spacing: 0) {
            segment(title: "Strip All", icon: "nosign", side: .left, active: allStripping) {
                stripAll()
            }
            Divider()
                .frame(height: 28)
                .overlay(color.opacity(0.15))
            segment(title: "Keep All", icon: "checkmark", side: .right, active: noneStripping) {
                keepAll()
            }        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
        )
        .animation(.spring(duration: 0.2), value: allStripping)
        .animation(.spring(duration: 0.2), value: noneStripping)
    }

    private enum SegmentSide { case left, right }

    private func segment(
        title: String,
        icon: String,
        side: SegmentSide,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(active ? color : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                active ? color.opacity(0.13) : Color.clear,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: side == .left  ? 10 : 0,
                    bottomLeadingRadius: side == .left  ? 10 : 0,
                    bottomTrailingRadius: side == .right ? 10 : 0,
                    topTrailingRadius: side == .right ? 10 : 0
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(category) fields")
    }

    // MARK: - Bulk helpers

    private var strippableFields: [MetadataField] { fields.filter { !$0.isStructural } }

    private var allStripping: Bool {
        strippableFields.allSatisfy { field in
            stripConfig.fieldOverrides["\(category).\(field.key)"] != false
        }
    }

    private var noneStripping: Bool {
        strippableFields.allSatisfy { field in
            stripConfig.fieldOverrides["\(category).\(field.key)"] == false
        }
    }

    private func stripAll() {
        for field in strippableFields {
            stripConfig.fieldOverrides.removeValue(forKey: "\(category).\(field.key)")
        }
    }

    private func keepAll() {
        for field in strippableFields {
            stripConfig.fieldOverrides["\(category).\(field.key)"] = false
        }
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var config = StripConfig.default
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        CategoryDetailPanel(
            category: "GPS",
            fields: [
                MetadataField(category: "GPS", key: "GPSLatitude", value: "37.3317"),
                MetadataField(category: "GPS", key: "GPSLongitude", value: "-122.0307"),
                MetadataField(category: "GPS", key: "GPSAltitude", value: "25"),
                MetadataField(category: "GPS", key: "GPSImgDirection", value: "193.4"),
                MetadataField(category: "GPS", key: "GPSHPositioningError", value: "4.7")
            ],
            stripConfig: $config,
            onDismiss: {}
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}
