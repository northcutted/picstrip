import SwiftUI

// MARK: - Detection catalogue data

private struct PIIEntry {
    let type: PIIType
    let icon: String
    let color: Color
    let detail: String
}

private struct MetadataEntry {
    let name: String
    let icon: String
    let color: Color
    let detail: String
}

private let visualEntries: [PIIEntry] = [
    // Contact
    .init(type: .phoneNumber,             icon: "phone.fill",                        color: .green,   detail: "Detected via Apple's NLP text engine"),
    .init(type: .email,                   icon: "envelope.fill",                     color: .blue,    detail: "RFC-compliant address regex + NLP"),
    // Identity
    .init(type: .address,                 icon: "map.fill",                          color: .orange,  detail: "Street addresses via Apple's NLP text engine"),
    .init(type: .socialSecurityNumber,    icon: "person.text.rectangle.fill",        color: .red,     detail: "US SSN — 3-2-4 format with anti-zero guards"),
    .init(type: .dateOfBirth,             icon: "calendar",                          color: .purple,  detail: "MM/DD/YYYY and YYYY-MM-DD formats"),
    .init(type: .nationalInsuranceNumber, icon: "person.badge.shield.checkmark.fill",color: .indigo,  detail: "UK NI — two-letter prefix, six digits, A-D suffix"),
    // Web
    .init(type: .ipAddress,               icon: "network",                           color: .cyan,    detail: "IPv4 (four 0-255 octets) and IPv6"),
    .init(type: .macAddress,              icon: "wifi",                              color: .teal,    detail: "Colon or hyphen-separated hardware addresses"),
    .init(type: .link,                    icon: "link",                              color: .blue,    detail: "URLs and web links"),
    // Financial
    .init(type: .creditCard,              icon: "creditcard.fill",                   color: .pink,    detail: "Visa, Mastercard, Amex, Discover — with or without spaces"),
    .init(type: .iban,                    icon: "building.columns.fill",             color: .brown,   detail: "International bank account numbers (2-letter country code + check digits)"),
    .init(type: .cryptoWallet,            icon: "bitcoinsign.circle.fill",           color: .orange,  detail: "Ethereum (0x... 40 hex) and Bitcoin Bech32 (bc1...)"),
    // Developer Secrets
    .init(type: .awsAccessKey,            icon: "cloud.fill",                        color: .orange,  detail: "AWS Access Key IDs (AKIA... prefix)"),
    .init(type: .githubToken,             icon: "chevron.left.forwardslash.chevron.right", color: .gray,    detail: "Classic ghp_, gho_, ghu_, ghs_, ghr_ tokens"),
    .init(type: .googleAPIKey,            icon: "key.horizontal.fill",               color: .red,     detail: "Google Cloud API keys (AIza... prefix)"),
    .init(type: .openAIKey,               icon: "sparkles",                          color: .purple,  detail: "OpenAI API keys (sk- and sk-proj- formats)"),
    .init(type: .slackToken,              icon: "message.fill",                      color: .green,   detail: "Bot, user, and app tokens (xox... prefix)"),
    .init(type: .stripeKey,               icon: "dollarsign.circle.fill",            color: .indigo,  detail: "Secret and publishable keys (sk_/pk_ + live/test)"),
    .init(type: .genericPrivateKey,       icon: "key.fill",                          color: .yellow,  detail: "PEM headers: RSA, EC, DSA, OPENSSH private keys"),
    // Unstructured
    .init(type: .unstructuredCredential,  icon: "note.text",                         color: .secondary, detail: "Whiteboard or sticky-note passwords detected via keyword + separator heuristic"),
]

private let metadataEntries: [MetadataEntry] = [
    .init(name: "GPS",              icon: "location.fill",    color: .red,    detail: "Coordinates, altitude, speed, heading, and the exact timestamp your shutter fired"),
    .init(name: "EXIF",             icon: "camera.fill",      color: .blue,   detail: "Shutter speed, aperture, ISO, focal length, flash, white balance, and lens info"),
    .init(name: "EXIF Auxiliary",   icon: "camera.aperture",  color: .cyan,   detail: "Lens serial number, lens ID, and flash compensation data"),
    .init(name: "TIFF",             icon: "doc.fill",         color: .orange, detail: "Device make and model, editing software, copyright notice, author, and creation time"),
    .init(name: "IPTC",             icon: "person.2.fill",    color: .purple, detail: "Press-agency fields: caption, keywords, creator credit, contact info, and copyright"),
    .init(name: "Apple Maker Note", icon: "iphone.gen2",      color: .gray,   detail: "Private Apple metadata: face detection data, HDR analysis, scene classification, front/rear camera ID"),
]

