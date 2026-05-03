import SwiftUI

// MARK: - Shared category styling helpers

func metadataIconName(for category: String) -> String {
    switch category {
    case "GPS":               return "location.fill"
    case "EXIF":              return "camera.fill"
    case "EXIF Auxiliary":    return "camera.aperture"
    case "TIFF":              return "doc.richtext"
    case "IPTC":              return "person.text.rectangle"
    case "Apple Maker Note":  return "apple.logo"
    default:                  return "tag.fill"
    }
}

func metadataIconColor(for category: String) -> Color {
    switch category {
    case "GPS":               return .red
    case "EXIF":              return .blue
    case "EXIF Auxiliary":    return .indigo
    case "TIFF":              return .orange
    case "IPTC":              return .purple
    case "Apple Maker Note":  return .primary
    default:                  return .secondary
    }
}

/// Plain-English description of what a metadata category contains and why it's a privacy risk.
func metadataCategoryDescription(for category: String) -> String {
    switch category {
    case "GPS":
        return "The precise location where this photo was taken — latitude, longitude, and altitude. Sharing it reveals where you live, work, or travel, and can be used to track your movements over time."
    case "EXIF":
        return "Camera settings, the exact date and time the photo was taken, and your device model. The timestamp can expose your daily routine; the device model identifies your phone or camera."
    case "EXIF Auxiliary":
        return "Lens details, flash status, and other technical data recorded by your camera app. Low direct privacy risk, but still unnecessary information to share with strangers."
    case "TIFF":
        return "Low-level image properties including software version, color profile, and copyright strings — which sometimes contain your real name or organisation."
    case "IPTC":
        return "Publishing and editorial metadata: captions, credit lines, keywords, and contact information. Often contains your name, job title, or email address."
    case "Apple Maker Note":
        return "Private diagnostic data embedded by Apple's Camera app. The exact contents are not publicly documented but may include device identifiers and shooting conditions."
    default:
        return "Additional metadata embedded in this image that may contain private or identifying information."
    }
}

// MARK: - MetadataBadgeRow

/// A horizontally scrolling row of coloured pill badges — one per detected metadata category.
///
/// - `onPhoto`: When `true`, renders for a dark photo background (white text, opaque fill).
///   Badges are not tappable in this mode.
/// - `selectedCategory`: When provided, tapping a badge selects/deselects it (off-photo only).
struct MetadataBadgeRow: View {

    let metadata: StrippedMetadata
    var onPhoto: Bool = false
    var selectedCategory: Binding<String?>? = nil

    /// Categories present in the metadata, in canonical display order, with field counts.
    private var presentCategories: [(category: String, count: Int)] {
        ImageProcessor.categoryMap.compactMap { entry in
            let count = metadata.fields.filter { $0.category == entry.category }.count
            guard count > 0 else { return nil }
            return (entry.category, count)
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(presentCategories, id: \.category) { item in
                    badge(category: item.category, count: item.count)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func badge(category: String, count: Int) -> some View {
        let color = metadataIconColor(for: category)
        let isSelected = selectedCategory?.wrappedValue == category
        let interactive = !onPhoto && selectedCategory != nil

        return Button {
            guard interactive else { return }
            if isSelected {
                selectedCategory?.wrappedValue = nil
            } else {
                selectedCategory?.wrappedValue = category
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: metadataIconName(for: category))
                    .font(.system(size: 10, weight: .semibold))
                Text(category)
                    .font(.system(size: 11, weight: .semibold))
                // Count bubble
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        onPhoto
                            ? Color.white.opacity(0.25)
                            : (isSelected ? color.opacity(0.25) : color.opacity(0.18)),
                        in: Capsule()
                    )
                // Selected indicator
                if isSelected {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .foregroundStyle(onPhoto ? .white : (isSelected ? color : color))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                onPhoto
                    ? color.opacity(0.75)
                    : (isSelected ? color.opacity(0.18) : color.opacity(0.10)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? color.opacity(0.6) : color.opacity(0.22),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(onPhoto)
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

// MARK: - MetadataFieldListView

/// Embeddable list of stripped metadata fields grouped by category.
/// Designed to be placed inside a `List` or `ScrollView`.
struct MetadataFieldListView: View {

    let metadata: StrippedMetadata

    var body: some View {
        if metadata.isEmpty {
            emptyState
        } else {
            ForEach(metadata.byCategory, id: \.category) { group in
                Section(header: categoryHeader(group.category)) {
                    ForEach(group.fields) { field in
                        fieldRow(field)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("No Private Metadata Found")
                .font(.headline)
            Text("This image contained no EXIF, GPS, or other private metadata.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func categoryHeader(_ category: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: metadataIconName(for: category))
                .font(.caption)
                .foregroundStyle(metadataIconColor(for: category))
            Text(category)
        }
    }

    private func fieldRow(_ field: MetadataField) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.key)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(field.value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Previews

#Preview("Badge row — interactive") {
    @Previewable @State var selected: String? = nil
    let metadata = StrippedMetadata(fields: [
        MetadataField(category: "GPS",  key: "GPSLatitude",      value: "37.33"),
        MetadataField(category: "GPS",  key: "GPSLongitude",     value: "-122.03"),
        MetadataField(category: "EXIF", key: "DateTimeOriginal", value: "2024:06:15"),
        MetadataField(category: "TIFF", key: "Software",         value: "17.0"),
    ])
    VStack(spacing: 24) {
        MetadataBadgeRow(metadata: metadata, onPhoto: false, selectedCategory: $selected)
        Text("Selected: \(selected ?? "none")").font(.caption).foregroundStyle(.secondary)
    }
    .padding()
}

#Preview("Badge row — on photo") {
    ZStack {
        Color.black
        MetadataBadgeRow(metadata: StrippedMetadata(fields: [
            MetadataField(category: "GPS",  key: "GPSLatitude", value: "37.33"),
            MetadataField(category: "EXIF", key: "Make",        value: "Apple"),
        ]), onPhoto: true)
    }
    .frame(height: 60)
}

#Preview("Field list") {
    List {
        MetadataFieldListView(metadata: StrippedMetadata(fields: [
            MetadataField(category: "GPS",  key: "GPSLatitude",      value: "37.3317"),
            MetadataField(category: "GPS",  key: "GPSLongitude",     value: "-122.0307"),
            MetadataField(category: "EXIF", key: "DateTimeOriginal", value: "2024:06:15 14:32:01"),
            MetadataField(category: "EXIF", key: "Make",             value: "Apple"),
            MetadataField(category: "TIFF", key: "Software",         value: "17.0"),
        ]))
    }
    .listStyle(.insetGrouped)
}
