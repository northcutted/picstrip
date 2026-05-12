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
    .init(type: .phoneNumber, icon: "phone.fill", color: .green, detail: "Detected via Apple's NLP text engine"),
    .init(type: .email, icon: "envelope.fill", color: .blue, detail: "RFC-compliant address regex + NLP"),
    // Identity
    .init(type: .address, icon: "map.fill", color: .orange, detail: "Street addresses via Apple's NLP text engine"),
    .init(type: .socialSecurityNumber, icon: "person.text.rectangle.fill", color: .red, detail: "US SSN — 3-2-4 format with anti-zero guards"),
    .init(type: .dateOfBirth, icon: "calendar", color: .purple, detail: "MM/DD/YYYY and YYYY-MM-DD formats"),
    .init(type: .nationalInsuranceNumber, icon: "person.badge.shield.checkmark.fill", color: .indigo, detail: "UK NI — two-letter prefix, six digits, A-D suffix"),
    .init(type: .governmentID, icon: "person.text.rectangle", color: .teal, detail: "Canadian SIN, Indian PAN/Aadhaar, Spanish DNI/NIE, Brazilian CPF, German Steuer-ID, Italian Codice Fiscale, French INSEE, Japanese My Number"),
    // Web
    .init(type: .ipAddress, icon: "network", color: .cyan, detail: "IPv4 (four 0-255 octets) and IPv6"),
    .init(type: .macAddress, icon: "wifi", color: .teal, detail: "Colon or hyphen-separated hardware addresses"),
    .init(type: .link, icon: "link", color: .blue, detail: "URLs and web links"),
    // Vehicle
    .init(type: .vehicleIdentificationNumber, icon: "car.fill", color: .brown, detail: "17-character ISO 3779 VIN (no I/O/Q)"),
    .init(type: .licensePlate, icon: "rectangle.fill", color: .brown, detail: "California-style plates detected structurally; other formats require a nearby plate label"),
    // Financial
    .init(type: .creditCard, icon: "creditcard.fill", color: .pink, detail: "Visa, Mastercard, Amex, Discover — with or without spaces"),
    .init(type: .iban, icon: "building.columns.fill", color: .brown, detail: "International bank account numbers (2-letter country code + check digits)"),
    .init(type: .cryptoWallet, icon: "bitcoinsign.circle.fill", color: .orange, detail: "Ethereum (0x... 40 hex) and Bitcoin Bech32 (bc1...)"),
    .init(type: .swiftBIC, icon: "globe", color: .teal, detail: "SWIFT/BIC bank codes — requires a SWIFT/BIC label nearby to prevent false positives"),
    .init(type: .abaRoutingNumber, icon: "banknote.fill", color: .green, detail: "US ABA 9-digit routing numbers — requires a routing/ABA keyword nearby"),
    // Developer Secrets
    .init(type: .awsAccessKey, icon: "cloud.fill", color: .orange, detail: "AWS Access Key IDs (AKIA... prefix)"),
    .init(type: .githubToken, icon: "chevron.left.forwardslash.chevron.right", color: .gray, detail: "Classic ghp_, gho_, ghu_, ghs_, ghr_ tokens"),
    .init(type: .googleAPIKey, icon: "key.horizontal.fill", color: .red, detail: "Google Cloud API keys (AIza... prefix)"),
    .init(type: .openAIKey, icon: "sparkles", color: .purple, detail: "OpenAI API keys (sk- and sk-proj- formats)"),
    .init(type: .slackToken, icon: "message.fill", color: .green, detail: "Bot, user, and app tokens (xox... prefix)"),
    .init(type: .stripeKey, icon: "dollarsign.circle.fill", color: .indigo, detail: "Secret and publishable keys (sk_/pk_ + live/test)"),
    .init(type: .genericPrivateKey, icon: "key.fill", color: .yellow, detail: "PEM headers: RSA, EC, DSA, OPENSSH private keys"),
    .init(type: .jwtToken, icon: "ellipsis.curlybraces", color: .cyan, detail: "JSON Web Tokens — double eyJ base64url prefix uniquely identifies the format"),
    .init(type: .developerSecret, icon: "lock.shield.fill", color: .red, detail: "Anthropic, GitLab PAT, npm, HuggingFace, DigitalOcean, Twilio, SendGrid, Discord bot tokens"),
    .init(type: .connectionString, icon: "server.rack", color: .brown, detail: "Database/broker URIs with inline credentials: postgres, mysql, mongodb, redis, amqp"),
    // Vision-detected
    .init(type: .face, icon: "face.dashed", color: .pink, detail: "Human faces detected via Apple's on-device Face Rectangles model"),
    .init(type: .barcode, icon: "qrcode", color: .primary, detail: "QR codes and barcodes — decoded payload shown in the snippet (Wi-Fi passwords, vCards, URLs, MFA seeds)"),
    // Unstructured
    .init(type: .unstructuredCredential, icon: "note.text", color: .secondary, detail: "Whiteboard or sticky-note passwords detected via keyword + separator heuristic")
]

