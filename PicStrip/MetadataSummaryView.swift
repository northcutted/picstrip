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

/// The name shown for a metadata category.
///
/// `category` is the identifier `ImageProcessor` files fields under, and it doubles
/// as the key for `StripConfig`, icons, and accessibility identifiers — so it never
/// changes.  GPS, EXIF, TIFF and IPTC are the same in every language; only the
/// names made of ordinary words are translated.
func metadataCategoryDisplayName(for category: String) -> String {
    switch category {
    case "EXIF Auxiliary":    return String(localized: "EXIF Auxiliary")
    case "Apple Maker Note":  return String(localized: "Apple Maker Note")
    case "General":           return String(localized: "General")
    default:                  return category
    }
}

/// Plain-English description of what a metadata category contains and why it's a privacy risk.
func metadataCategoryDescription(for category: String) -> String {
    switch category {
    case "GPS":
        return String(localized: "The precise location where this photo was taken — latitude, longitude, and altitude. Sharing it reveals where you live, work, or travel, and can be used to track your movements over time.")
    case "EXIF":
        return String(localized: "Camera settings, the exact date and time the photo was taken, and your device model. The timestamp can expose your daily routine; the device model identifies your phone or camera.")
    case "EXIF Auxiliary":
        return String(localized: "Lens details, flash status, and other technical data recorded by your camera app. Low direct privacy risk, but still unnecessary information to share with strangers.")
    case "TIFF":
        return String(localized: "Low-level image properties including software version, color profile, and copyright strings — which sometimes contain your real name or organisation.")
    case "IPTC":
        return String(localized: "Publishing and editorial metadata: captions, credit lines, keywords, and contact information. Often contains your name, job title, or email address.")
    case "Apple Maker Note":
        return String(localized: "Private diagnostic data embedded by Apple's Camera app. The exact contents are not publicly documented but may include device identifiers and shooting conditions.")
    default:
        return String(localized: "Additional metadata embedded in this image that may contain private or identifying information.")
    }
}

// MARK: - MetadataBadgeRow

/// A horizontally scrolling row of coloured pill badges — one per detected metadata category.
///
/// - `selectedCategory`: When provided, tapping a badge selects/deselects it.
struct MetadataBadgeRow: View {

    let metadata: StrippedMetadata
    var selectedCategory: Binding<String?>?

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
        let interactive = selectedCategory != nil

        return Button {
            guard interactive else { return }
            if isSelected {
                selectedCategory?.wrappedValue = nil
            } else {
                selectedCategory?.wrappedValue = category
            }
        } label: {
            // The category colour stays on the glyph and the fill; the words are
            // `.primary`, because orange or red caption text on a 10 % tint of
            // itself is unreadable.
            HStack(spacing: 4) {
                Image(systemName: metadataIconName(for: category))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(metadataCategoryDisplayName(for: category))
                    .font(.caption2.weight(.semibold))
                // Count bubble
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(isSelected ? color.opacity(0.25) : color.opacity(0.18), in: Capsule())
                // Selected indicator
                if isSelected {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.18) : color.opacity(0.10), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? color.opacity(0.6) : color.opacity(0.22),
                        lineWidth: isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: metadataCategoryDisplayName(for: category)))
        .accessibilityValue("^[\(count) field](inflect: true)")
        .accessibilityIdentifier("badge_\(category)")
        .accessibilityHint(interactive ? (isSelected ? "Double tap to close" : "Double tap to review") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(.spring(duration: 0.2), value: isSelected)
    }
}

// MARK: - Previews

#Preview("Badge row — interactive") {
    @Previewable @State var selected: String?
    let metadata = StrippedMetadata(fields: [
        MetadataField(category: "GPS", key: "GPSLatitude", value: "37.33"),
        MetadataField(category: "GPS", key: "GPSLongitude", value: "-122.03"),
        MetadataField(category: "EXIF", key: "DateTimeOriginal", value: "2024:06:15"),
        MetadataField(category: "TIFF", key: "Software", value: "17.0")
    ])
    VStack(spacing: 24) {
        MetadataBadgeRow(metadata: metadata, selectedCategory: $selected)
        Text(verbatim: "Selected: \(selected ?? "none")").font(.caption).foregroundStyle(.secondary)
    }
    .padding()
}
