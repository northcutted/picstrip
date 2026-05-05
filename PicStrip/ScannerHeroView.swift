import SwiftUI

// MARK: - PIIState

/// Tracks the visual lifecycle of a detected PII box across the two animation passes.
private enum PIIState: Equatable {
    case clear      // invisible — before detection
    case outlined   // dashed accent border — detected, not yet scrubbed
    case redacted   // solid black fill — scrubbed
}

// MARK: - ScannerHeroView

/// Looping two-pass privacy-scanner hero animation shown on the home screen.
///
/// **Pass 1 — Detection:** a blue scan beam sweeps top-to-bottom.  As it
/// crosses each element it reveals hidden file metadata (dots scattered in the
/// document margins / corners) and outlines visual PII text regions.
///
/// **Pass 2 — Scrubbing:** an orange scrub beam sweeps top-to-bottom; as it
/// crosses each element the metadata dots disappear and the PII boxes flip to
/// solid black redactions.
///
/// A camera-shutter wipe resets the scene between cycles.
/// `.task` + `Task.sleep` gives precise multi-step sequencing with automatic
/// cancellation when the view disappears.
struct ScannerHeroView: View {

    // MARK: Layout constants

    private let frameW: CGFloat = 220
    private let frameH: CGFloat = 160

    /// Duration of the Detection scan sweep (seconds).
    private let scanDuration: Double = 2.4
    /// Duration of the Scrubbing sweep (seconds).
    private let scrubDuration: Double = 2.0

    // MARK: PII boxes — fractions of frame dimensions (x, y, w, h)

    private let boxes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = [
        (0.10, 0.16, 0.52, 0.12),  // name   — centreY ≈ 35 px
        (0.10, 0.41, 0.64, 0.11),  // email  — centreY ≈ 74 px
        (0.10, 0.66, 0.38, 0.11),  // phone  — centreY ≈114 px
    ]

    /// Simulated document text-line widths as fractions of frame width.
    private let textLines: [CGFloat] = [0.52, 0.70, 0.45, 0.64, 0.38, 0.56]

    // MARK: Metadata dots
    //
    // These represent hidden *file* metadata (GPS, EXIF timestamps, camera
    // model, software tag, etc.) embedded in the image — not the visible text
    // findings.  They are scattered in the document's right margin and corners
    // to emphasise that they live inside the file, not on the page.
    //
    // Positions are the *centre* pixel coordinates within the 220 × 160 frame,
    // sorted by cy so the beam triggers them in top-to-bottom order.

    private struct DotSpec {
        let cx: CGFloat
        let cy: CGFloat
        let color: Color
    }

    /// All metadata dots, **sorted ascending by `cy`** so beam-sweep timing
    /// can process them in a single linear pass.
    ///
    /// One dot per metadata category, using the same colours as the app's
    /// pill badges (`MetadataSummaryView.metadataIconColor`).
    /// Arranged in a single vertical column in the right margin to evoke a
    /// structured file manifest embedded in the image.
    private let dots: [DotSpec] = [
        DotSpec(cx: 196, cy:  12, color: .red),     // GPS
        DotSpec(cx: 196, cy:  39, color: .blue),    // EXIF
        DotSpec(cx: 196, cy:  66, color: .indigo),  // EXIF Auxiliary
        DotSpec(cx: 196, cy:  93, color: .orange),  // TIFF
        DotSpec(cx: 196, cy: 120, color: .purple),  // IPTC
        DotSpec(cx: 196, cy: 147, color: .primary), // Apple Maker Note
    ]

    // MARK: Animation state

    @State private var scanY: CGFloat = 0
    @State private var beamVisible: Bool = false

    @State private var scrubY: CGFloat = 0
    @State private var scrubBeamVisible: Bool = false

    /// Per-box detection / scrub state.
    @State private var piiStates: [PIIState] = [.clear, .clear, .clear]

    /// Per-dot visibility — each driven independently by beam timing.
    @State private var dotVisible: [Bool] = [false, false, false, false, false, false]

