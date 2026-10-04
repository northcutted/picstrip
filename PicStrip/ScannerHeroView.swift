import SwiftUI

// MARK: - ScannerHeroView

/// The home screen's hero: a little photo that PicStrip cleans, on a loop.
///
/// One loop, beat by beat:
/// 1. **Scan** — a beam sweeps the photo.  The hidden metadata it passes
///    (location, device, date) pops out of the photo as tags pinned to its
///    edges, and the face and the sign's text are outlined.
/// 2. **Strip** — the tags lift off and fade, the face is covered and the
///    text is blacked out.
/// 3. **Clean** — a seal stamps the photo and a glint crosses it.
/// 4. **Turn over** — the card flips to the next loop.  Loops alternate
///    between a photo, whose face is blurred, and a video: it starts playing,
///    its subject sways and its scrubber runs, and an emoji covers the face
///    and follows it.
///
/// Symbols and shapes only: no words, so nothing here needs translating.
///
/// Two clocks drive it.  The beats are discrete state changes, sequenced in
/// `.task` and animated with springs, so each runs at the display's rate only
/// while it plays.  The slow, continuous motion between them — the card's
/// float and tilt, the tags' bob, the cloud and the video's playback — comes
/// from a `TimelineView` at 30 frames a second: none of it moves more than a
/// point a frame at that rate, so the full rate would cost power without
/// looking any smoother.  Both stop when Reduce Motion is on, when the scene is
/// not active and when the hero is off screen; under Reduce Motion the hero
/// shows the finished, cleaned photo.
struct ScannerHeroView: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var beats = HeroBeats.start(isVideo: false)
    /// False once the hero scrolls out of sight (at the largest text sizes)
    /// or the home screen goes.
    @State private var isOnScreen = false

    private var isPlaying: Bool {
        !reduceMotion && isOnScreen && scenePhase == .active
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            HeroCard(beats: beats, time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: HeroLayout.canvas.width, height: HeroLayout.canvas.height)
        .accessibilityHidden(true) // decorative animation — no semantic content
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onScrollVisibilityChange(threshold: 0.05) { isOnScreen = $0 }
        .task(id: isPlaying) {
            if reduceMotion {
                beats = .finished
            } else if isPlaying {
                await play()
            }
        }
    }

    // MARK: - Sequencing

    /// Plays loops until the task is cancelled.  A loop interrupted half-way
    /// (the app went to the background, say) is not resumed: the card turns
    /// over to a fresh one instead.
    private func play() async {
        do {
            if beats != .start(isVideo: beats.isVideo) {
                try await turnOver(toVideo: !beats.isVideo)
            }
            while true {
                try await playLoop()
                try await turnOver(toVideo: !beats.isVideo)
            }
        } catch {
            // Cancelled: the hero went off screen or Reduce Motion came on.
        }
    }

    private func playLoop() async throws {
        if beats.isVideo {
            try await pause(0.35)
            try await startVideo()
        } else {
            try await pause(0.6)
        }
        try await scan()
        try await pause(0.8)
        try await strip()
        try await pause(0.3)
        seal()
        try await pause(2.4)
    }

    /// The play badge dips as if tapped and fades; playback starts with it.
    private func startVideo() async throws {
        withAnimation(.snappy(duration: 0.16)) { beats.isPlayPressed = true }
        try await pause(0.16)
        withAnimation(.smooth(duration: 0.4)) {
            beats.isPlayBadgeVisible = false
            beats.playStart = Date.now.timeIntervalSinceReferenceDate
        }
        try await pause(0.5)
    }

    /// Sweeps the beam across, revealing each find as the beam reaches it.
    private func scan() async throws {
        let duration = 1.8
        let curve = UnitCurve.easeInOut
        withAnimation(.easeOut(duration: 0.2)) { beats.isBeamVisible = true }
        withAnimation(.timingCurve(curve, duration: duration)) { beats.beam = 1 }

        var elapsed = 0.0
        for find in HeroFind.inScanOrder {
            // When the eased beam reaches the find, not when a linear one would.
            let time = curve.inverse.value(at: HeroLayout.beamProgress(atX: find.x)) * duration
            try await pause(time - elapsed)
            elapsed = time
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { reveal(find) }
        }
        try await pause(duration - elapsed)
        withAnimation(.easeOut(duration: 0.3)) { beats.isBeamVisible = false }
    }

    private func reveal(_ find: HeroFind) {
        switch find {
        case .tag(let index): beats.tags[index] = .pinned
        case .face: beats.isFaceFound = true
        case .text: beats.isTextFound = true
        }
    }

    /// Tags lift off one after another, then the face and the text are covered.
    private func strip() async throws {
        for index in beats.tags.indices {
            withAnimation(.smooth(duration: 0.55)) { beats.tags[index] = .lifted }
            try await pause(0.1)
        }
        try await pause(0.15)
        // The emoji lands with a bounce; a blur just settles in.
        let cover: Animation = beats.isVideo ? .bouncy(duration: 0.45, extraBounce: 0.15) : .smooth(duration: 0.6)
        withAnimation(cover) { beats.isFaceCovered = true }
        withAnimation(.smooth(duration: 0.3)) { beats.isFaceFound = false }
        for line in HeroLayout.signLines.indices {
            withAnimation(.snappy(duration: 0.28)) { beats.coveredLines = line + 1 }
            try await pause(0.09)
        }
        withAnimation(.smooth(duration: 0.3)) { beats.isTextFound = false }
    }

    private func seal() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { beats.isSealed = true }
        withAnimation(.easeInOut(duration: 0.9).delay(0.1)) { beats.glint = 1 }
    }

    /// Flips the card edge-on, swaps in a fresh one while nothing shows, and
    /// springs it the rest of the way round.
    private func turnOver(toVideo isVideo: Bool) async throws {
        withAnimation(.easeIn(duration: 0.22)) { beats.flip = 90 }
        try await pause(0.22)
        var next = HeroBeats.start(isVideo: isVideo)
        next.flip = -90
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { beats = next }
        // Let the swap render before the spring starts, or SwiftUI merges the
        // two and animates the old card round instead.
        try await pause(0.04)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { beats.flip = 0 }
        try await pause(0.5)
    }

    private func pause(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - State

/// Where a loop has got to.  The sequencer changes it one beat at a time; the
/// card draws it.
private struct HeroBeats: Equatable {
    enum TagState { case hidden, pinned, lifted }

    var isVideo = false
    var isPlayBadgeVisible = false
    var isPlayPressed = false
    /// When the video started playing, on the idle clock.
    var playStart: TimeInterval?
    /// How far the beam has crossed, 0…1.
    var beam: CGFloat = 0
    var isBeamVisible = false
    var tags: [TagState] = HeroTag.all.map { _ in .hidden }
    var isFaceFound = false
    var isTextFound = false
    var isFaceCovered = false
    /// How many of the sign's lines are blacked out.
    var coveredLines = 0
    var isSealed = false
    /// How far the glint has crossed, 0…1.
    var glint: CGFloat = 0
    /// The card's turn in degrees: 0 faces front, ±90 is edge-on.
    var flip: Double = 0

    /// A fresh loop: the original photo, or the video waiting to play.
    static func start(isVideo: Bool) -> HeroBeats {
        HeroBeats(isVideo: isVideo, isPlayBadgeVisible: isVideo)
    }

    /// The end of a photo loop, shown still under Reduce Motion.
    static let finished = HeroBeats(
        tags: HeroTag.all.map { _ in .lifted },
        isFaceCovered: true,
        coveredLines: HeroLayout.signLines.count,
        isSealed: true
    )
}

/// What the beam finds, in the order it finds them.
private enum HeroFind {
    case tag(Int)
    case face
    case text

    /// Where the find sits across the card, for the beam's timing.
    var x: CGFloat {
        switch self {
        case .tag(let index): HeroTag.all[index].center.x
        case .face: HeroLayout.face.x
        case .text: HeroLayout.sign.x
        }
    }

    static let inScanOrder: [HeroFind] = {
        let finds: [HeroFind] = HeroTag.all.indices.map { .tag($0) } + [.face, .text]
        return finds.sorted { $0.x < $1.x }
    }()
}

/// A piece of hidden metadata, pinned to the photo's edge once found.
private struct HeroTag: Identifiable {
    let id: Int
    let symbol: String
    let color: Color
    /// The tag's centre, in card coordinates.
    let center: CGPoint
    /// The direction out of the photo: tags emerge along it and lift off along it.
    let outward: CGVector

    /// Location, device and date, coloured like their categories elsewhere.
    static let all: [HeroTag] = [
        HeroTag(id: 0, symbol: "location.fill", color: .red, center: CGPoint(x: -1, y: 38), outward: CGVector(dx: -1, dy: 0)),
        HeroTag(id: 1, symbol: "iphone.gen2", color: .blue, center: CGPoint(x: 104, y: -1), outward: CGVector(dx: 0, dy: -1)),
        HeroTag(id: 2, symbol: "calendar", color: .orange, center: CGPoint(x: 201, y: 88), outward: CGVector(dx: 1, dy: 0))
    ]
}

// MARK: - Layout

/// Where everything sits, in the card's coordinates (points from its top-left).
private enum HeroLayout {
    static let card = CGSize(width: 200, height: 128)
    /// Room around the card for the tags, the seal and the float.
    static let canvas = CGSize(width: 252, height: 150)
    static let cornerRadius: CGFloat = 18

    static let sun = CGPoint(x: 166, y: 27)
    static let face = CGPoint(x: 64, y: 80)
    static let sign = CGPoint(x: 152, y: 60)
    static let signSize = CGSize(width: 58, height: 38)
    /// The width of each line of text on the sign.
    static let signLines: [CGFloat] = [36, 24, 30]
    static let seal = CGPoint(x: 193, y: 121)
    /// Clear of the face and the sign.
    static let playBadge = CGPoint(x: 98, y: 42)

    /// How far the beam runs past each side, so it enters and leaves unseen.
    static let beamOverrun: CGFloat = 24

    static func beamX(progress: CGFloat) -> CGFloat {
        -beamOverrun + progress * (card.width + 2 * beamOverrun)
    }

    static func beamProgress(atX x: CGFloat) -> Double {
        Double((x + beamOverrun) / (card.width + 2 * beamOverrun))
    }

    /// The centre of line `index` on the sign, and its leading edge.
    static func signLine(_ index: Int) -> (y: CGFloat, leading: CGFloat) {
        (sign.y - 10 + CGFloat(index) * 10, sign.x - 21)
    }
}

// MARK: - Palette

/// The scene's colours: a day photo and a golden-hour video in Light Mode;
/// a night photo and a dusk video in Dark Mode, so the card does not glare.
private struct HeroPalette: Equatable {
    let skyTop: Color
    let skyBottom: Color
    let farHill: Color
    let nearHill: Color
    let sun: Color
    let cloud: Color
    let shirt: Color
    let board: Color
    let ink: Color

    static func scene(isVideo: Bool, isDark: Bool) -> HeroPalette {
        switch (isVideo, isDark) {
        case (false, false): day
        case (true, false): goldenHour
        case (false, true): night
        case (true, true): dusk
        }
    }

    private static let day = HeroPalette(
        skyTop: Color(red: 0.45, green: 0.70, blue: 0.96), skyBottom: Color(red: 0.80, green: 0.91, blue: 0.99),
        farHill: Color(red: 0.60, green: 0.80, blue: 0.52), nearHill: Color(red: 0.42, green: 0.69, blue: 0.43),
        sun: Color(red: 1.00, green: 0.80, blue: 0.30), cloud: .white.opacity(0.9),
        shirt: Color(red: 0.95, green: 0.50, blue: 0.38),
        board: Color(white: 0.98), ink: Color(white: 0.45)
    )
    private static let goldenHour = HeroPalette(
        skyTop: Color(red: 0.97, green: 0.60, blue: 0.50), skyBottom: Color(red: 1.00, green: 0.86, blue: 0.66),
        farHill: Color(red: 0.76, green: 0.71, blue: 0.46), nearHill: Color(red: 0.56, green: 0.62, blue: 0.38),
        sun: Color(red: 1.00, green: 0.93, blue: 0.68), cloud: .white.opacity(0.7),
        shirt: Color(red: 0.30, green: 0.46, blue: 0.86),
        board: Color(white: 0.98), ink: Color(white: 0.45)
    )
    private static let night = HeroPalette(
        skyTop: Color(red: 0.07, green: 0.10, blue: 0.25), skyBottom: Color(red: 0.21, green: 0.23, blue: 0.43),
        farHill: Color(red: 0.15, green: 0.28, blue: 0.30), nearHill: Color(red: 0.10, green: 0.21, blue: 0.23),
        sun: Color(red: 0.95, green: 0.94, blue: 0.84), cloud: .white.opacity(0.16),
        shirt: Color(red: 0.78, green: 0.40, blue: 0.32),
        board: Color(white: 0.84), ink: Color(white: 0.38)
    )
    private static let dusk = HeroPalette(
        skyTop: Color(red: 0.17, green: 0.11, blue: 0.31), skyBottom: Color(red: 0.55, green: 0.30, blue: 0.40),
        farHill: Color(red: 0.27, green: 0.21, blue: 0.31), nearHill: Color(red: 0.18, green: 0.15, blue: 0.25),
        sun: Color(red: 1.00, green: 0.74, blue: 0.52), cloud: .white.opacity(0.14),
        shirt: Color(red: 0.32, green: 0.44, blue: 0.82),
        board: Color(white: 0.84), ink: Color(white: 0.38)
    )
}

// MARK: - Card

/// The photo card at one instant: `beats` says what has happened in the loop,
/// `time` drives the idle motion.  A `time` of 0 holds that motion at rest.
private struct HeroCard: View {
    let beats: HeroBeats
    let time: TimeInterval

    @Environment(\.colorScheme) private var colorScheme

    private var palette: HeroPalette {
        .scene(isVideo: beats.isVideo, isDark: colorScheme == .dark)
    }

    var body: some View {
        // Shrinks a little as it turns edge-on, like a card picked up to flip.
        let turnScale = CGFloat(1 - 0.06 * abs(beats.flip) / 90)
        let yaw = Angle.degrees(4 * wave(9))
        let pitch = Angle.degrees(2.5 * wave(7.4, phase: 1))
        let float = CGFloat(3 * wave(6))
        return ZStack {
            photo
            pins
        }
        .frame(width: HeroLayout.card.width, height: HeroLayout.card.height)
        .scaleEffect(turnScale)
        .rotation3DEffect(.degrees(beats.flip), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .rotation3DEffect(yaw, axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .rotation3DEffect(pitch, axis: (x: 1, y: 0, z: 0), perspective: 0.4)
        .offset(y: float)
    }

    /// A sine of the idle clock, -1…1, with the given period in seconds.
    private func wave(_ period: Double, phase: Double = 0) -> Double {
        sin(time * 2 * .pi / period + phase)
    }

    /// Seconds since the video started playing; 0 before it does.
    private var playback: TimeInterval {
        guard let start = beats.playStart, time > 0 else { return 0 }
        return max(0, time - start)
    }

    // MARK: Photo

    private var photo: some View {
        ZStack(alignment: .topLeading) {
            HeroSky(palette: palette, isDark: colorScheme == .dark)
            cloud
            HeroLand(palette: palette)
            textCovers
            person
            if beats.isVideo {
                videoControls
            }
            beam
            glint
        }
        .frame(width: HeroLayout.card.width, height: HeroLayout.card.height)
        .clipShape(.rect(cornerRadius: HeroLayout.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HeroLayout.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.6), lineWidth: 1)
        }
        .background { shadow }
    }

    /// The card's shadow, on a plain shape: shadowing the photo itself would
    /// shadow every layer in it.  It softens as the card floats up.
    private var shadow: some View {
        let lift = CGFloat(wave(6))
        return RoundedRectangle(cornerRadius: HeroLayout.cornerRadius, style: .continuous)
            .fill(palette.skyBottom)
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16),
                radius: 14 - 2 * lift,
                y: 10 - 2 * lift
            )
    }

    /// A cloud drifting across the sky, about ten points a second.
    private var cloud: some View {
        let span = HeroLayout.card.width + 70
        let drift = CGFloat((time / 27 + 0.55).truncatingRemainder(dividingBy: 1))
        return HeroCloud(color: palette.cloud)
            .position(x: drift * span - 35, y: 32)
    }

    // MARK: Finds and covers

    private var person: some View {
        let face = HeroLayout.face
        let isBlurred = beats.isFaceCovered && !beats.isVideo
        return ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(palette.shirt.gradient)
                .frame(width: 54, height: 36)
                .position(x: face.x, y: face.y + 37)
            Text(verbatim: beats.isVideo ? "👩🏼" : "🧑🏽")
                .font(.system(size: 38))
                .blur(radius: isBlurred ? 6 : 0)
                .position(face)
            outline(isFound: beats.isFaceFound, size: CGSize(width: 46, height: 48))
                .position(face)
            if beats.isVideo {
                emojiCover.position(face)
            }
        }
        // Playing, the subject sways; the outline and the cover follow it.
        .offset(x: beats.isVideo ? CGFloat(8 * sin(playback * 2 * .pi / 3.2)) : 0)
    }

    /// PicStrip's default emoji cover.
    private var emojiCover: some View {
        Text(verbatim: "🙂")
            .font(.system(size: 40))
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .scaleEffect(beats.isFaceCovered ? 1 : 0.2)
            .opacity(beats.isFaceCovered ? 1 : 0)
    }

    /// The sign's outline, then a black bar over each line of its text.
    private var textCovers: some View {
        ZStack {
            ForEach(HeroLayout.signLines.indices, id: \.self) { index in
                bar(index)
            }
            outline(isFound: beats.isTextFound, size: CGSize(width: 66, height: 46))
                .position(HeroLayout.sign)
        }
    }

    private func bar(_ index: Int) -> some View {
        let width = HeroLayout.signLines[index] + 8
        let line = HeroLayout.signLine(index)
        let isCovered = index < beats.coveredLines
        return Capsule()
            .fill(.black)
            .frame(width: width, height: 8)
            .scaleEffect(x: isCovered ? 1 : 0.01, anchor: .leading)
            .opacity(isCovered ? 1 : 0)
            .position(x: line.leading - 4 + width / 2, y: line.y)
    }

    /// A detection outline: it settles onto what was found, like a focus square.
    private func outline(isFound: Bool, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return shape
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(shape.fill(Color.accentColor.opacity(0.14)))
            .frame(width: size.width, height: size.height)
            .scaleEffect(isFound ? 1 : 1.35)
            .opacity(isFound ? 1 : 0)
    }

    // MARK: Video

    /// A play badge waiting to be tapped, then a scrubber that runs.
    private var videoControls: some View {
        let width: CGFloat = 164
        let progress = CGFloat(min(1, playback / 8))
        return ZStack {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                .frame(width: HeroLayout.card.width, height: 36)
                .position(x: HeroLayout.card.width / 2, y: HeroLayout.card.height - 18)
            HeroScrubber(width: width, progress: progress)
                .position(x: HeroLayout.card.width / 2, y: HeroLayout.card.height - 11)
            playBadge
                .position(HeroLayout.playBadge)
        }
    }

    private var playBadge: some View {
        let scale: CGFloat = beats.isPlayBadgeVisible ? (beats.isPlayPressed ? 0.86 : 1) : 1.3
        return Image(systemName: "play.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(.black.opacity(0.32), in: .circle)
            .scaleEffect(scale)
            .opacity(beats.isPlayBadgeVisible ? 1 : 0)
    }

    // MARK: Beam and glint

    /// A line of light with a soft glow either side, tinted with the accent.
    private var beam: some View {
        let light = Color.white
        return LinearGradient(
            colors: [light.opacity(0), light.opacity(0.5), light.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 36, height: HeroLayout.card.height)
        .overlay {
            Rectangle()
                .fill(light)
                .frame(width: 2)
                .shadow(color: Color.accentColor, radius: 4)
        }
        .opacity(beats.isBeamVisible ? 1 : 0)
        .position(x: HeroLayout.beamX(progress: beats.beam), y: HeroLayout.card.height / 2)
    }

    /// A diagonal shine that crosses the card once it is clean.
    private var glint: some View {
        let shine = Color.white
        return LinearGradient(
            colors: [shine.opacity(0), shine.opacity(colorScheme == .dark ? 0.3 : 0.55), shine.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 46, height: HeroLayout.card.height * 1.6)
        .rotationEffect(.degrees(18))
        .position(x: -70 + beats.glint * (HeroLayout.card.width + 140), y: HeroLayout.card.height / 2)
    }

    // MARK: Pins

    /// The metadata tags and the seal: pinned to the card, so not clipped by it.
    private var pins: some View {
        ZStack {
            ForEach(HeroTag.all) { tag in
                HeroTagView(tag: tag, state: beats.tags[tag.id], bob: CGFloat(1.5 * wave(2.8, phase: Double(tag.id) * 2.1)))
                    .position(tag.center)
            }
            sealView
                .position(HeroLayout.seal)
        }
        .frame(width: HeroLayout.card.width, height: HeroLayout.card.height)
    }

    private var sealView: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: 30, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .background(Circle().fill(.white).padding(2))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .modifier(HeroPing(color: .accentColor, isOn: beats.isSealed))
            .scaleEffect(beats.isSealed ? 1 : 0.2)
            .rotationEffect(.degrees(beats.isSealed ? 0 : -40))
            .opacity(beats.isSealed ? 1 : 0)
    }
}

// MARK: - Scene pieces

// Each piece takes only what it draws, so SwiftUI skips it on the idle clock's
// ticks, when nothing it draws has changed.

private struct HeroSky: View {
    let palette: HeroPalette
    let isDark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.skyTop, palette.skyBottom], startPoint: .top, endPoint: .bottom)
            if isDark {
                stars
            }
            Circle()
                .fill(palette.sun.gradient)
                .frame(width: 22, height: 22)
                .shadow(color: palette.sun.opacity(0.7), radius: 8)
                .position(HeroLayout.sun)
        }
    }

    private var stars: some View {
        ZStack {
            Circle().frame(width: 2, height: 2).position(x: 30, y: 18)
            Circle().frame(width: 1.5, height: 1.5).position(x: 74, y: 30)
            Circle().frame(width: 2, height: 2).position(x: 128, y: 14)
        }
        .foregroundStyle(.white.opacity(0.75))
    }
}