private let metadataEntries: [MetadataEntry] = [
    .init(name: "GPS", icon: "location.fill", color: .red, detail: "Coordinates, altitude, speed, heading, and the exact timestamp your shutter fired"),
    .init(name: "EXIF", icon: "camera.fill", color: .blue, detail: "Shutter speed, aperture, ISO, focal length, flash, white balance, and lens info"),
    .init(name: "EXIF Auxiliary", icon: "camera.aperture", color: .cyan, detail: "Lens serial number, lens ID, and flash compensation data"),
    .init(name: "TIFF", icon: "doc.fill", color: .orange, detail: "Device make and model, editing software, copyright notice, author, and creation time"),
    .init(name: "IPTC", icon: "person.2.fill", color: .purple, detail: "Press-agency fields: caption, keywords, creator credit, contact info, and copyright"),
    .init(name: "Apple Maker Note", icon: "iphone.gen2", color: .gray, detail: "Private Apple metadata: face detection data, HDR analysis, scene classification, front/rear camera ID")
]

// MARK: - Risk Level display helpers

private func riskColor(_ level: RiskLevel) -> Color {
    switch level {
    case .critical: return .red
    case .high:     return .orange
    case .medium:   return .blue
    case .low:      return .green
    }
}

private func riskIcon(_ level: RiskLevel) -> String {
    switch level {
    case .critical: return "exclamationmark.octagon.fill"
    case .high:     return "exclamationmark.triangle.fill"
    case .medium:   return "info.circle.fill"
    case .low:      return "checkmark.circle.fill"
    }
}

// MARK: - About view

