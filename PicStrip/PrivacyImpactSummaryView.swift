import SwiftUI

struct PrivacyImpactSummaryView: View {
    let stats: PrivacyRemovalStats

    @Environment(\.dismiss) private var dismiss

    private var metadataRows: [(category: String, count: Int)] {
        ImageProcessor.categoryMap.compactMap { entry in
            guard let count = stats.metadataCategoryCounts[entry.category], count > 0 else { return nil }
            return (entry.category, count)
        }
    }

    private var visualRows: [(name: String, count: Int)] {
        stats.visualTypeCounts
            .map { ($0.key, $0.value) }
            .filter { $0.1 > 0 }
            .sorted { $0.0 < $1.0 }
    }

    private var confidenceRows: [(label: String, count: Int)] {
        ConfidenceLevel.allCases.reversed().compactMap { level in
            guard let count = stats.visualConfidenceCounts[level.label], count > 0 else { return nil }
            return (level.label, count)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "shield.checkered")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Privacy Cleanup")
                                .font(.headline)
                            Text("Aggregate counts only. PicStrip does not keep photo history, removed values, OCR snippets, or redaction boxes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if metadataRows.isEmpty && visualRows.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Cleanup Stats Yet",
                            systemImage: "checkmark.seal",
                            description: Text("Clean and save a photo to build an aggregate privacy summary.")
                        )
                    }
                }

                if !metadataRows.isEmpty {
                    Section("Metadata Removed") {
                        ForEach(metadataRows, id: \.category) { row in
                            MetadataImpactRow(category: row.category, count: row.count)
                        }
                    }
                }

                if !visualRows.isEmpty {
                    Section("Visual Redactions") {
                        ForEach(visualRows, id: \.name) { row in
                            VisualImpactRow(name: row.name, count: row.count)
                        }
                    }
                }

                if !confidenceRows.isEmpty {
                    Section {
                        ForEach(confidenceRows, id: \.label) { row in
                            HStack {
                                Text(row.label)
                                Spacer()
                                Text("^[\(row.count) region](inflect: true)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Detection Confidence")
                    } footer: {
                        Text("Confidence summarizes automatic visual detections only. Custom redactions are counted without a confidence score.")
                    }
                }
            }
            .navigationTitle("Removed Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("privacyImpactSummary")
    }
}

private struct MetadataImpactRow: View {
    let category: String
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: metadataIconName(for: category))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(metadataIconColor(for: category))
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(category)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("^[\(count) field](inflect: true)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(metadataCategoryDescription(for: category))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct VisualImpactRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("^[\(count) region](inflect: true)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(visualRiskDescription(for: name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private func visualRiskDescription(for name: String) -> String {
    switch name {
    case PIIType.email.description:
        return "Email addresses can connect a photo to accounts, breach data, social profiles, and workplace identity."
    case PIIType.phoneNumber.description:
        return "Phone numbers can be searched, messaged, or linked to public records and account recovery flows."
    case PIIType.address.description:
        return "Addresses can reveal where someone lives, works, or spends time."
    case PIIType.link.description:
        return "Links can expose private documents, usernames, tracking parameters, or internal systems."
    case PIIType.ipAddress.description:
        return "IP addresses can identify a network, workplace, approximate location, or infrastructure."
    case PIIType.macAddress.description:
        return "Hardware addresses can identify a specific device on a local network."
    case PIIType.creditCard.description, PIIType.iban.description, PIIType.cryptoWallet.description:
        return "Financial identifiers can expose accounts or enable fraud when shared with the wrong audience."
    case PIIType.socialSecurityNumber.description,
         PIIType.nationalInsuranceNumber.description,
         PIIType.dateOfBirth.description:
        return "Identity details can support impersonation, account recovery abuse, or public-record matching."
    case PIIType.awsAccessKey.description,
         PIIType.githubToken.description,
         PIIType.googleAPIKey.description,
         PIIType.openAIKey.description,
         PIIType.slackToken.description,
         PIIType.stripeKey.description,
         PIIType.genericPrivateKey.description:
        return "Secrets and tokens can grant access to accounts, code, infrastructure, or paid services."
    case PIIType.unstructuredCredential.description:
        return "Credentials in screenshots or whiteboards can be reused directly if they are visible."
    default:
        return "Custom redactions hide sensitive visual details that automatic detection may not understand."
    }
}

#Preview {
    PrivacyImpactSummaryView(stats: PrivacyRemovalStats(
        metadataCategoryCounts: ["GPS": 2, "EXIF": 6],
        visualTypeCounts: ["Email Address": 1, "Custom Redaction": 2],
        visualConfidenceCounts: ["High": 1]
    ))
}