private struct HeroCloud: View {
    let color: Color

    var body: some View {
        ZStack {
            Capsule().frame(width: 38, height: 12).offset(y: 3)
            Circle().frame(width: 16, height: 16).offset(x: -5, y: -1)
            Circle().frame(width: 12, height: 12).offset(x: 7, y: 0)
        }
        .foregroundStyle(color)
    }
}

/// The hills and the sign, with its lines of text.
private struct HeroLand: View {
    let palette: HeroPalette

    var body: some View {
        ZStack {
            Ellipse()
                .fill(palette.farHill)
                .frame(width: 280, height: 96)
                .position(x: 40, y: 134)
            Rectangle()
                .fill(palette.ink)
                .frame(width: 3, height: 44)
                .position(x: HeroLayout.sign.x, y: HeroLayout.sign.y + 30)
            Ellipse()
                .fill(palette.nearHill)
                .frame(width: 250, height: 76)
                .position(x: 184, y: 140)
            board
        }
    }

    private var board: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.board)
                .frame(width: HeroLayout.signSize.width, height: HeroLayout.signSize.height)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .position(HeroLayout.sign)
            ForEach(HeroLayout.signLines.indices, id: \.self) { index in
                let line = HeroLayout.signLine(index)
                let width = HeroLayout.signLines[index]
                Capsule()
                    .fill(palette.ink)
                    .frame(width: width, height: 4)
                    .position(x: line.leading + width / 2, y: line.y)
            }
        }
    }
}

