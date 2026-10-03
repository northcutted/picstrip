import SwiftUI

// MARK: - Detection catalogue data

// `detail` is a `LocalizedStringKey`, not a `String`: a plain string literal is
// never extracted into the string catalog, so it would stay English everywhere.
private struct PIIEntry {
    let type: PIIType
    let color: Color
    let detail: LocalizedStringKey
}

private struct MetadataEntry {
    /// The category identifier `ImageProcessor` reports ("GPS", "Apple Maker Note", …).
    let name: String
    let icon: String
    let color: Color
    let detail: LocalizedStringKey
}

private let visualEntries: [PIIEntry] = [
    // Contact
    .init(type: .phoneNumber, color: .green, detail: "Detected via Apple's NLP text engine"),
    .init(type: .email, color: .blue, detail: "RFC-compliant address regex + NLP"),
    // Identity
    .init(type: .address, color: .orange, detail: "Street addresses via Apple's NLP text engine"),
    .init(type: .socialSecurityNumber, color: .red, detail: "US SSN — 3-2-4 format with anti-zero guards"),
    .init(type: .dateOfBirth, color: .purple, detail: "MM/DD/YYYY and YYYY-MM-DD formats"),
    .init(type: .nationalInsuranceNumber, color: .indigo, detail: "UK NI — two-letter prefix, six digits, A-D suffix"),
    .init(type: .governmentID, color: .teal, detail: "Canadian SIN, Indian PAN/Aadhaar, Spanish DNI/NIE, Brazilian CPF, German Steuer-ID, Italian Codice Fiscale, French INSEE, Japanese My Number"),
    // Web
    .init(type: .ipAddress, color: .cyan, detail: "IPv4 (four 0-255 octets) and IPv6"),
    .init(type: .macAddress, color: .teal, detail: "Colon or hyphen-separated hardware addresses"),
    .init(type: .link, color: .blue, detail: "URLs and web links"),
    // Vehicle
    .init(type: .vehicleIdentificationNumber, color: .brown, detail: "17-character ISO 3779 VIN (no I/O/Q)"),
    .init(type: .licensePlate, color: .brown, detail: "California-style plates detected structurally; other formats require a nearby plate label"),
    // Financial
    .init(type: .creditCard, color: .pink, detail: "Visa, Mastercard, Amex, Discover — with or without spaces"),
    .init(type: .iban, color: .brown, detail: "International bank account numbers (2-letter country code + check digits)"),
    .init(type: .cryptoWallet, color: .orange, detail: "Ethereum (0x... 40 hex) and Bitcoin Bech32 (bc1...)"),
    .init(type: .swiftBIC, color: .teal, detail: "SWIFT/BIC bank codes — requires a SWIFT/BIC label nearby to prevent false positives"),
    .init(type: .abaRoutingNumber, color: .green, detail: "US ABA 9-digit routing numbers — requires a routing/ABA keyword nearby"),
    // Developer Secrets
    .init(type: .awsAccessKey, color: .orange, detail: "AWS Access Key IDs (AKIA... prefix)"),
    .init(type: .githubToken, color: .gray, detail: "Classic ghp_, gho_, ghu_, ghs_, ghr_ tokens"),
    .init(type: .googleAPIKey, color: .red, detail: "Google Cloud API keys (AIza... prefix)"),
    .init(type: .openAIKey, color: .purple, detail: "OpenAI API keys (sk- and sk-proj- formats)"),
    .init(type: .slackToken, color: .green, detail: "Bot, user, and app tokens (xox... prefix)"),
    .init(type: .stripeKey, color: .indigo, detail: "Secret and publishable keys (sk_/pk_ + live/test)"),
    .init(type: .genericPrivateKey, color: .yellow, detail: "Multiline PEM private-key blocks, including their encoded contents"),
    .init(type: .jwtToken, color: .cyan, detail: "JSON Web Tokens — double eyJ base64url prefix uniquely identifies the format"),
    .init(type: .developerSecret, color: .red, detail: "Anthropic, GitLab PAT, npm, HuggingFace, DigitalOcean, Twilio, SendGrid, Discord bot tokens"),
    .init(type: .connectionString, color: .brown, detail: "Database/broker URIs with inline credentials: postgres, mysql, mongodb, redis, amqp"),
    // Vision-detected
    .init(type: .face, color: .pink, detail: "Human faces detected via Apple's on-device Face Rectangles model"),
    .init(type: .barcode, color: .primary, detail: "QR codes and barcodes — decoded payload shown in the snippet (Wi-Fi passwords, vCards, URLs, MFA seeds)"),
    // Unstructured
    .init(type: .personName, color: .teal, detail: "People's names, found by Apple's on-device language model where Apple Intelligence is on. Listed, but not redacted until you switch them on"),
    .init(type: .unstructuredCredential, color: .secondary, detail: "Whiteboard or sticky-note passwords detected via keyword + separator heuristic")
]