// MARK: - About view

/// Native iOS "About" sheet — instructions, privacy guarantee, and project links.
struct AboutView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var visualExpanded  = false
    @State private var metadataExpanded = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {

                // ── Section 1: App header ──────────────────────────────────
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.accentColor, Color.indigo],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 88, height: 88)
                                    .shadow(color: Color.accentColor.opacity(0.35),
                                            radius: 10, x: 0, y: 4)

                                Image(systemName: "shield.checkerboard")
                                    .font(.system(size: 42, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                            .accessibilityHidden(true)

                            Text("PicStrip")
                                .font(.title2.bold())

                            Text(appVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                // ── Section 2: How It Works ────────────────────────────────
                Section(header: Text("How It Works")) {
                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(
                            icon: "photo.badge.plus",
                            color: .blue,
                            text: "Select one or more photos from your library."
                        )
                        instructionRow(
                            icon: "eye.slash.fill",
                            color: .orange,
                            text: "PicStrip scans for sensitive visual data (passwords, emails, phone numbers) and blacks it out on-device."
                        )
                        instructionRow(
                            icon: "tag.slash.fill",
                            color: .purple,
                            text: "Hidden metadata like GPS coordinates, camera model, and timestamps is stripped from the file before it ever leaves your device."
                        )
                        instructionRow(
                            icon: "square.and.arrow.down.fill",
                            color: .green,
                            text: "Save the cleaned photo back to your library or replace the original. An audit report is always available."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 3: What PicStrip Detects ──────────────────────
                Section {
                    // Visual content
                    DisclosureGroup(isExpanded: $visualExpanded) {
                        VStack(spacing: 2) {
                            ForEach(visualEntries, id: \.type) { entry in
                                detectionRow(
                                    icon:   entry.icon,
                                    color:  entry.color,
                                    title:  entry.type.description,
                                    detail: entry.detail
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        disclosureLabel(
                            icon:  "eye.fill",
                            color: .blue,
                            title: "Visual Content",
                            count: "\(visualEntries.count) types"
                        )
                    }

                    // Metadata categories
                    DisclosureGroup(isExpanded: $metadataExpanded) {
                        VStack(spacing: 2) {
                            ForEach(metadataEntries, id: \.name) { entry in
                                detectionRow(
                                    icon:   entry.icon,
                                    color:  entry.color,
                                    title:  entry.name,
                                    detail: entry.detail
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        disclosureLabel(
                            icon:  "tag.fill",
                            color: .purple,
                            title: "Hidden Metadata",
                            count: "\(metadataEntries.count) categories"
                        )
                    }
                } header: {
                    Text("What PicStrip Detects")
                } footer: {
                    Text("Detection limits are intentional. We only flag patterns specific enough to keep false positives rare.")
                        .font(.caption)
                }

                // ── Section 4: Privacy Guarantee ───────────────────────────
                Section(header: Text("Privacy")) {
                    privacyRow(
                        icon: "lock.fill",
                        color: .green,
                        title: "100% On-Device Processing",
                        detail: "Your photos are never uploaded to any server. All scanning, redaction, and metadata stripping happens entirely on your iPhone."
                    )
                    privacyRow(
                        icon: "wifi.slash",
                        color: .orange,
                        title: "No Internet Required",
                        detail: "PicStrip works completely offline. It makes zero network requests. Ever."
                    )
                    privacyRow(
                        icon: "chart.bar.xaxis",
                        color: .red,
                        title: "No Analytics or Tracking",
                        detail: "No telemetry, no crash reporters, no ad SDKs. Your usage is not observed or collected in any way."
                    )
                }

                // ── Section 5: Open Source & Developer ─────────────────────
                Section(header: Text("About the Project")) {
                    Link(destination: URL(string: "https://github.com/northcutted/picstrip")!) {
                        Label {
                            Text("View Source on GitHub")
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    LabeledContent {
                        Text("MIT License")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text("Open Source License")
                        } icon: {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent {
                        Text("Eddie Northcutt")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label {
                            Text("Developer")
                        } icon: {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── Section 6: Privacy promise footer ─────────────────────
                Section {
                    Text("PicStrip was built on a single principle: your photos are yours. The app exists to give you back control of the data attached to and visible inside your images, silently, automatically, and entirely privately.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Row helpers

    private func instructionRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func privacyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func disclosureLabel(icon: String, color: Color, title: String, count: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            Text(count)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 2)
    }

    private func detectionRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }
}

#Preview {
    AboutView()
}