private struct HeroScrubber: View {
    let width: CGFloat
    let progress: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.35))
            Capsule().fill(.white).frame(width: max(3, width * progress))
        }
        .frame(width: width, height: 3)
        .overlay(alignment: .leading) {
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .shadow(color: .black.opacity(0.25), radius: 1.5)
                .offset(x: width * progress - 4)
        }
    }
}

/// A metadata tag: it emerges from the photo's edge, bobs while pinned, and
/// lifts away when stripped.
private struct HeroTagView: View {
    let tag: HeroTag
    let state: HeroBeats.TagState
    let bob: CGFloat

    var body: some View {
        Image(systemName: tag.symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tag.color.gradient, in: .circle)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
            .modifier(HeroPing(color: tag.color, isOn: state == .pinned))
            .scaleEffect(scale)
            .blur(radius: state == .lifted ? 2.5 : 0)
            .opacity(state == .pinned ? 1 : 0)
            .offset(offset)
    }

    private var scale: CGFloat {
        switch state {
        case .hidden: 0.2
        case .pinned: 1
        case .lifted: 0.75
        }
    }

    private var offset: CGSize {
        let out = tag.outward
        switch state {
        case .hidden: return CGSize(width: -12 * out.dx, height: -12 * out.dy)
        case .pinned: return CGSize(width: 0, height: bob)
        case .lifted: return CGSize(width: 8 * out.dx, height: 8 * out.dy - 18)
        }
    }
}

/// A ring that swells out of a view and fades, once, as `isOn` turns true:
/// the "found it" of a tag, the stamp of the seal.  A bounded keyframe
/// animation, so it costs nothing once played.
private struct HeroPing: ViewModifier {
    let color: Color
    let isOn: Bool

    private struct Ring {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    func body(content: Content) -> some View {
        let isOn = isOn
        return content.background {
            Circle()
                .stroke(color, lineWidth: 2)
                .keyframeAnimator(initialValue: Ring(), trigger: isOn) { ring, value in
                    ring
                        .scaleEffect(value.scale)
                        .opacity(isOn ? value.opacity : 0)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(1)
                        CubicKeyframe(2.1, duration: 0.7)
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0.8)
                        CubicKeyframe(0, duration: 0.7)
                    }
                }
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(.systemBackground).ignoresSafeArea()
        ScannerHeroView()
    }
}