    /// Shutter panels meet at mid-line when true.
    @State private var shutterClosed: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            backgroundLayer
            textLineLayer
            piiBoxLayer
            dotLayer
            detectionBeamLayer
            scrubBeamLayer
            shutterLayer
            borderLayer
        }
        .frame(width: frameW, height: frameH)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
        .accessibilityHidden(true) // decorative animation — no semantic content
        .task(id: reduceMotion) {
            if reduceMotion { return }
            await runLoop()
        }
    }

    // MARK: - Sub-layers

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.secondarySystemBackground))
    }

    private var textLineLayer: some View {
        ForEach(textLines.indices, id: \.self) { row in
            let lineY = 0.10 + CGFloat(row) * 0.155
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.primary.opacity(0.07))
                .frame(width: textLines[row] * frameW, height: 6)
                .offset(x: 0.10 * frameW, y: lineY * frameH)
        }
    }

    private var piiBoxLayer: some View {
        ForEach(boxes.indices, id: \.self) { i in
            let box   = boxes[i]
            let state = piiStates[i]

            RoundedRectangle(cornerRadius: 4)
                .fill(state == .redacted ? Color.black.opacity(0.85) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            state == .outlined ? Color.accentColor.opacity(0.75) : Color.clear,
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                )
                .frame(width: box.w * frameW, height: box.h * frameH)
                .offset(x: box.x * frameW, y: box.y * frameH)
                .opacity(state == .clear ? 0 : 1)
                .animation(.easeIn(duration: 0.18), value: state)
        }
    }

    /// Hidden file-metadata dots scattered in the document's right margin and
    /// corners.  Each dot is independently animated via its own `dotVisible[i]`
    /// boolean — no group stagger needed because the beam timer staggers them.
    private var dotLayer: some View {
        ForEach(dots.indices, id: \.self) { i in
            let dot     = dots[i]
            let dotSize: CGFloat = 7

            Circle()
                .fill(dot.color)
                .frame(width: dotSize, height: dotSize)
                .offset(x: dot.cx - dotSize / 2, y: dot.cy - dotSize / 2)
                .opacity(dotVisible[i] ? 1 : 0)
                .scaleEffect(dotVisible[i] ? 1 : 0.2)
                .animation(.spring(response: 0.30, dampingFraction: 0.55), value: dotVisible[i])
        }
    }

    /// Blue detection beam — sweeps during Pass 1.
    private var detectionBeamLayer: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear,                          location: 0.0),
                        .init(color: Color.accentColor.opacity(0.85), location: 0.5),
                        .init(color: .clear,                          location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: frameW, height: 14)
            .offset(y: scanY - 7)
            .opacity(beamVisible ? 1 : 0)
    }

    /// Scrub beam — same accent colour as the detection beam.
    private var scrubBeamLayer: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear,                          location: 0.0),
                        .init(color: Color.accentColor.opacity(0.90), location: 0.5),
                        .init(color: .clear,                          location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: frameW, height: 16)
            .offset(y: scrubY - 8)
            .opacity(scrubBeamVisible ? 1 : 0)
    }

    /// Camera-shutter: two panels slide from opposite edges to the mid-line.
    private var shutterLayer: some View {
        ZStack(alignment: .topLeading) {
            Color(.secondarySystemBackground)
                .frame(width: frameW, height: frameH / 2)
                .offset(y: shutterClosed ? 0 : -(frameH / 2))

            Color(.secondarySystemBackground)
                .frame(width: frameW, height: frameH / 2)
                .offset(y: shutterClosed ? frameH / 2 : frameH)
        }
    }

    private var borderLayer: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
    }

    // MARK: - Animation loop

    private func runLoop() async {
        while !Task.isCancelled {
            do { try await runCycle() } catch { break }
        }
    }

    /// Unified scan-event used to merge box and dot triggers into one
    /// sorted sequence for each beam pass.
    private enum ScanEvent {
        case outlineBox(Int)
        case showDot(Int)
        case redactBox(Int)
        case hideDot(Int)

        var yFrac: Double {
            // Computed in context of runCycle() — see helper below.
            0
        }
    }

    private func runCycle() async throws {

        var noAnim = Transaction()
        noAnim.disablesAnimations = true

        // ── 1. Instant reset ───────────────────────────────────────────────
        withTransaction(noAnim) {
            scanY            = 0
            beamVisible      = false
            scrubY           = 0
            scrubBeamVisible = false
            piiStates        = [.clear, .clear, .clear]
            dotVisible       = [false, false, false, false, false, false]
        }
        try await Task.sleep(for: .milliseconds(400))

        // ── 2. Pass 1 — Detection scan (blue beam) ─────────────────────────
        withAnimation(.linear(duration: scanDuration)) { scanY = frameH }
        withTransaction(noAnim) { beamVisible = true }

        // Build a single sorted event list: boxes triggered at their y-centre,
        // dots triggered as the beam crosses their cy.
        let detectEvents: [(yFrac: Double, fire: () -> Void)] = {
            var evts: [(Double, () -> Void)] = []
            for i in boxes.indices {
                let yf = Double(boxes[i].y + boxes[i].h / 2)
                evts.append((yf, {
                    withAnimation(.easeIn(duration: 0.18)) { piiStates[i] = .outlined }
                }))
            }
            for i in dots.indices {
                let yf = Double(dots[i].cy / frameH)
                evts.append((yf, { dotVisible[i] = true }))
            }
            return evts.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1) }
        }()

        var elapsed = 0.0
        for event in detectEvents {
            let wait = max(0, event.yFrac * scanDuration - elapsed)
            try await Task.sleep(for: .seconds(wait))
            elapsed = event.yFrac * scanDuration
            event.fire()
        }

        // Wait for beam to finish its remaining travel.
        let remainingScan = max(0, scanDuration - elapsed)
        try await Task.sleep(for: .seconds(remainingScan))

        withAnimation(.easeOut(duration: 0.20)) { beamVisible = false }

        // ── 3. Pause — show detected state (outlines + dots) ───────────────
        try await Task.sleep(for: .milliseconds(550))

        // ── 4. Pass 2 — Scrubbing sweep (orange beam) ─────────────────────
        withAnimation(.linear(duration: scrubDuration)) { scrubY = frameH }
        withTransaction(noAnim) { scrubBeamVisible = true }

        // Same merge: boxes redacted at their y-centre, dots hidden at their cy.
        let scrubEvents: [(yFrac: Double, fire: () -> Void)] = {
            var evts: [(Double, () -> Void)] = []
            for i in boxes.indices {
                let yf = Double(boxes[i].y + boxes[i].h / 2)
                evts.append((yf, {
                    withAnimation(.easeIn(duration: 0.15)) { piiStates[i] = .redacted }
                }))
            }
            for i in dots.indices {
                let yf = Double(dots[i].cy / frameH)
                evts.append((yf, { dotVisible[i] = false }))
            }
            return evts.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1) }
        }()

        elapsed = 0.0
        for event in scrubEvents {
            let wait = max(0, event.yFrac * scrubDuration - elapsed)
            try await Task.sleep(for: .seconds(wait))
            elapsed = event.yFrac * scrubDuration
            event.fire()
        }

        let remainingScrub = max(0, scrubDuration - elapsed)
        try await Task.sleep(for: .seconds(remainingScrub))

        withAnimation(.easeOut(duration: 0.20)) { scrubBeamVisible = false }

        // ── 5. Hold — fully-redacted scene, no dots ────────────────────────
        try await Task.sleep(for: .milliseconds(1_200))

        // ── 6. Shutter close → reset behind it → shutter open ─────────────
        withAnimation(.easeInOut(duration: 0.28)) { shutterClosed = true }
        try await Task.sleep(for: .milliseconds(340))

        withTransaction(noAnim) {
            piiStates        = [.clear, .clear, .clear]
            dotVisible       = [false, false, false, false, false, false]
            scanY            = 0
            scrubY           = 0
            beamVisible      = false
            scrubBeamVisible = false
        }
        try await Task.sleep(for: .milliseconds(160))

        withAnimation(.easeInOut(duration: 0.28)) { shutterClosed = false }
        try await Task.sleep(for: .milliseconds(500))
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ScannerHeroView()
    }
}