private let metadataEntries: [MetadataEntry] = [
    .init(name: "GPS", icon: "location.fill", color: .red, detail: "Coordinates, altitude, speed, heading, and the exact timestamp your shutter fired"),
    .init(name: "EXIF", icon: "camera.fill", color: .blue, detail: "Shutter speed, aperture, ISO, focal length, flash, white balance, and lens info"),
    .init(name: "EXIF Auxiliary", icon: "camera.aperture", color: .cyan, detail: "Lens serial number, lens ID, and flash compensation data"),
    .init(name: "TIFF", icon: "doc.fill", color: .orange, detail: "Device make and model, editing software, copyright notice, author, and creation time"),
    .init(name: "IPTC", icon: "person.2.fill", color: .purple, detail: "Press-agency fields: caption, keywords, creator credit, contact info, and copyright"),
    .init(name: "Apple Maker Note", icon: "iphone.gen2", color: .gray, detail: "Private Apple metadata: face detection data, HDR analysis, scene classification, front/rear camera ID")
]

// MARK: - About view

/// Native iOS "About" sheet — instructions, privacy behavior, match-strength explanation,
/// and detection catalogue.
struct AboutView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var visualExpanded   = false
    @State private var metadataExpanded = false
    @State private var scoringExpanded  = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Version \(v) (\(b))")
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
                            text: "**Choose a photo or video** from your library, take one with PicStrip\u{2019}s camera, import from Files, or drag an image directly onto PicStrip."
                        )
                        instructionRow(
                            icon: "viewfinder",
                            color: .purple,
                            text: "**PicStrip scans on-device** using Apple's Vision OCR, face detection, and barcode reader to find sensitive content in the image."
                        )
                        instructionRow(
                            icon: "square.dashed",
                            color: .orange,
                            text: "**Review detections** in the Redaction Editor. Each finding shows its match strength and a risk rating so you can make informed decisions about what to cover."
                        )
                        instructionRow(
                            icon: "hand.tap.fill",
                            color: .indigo,
                            text: "**Adjust redactions** by dragging or using Position & size. Add a centered box without drawing. Use **Select** to apply changes to multiple regions."
                        )
                        instructionRow(
                            icon: "tag.slash.fill",
                            color: .teal,
                            text: "**Review hidden metadata** such as location, camera details, and timestamps. Choose what to remove and check the cleaned output."
                        )
                        instructionRow(
                            icon: "square.and.arrow.down.fill",
                            color: .green,
                            text: "**Review & Share** the cleaned image, or save a new copy to Photos. The Share Extension also offers direct cleaning or a protected handoff for editing."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 3: Getting Photos Into PicStrip ────────────────
                Section(header: Text("Ways to Import")) {
                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(
                            icon: "camera",
                            color: .pink,
                            text: "**Camera** — tap \u{201C}Camera\u{201D}, then choose Photo, Video or Document. Photo shows live what would be covered, Video records in 4K or HD with HDR, and Document scans paper. Nothing you capture is saved to your photo library as it is; only the cleaned copy is."
                        )
                        instructionRow(
                            icon: "photo.on.rectangle.angled",
                            color: .blue,
                            text: "**Photos & Videos** — pick one photo to edit it, one video to clean it, or several of either to clean them all at once. Your screenshots are in the picker's Collections."
                        )
                        instructionRow(
                            icon: "folder",
                            color: .brown,
                            text: "**Files App** — tap \u{201C}Browse Files\u{201D} to import an image or a video stored locally or in iCloud Drive, Dropbox, and other providers."
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
                                    Text("Match strength")
                                        .font(.subheadline.weight(.semibold))
                                } icon: {
                                    Image(systemName: "text.magnifyingglass")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 6))
                                }
                                Text("Match strength combines pattern rules and text-recognition quality. Strong, possible, and tentative matches help you prioritize review; they are not probabilities and cannot certify that an image is safe. Check the whole photo for anything you do not want to share.")
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
                                Text("Risk describes how sensitive a kind of information may be if shared. It is an editorial guide, separate from match strength. Even a tentative match may contain something you want to keep private.")
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
                            title: "Match strength & risk",
                            count: "How to read them"
                        )
                    }
                } header: {
                    Text("Understanding Your Results")
                } footer: {
                    Text("Match strength helps you review a finding. Risk helps you decide whether to cover it. Neither replaces your final review.")
                        .font(.caption)
                }

                // ── Section 5: What PicStrip Detects ──────────────────────
                Section {
                    // Visual content
                    DisclosureGroup(isExpanded: $visualExpanded) {
                        VStack(spacing: 2) {
                            ForEach(visualEntries, id: \.type) { entry in
                                detectionRow(
                                    icon: entry.type.symbolName,
                                    color: entry.color,
                                    type: entry.type,
                                    detail: entry.detail
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
                                    title: metadataCategoryDisplayName(for: entry.name),
                                    detail: entry.detail
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
                        instructionRow(
                            icon: "face.smiling",
                            color: .yellow,
                            text: "**Cover with an emoji** — choose Emoji as the style, then pick one from the grid or search all emoji. The face is blurred underneath, so nothing shows around it."
                        )
                    }
                    .padding(.vertical, 6)
                }

                // ── Section 6b: Videos ────────────────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        instructionRow(
                            icon: "video",
                            color: .red,
                            text: "**Clean a video.** PicStrip removes where it was filmed, the device, and the dates, and checks the copy before you share it."
                        )
                        instructionRow(
                            icon: "video.circle",
                            color: .pink,
                            text: "**Record in PicStrip.** In the camera, choose Video. Tap 4K or the frame rate to change them, HDR to turn it off, and the running figure for steadier video. In Photo and Video, tap a lens or pinch to zoom; tap to focus, then drag up or down to brighten or darken. The volume buttons and the Camera Control take the photo or start and stop recording."
                        )
                        instructionRow(
                            icon: "face.dashed",
                            color: .orange,
                            text: "**Faces are found and covered as they move**, with a strong blur, a solid box, or an emoji you pick for each face. Choose \u{201C}Leave Visible\u{201D} for anyone who should stay seen."
                        )
                        instructionRow(
                            icon: "text.viewfinder",
                            color: .blue,
                            text: "**Text and codes** — phone numbers, email addresses, card numbers, QR codes, and your Always Cover words — are read twice a second and stay covered as the camera moves."
                        )
                        instructionRow(
                            icon: "viewfinder",
                            color: .green,
                            text: "**Cover any object.** Pause where something shows — a person, a car, a screen, a sign — and tap \u{201C}Cover an Object\u{201D}. Draw a box around it, drag it into place or drag its corner to resize it, and PicStrip tracks it through the whole video, forwards and back."
                        )
                        instructionRow(
                            icon: "timeline.selection",
                            color: .purple,
                            text: "**The timeline** shows every cover and sound edit as a clip in its lane. Tap a clip to select it, drag its yellow ends to start it earlier or end it later, and hold it for its options. Drag across the frames to move through the video, and pinch to zoom in."
                        )
                        instructionRow(
                            icon: "waveform.badge.exclamationmark",
                            color: .pink,
                            text: "**Bleep or mute the sound.** Hold on the Audio lane and drag across what was said, then choose Bleep or Mute — or Play to hear it first. Drag the clip\u{2019}s ends to cover exactly the words."
                        )
                        instructionRow(
                            icon: "square.stack.3d.up",
                            color: .indigo,
                            text: "**Many videos at once.** Pick several videos — with photos too, if you like — and clean them all with one policy: every face found is blurred and text and codes are covered, with nothing reviewed. It takes a while, so keep PicStrip open; open a video on its own to check each cover."
                        )
                        instructionRow(
                            icon: "play.rectangle",
                            color: .teal,
                            text: "**Watch the preview, then save.** The preview is drawn exactly the way the copy is saved. Automatic covering can miss something small, turned away, or on screen for a moment, so check before you share."
                        )
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Videos")
                }

                // ── Section 7: Privacy ───────────────────────────
                Section(header: Text("Privacy")) {
                    privacyRow(
                        icon: "lock.fill",
                        color: .green,
                        title: "100% On-Device Processing",
                        detail: "Scanning, redaction, and metadata removal happen on your device. Photos go to another app or service only through the import, save, and sharing actions you choose."
                    )
                    privacyRow(
                        icon: "face.dashed",
                        color: .pink,
                        title: "Face Data Is Not Collected",
                        detail: "Face rectangles stay in the editing session. PicStrip does not identify people. Images you save or share can contain faces you leave uncovered."
                    )
                    privacyRow(
                        icon: "wifi.slash",
                        color: .orange,
                        title: "Offline Editing",
                        detail: "Editing works offline after your image is available locally. Cloud imports, optional Apple model downloads, and services you choose for saving or sharing may use the network."
                    )
                    privacyRow(
                        icon: "chart.bar.xaxis",
                        color: .red,
                        title: "No Analytics or Tracking",
                        detail: "No ads, usage analytics, or third-party crash reporting. PicStrip does not send your activity to a developer-operated service."
                    )
                    privacyRow(
                        icon: "clock.badge.xmark",
                        color: .purple,
                        title: "No Photo History",
                        detail: "PicStrip keeps no photo history. Protected edit copies expire after 15 minutes and temporary exports after one hour. Cleanup runs when the app or extension can access them."
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
                ToolbarItem(placement: .topBarTrailing) {
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

    private func disclosureLabel(icon: String, color: Color, title: LocalizedStringKey, count: LocalizedStringKey) -> some View {
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
                    Text(type.description)
                        .font(.subheadline.weight(.medium))

                    // Inline risk badge
                    Text(type.riskLevel.shortLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(type.riskLevel.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(type.riskLevel.color.opacity(0.12), in: Capsule())
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
        title: String,
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
            Image(systemName: level.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(level.color, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(level.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(level.color)

                Text(riskDescription(level))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func riskDescription(_ level: RiskLevel) -> LocalizedStringKey {
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