/// Native iOS "About" sheet — instructions, privacy guarantee, scoring system explanation,
/// and detection catalogue.
struct AboutView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var visualExpanded   = false
    @State private var metadataExpanded = false
    @State private var scoringExpanded  = false

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
                            text: "**Select a photo** from your library, import from Files, or drag an image directly onto PicStrip."
                        )
                        instructionRow(
                            icon: "viewfinder",
                            color: .purple,
                            text: "**PicStrip scans on-device** using Apple's Vision OCR, face detection, and barcode reader to find sensitive content in the image."
                        )
                        instructionRow(
                            icon: "square.dashed",
                            color: .orange,
                            text: "**Review detections** in the Redaction Editor. Each finding shows its match confidence and a risk rating so you can make informed decisions about what to cover."
                        )
                        instructionRow(
                            icon: "hand.tap.fill",
                            color: .indigo,
                            text: "**Adjust redactions** by tapping to select, dragging to reposition, or pinching to resize. Use the **Select** button to choose multiple regions at once and apply the same style or color to all of them in one step."
                        )
                        instructionRow(
                            icon: "tag.slash.fill",
                            color: .teal,
                            text: "**Hidden metadata** like GPS coordinates, camera model, and timestamps is stripped from the file before it ever leaves your device."
                        )
                        instructionRow(
                            icon: "square.and.arrow.down.fill",
                            color: .green,
                            text: "**Save the cleaned photo** back to your library. You can also share directly from the Photos app using the PicStrip Share Extension."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 3: Getting Photos Into PicStrip ────────────────
                Section(header: Text("Ways to Import")) {
                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(
                            icon: "photo",
                            color: .blue,
                            text: "**Photos Library** — tap \u{201C}Select a Photo\u{201D} or \u{201C}Select Multiple Photos\u{201D} to pick from your camera roll."
                        )
                        instructionRow(
                            icon: "folder",
                            color: .orange,
                            text: "**Files App** — tap \u{201C}Browse Files\u{201D} to import images stored locally or in iCloud Drive, Dropbox, and other providers."
                        )
                        instructionRow(
                            icon: "arrow.down.to.line",
                            color: .purple,
                            text: "**Drag & Drop** — drag any image from Safari, Files, or another app and drop it onto PicStrip to load it instantly."
                        )
                        instructionRow(
                            icon: "square.and.arrow.up",
                            color: .teal,
                            text: "**Share Extension** — in any app, tap Share → PicStrip to send an image to PicStrip, then open the app to edit it."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 4: Understanding Your Results ──────────────────
                Section {
                    DisclosureGroup(isExpanded: $scoringExpanded) {
                        VStack(alignment: .leading, spacing: 16) {

                            // Confidence explanation
                            VStack(alignment: .leading, spacing: 8) {
                                Label {
                                    Text("Match Confidence")
                                        .font(.subheadline.weight(.semibold))
                                } icon: {
                                    Image(systemName: "percent")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                                }
                                Text("The **match confidence** percentage tells you how certain our on-device models are that the detected pattern is really what we think it is. It is derived from two factors:\n• **Pattern specificity** — how structurally unambiguous the detection rule is. An AWS key with its exact AKIA prefix scores 98%; a date string scores only 48% because dates appear in many non-sensitive contexts.\n• **OCR quality** — Apple's Vision OCR confidence for the specific text observation. A crisp screenshot produces a higher score than a blurry photograph of the same text.\n\nA higher confidence means fewer false positives, but low-confidence detections can still be real — use your judgement.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Divider()

                            // Risk explanation
                            VStack(alignment: .leading, spacing: 8) {
                                Label {
                                    Text("Risk Level")
                                        .font(.subheadline.weight(.semibold))
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
                                }
                                Text("The **risk level** is our editorial assessment of how harmful it would be if this type of data were accidentally shared. It does not change based on detection confidence — a critical-risk item is critical regardless of whether we detected it at 60% or 99%.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                // Risk level rows
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(RiskLevel.allCases.reversed(), id: \.self) { level in
                                        riskLevelRow(level)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    } label: {
                        disclosureLabel(
                            icon: "chart.bar.xaxis",
                            color: .indigo,
                            title: "Confidence & Risk Scores",
                            count: "How to read them"
                        )
                    }
                } header: {
                    Text("Understanding Your Results")
                } footer: {
                    Text("Both scores are shown together for every detection so you can see exactly what was found, how certain we are, and how serious exposure would be.")
                        .font(.caption)
                }

                // ── Section 5: What PicStrip Detects ──────────────────────
                Section {
                    // Visual content
                    DisclosureGroup(isExpanded: $visualExpanded) {
                        VStack(spacing: 2) {
                            ForEach(visualEntries, id: \.type) { entry in
                                detectionRow(
                                    icon: entry.icon,
                                    color: entry.color,
                                    type: entry.type,
                                    detail: LocalizedStringKey(entry.detail)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        disclosureLabel(
                            icon: "eye.fill",
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
                                    icon: entry.icon,
                                    color: entry.color,
                                    title: LocalizedStringKey(entry.name),
                                    detail: LocalizedStringKey(entry.detail)
                                )
                            }
                        }
                        .padding(.vertical, 4)
                    } label: {
                        disclosureLabel(
                            icon: "tag.fill",
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

                // ── Section 6: Redaction Editor Tips ──────────────────────
                Section(header: Text("Redaction Editor Tips")) {
                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(
                            icon: "hand.tap",
                            color: .blue,
                            text: "**Tap a region row** in the editor to select it and reveal its style and color options."
                        )
                        instructionRow(
                            icon: "checkmark.circle.fill",
                            color: .orange,
                            text: "**Tap the circle** on the right of each row to enable or disable a redaction individually. Disabled regions are shown at reduced opacity."
                        )
                        instructionRow(
                            icon: "checklist",
                            color: .indigo,
                            text: "**Select multiple regions** using the \u{201C}Select\u{201D} button. Tap \u{201C}Select All\u{201D} to grab everything at once, then choose a style or color to apply to the entire selection in one tap."
                        )
                        instructionRow(
                            icon: "arrow.uturn.backward",
                            color: .gray,
                            text: "**Undo / Redo** every style change, move, resize, or delete — every action is fully reversible."
                        )
                        instructionRow(
                            icon: "plus.circle.fill",
                            color: .green,
                            text: "**Draw a custom region** using the \u{201C}Add Region\u{201D} button, then drag on the photo to cover anything the automatic scan missed."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 7: Privacy Guarantee ───────────────────────────
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
                    privacyRow(
                        icon: "clock.badge.xmark",
                        color: .purple,
                        title: "No Photo History",
                        detail: "PicStrip does not keep photo history, removed values, OCR snippets, or redaction coordinates. Nothing about what you process is stored beyond the current session."
                    )
                }

                // ── Section 8: Open Source & Developer ─────────────────────
                Section(header: Text("About the Project")) {
                    if let sourceURL = URL(string: "https://github.com/northcutted/picstrip") {
                        Link(destination: sourceURL) {
                            Label {
                                Text("View Source on GitHub")
                            } icon: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(Color.accentColor)
                            }
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

                    if let linkedInURL = URL(string: "https://www.linkedin.com/in/edward-northcutt-b06386101") {
                        Link(destination: linkedInURL) {
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
                    }
                }

                // ── Section 9: Privacy promise footer ─────────────────────
                Section {
                    Text("PicStrip was built on a single principle: Privacy. The app exists to help you avoid sharing things you don't intend to.")
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

    private func instructionRow(icon: String, color: Color, text: LocalizedStringKey) -> some View {
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

    private func privacyRow(icon: String, color: Color, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
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

    private func disclosureLabel(icon: String, color: Color, title: LocalizedStringKey, count: String) -> some View {
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

    /// Detection row with an inline risk badge (used for PIIType entries).
    private func detectionRow(
        icon: String,
        color: Color,
        type: PIIType,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(type.description))
                        .font(.subheadline.weight(.medium))

                    // Inline risk badge
                    Text(type.riskLevel.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(riskColor(type.riskLevel))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(riskColor(type.riskLevel).opacity(0.12), in: Capsule())
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
    }

    /// Detection row without a risk badge (used for metadata entries that have no PIIType).
    private func detectionRow(
        icon: String,
        color: Color,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
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

    /// Single risk-level explanatory row used inside the scoring disclosure group.
    private func riskLevelRow(_ level: RiskLevel) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: riskIcon(level))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(riskColor(level), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(level.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(riskColor(level))

                Text(riskDescription(level))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func riskDescription(_ level: RiskLevel) -> String {
        switch level {
        case .critical:
            return "Immediate account takeover or major financial fraud risk. SSNs, credit card numbers, API keys, private keys, database credentials."
        case .high:
            return "Significant personal, financial, or identity harm. Bank account numbers, faces, physical credentials written on paper."
        case .medium:
            return "Useful to attackers in combination with other data. Email addresses, phone numbers, IP addresses, vehicle plates."
        case .low:
            return "Contextual information. Exposure risk depends on the recipient. Dates, URLs, barcodes."
        }
    }
}

#Preview {
    AboutView()
}
