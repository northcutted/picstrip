import SwiftUI

// MARK: - Redaction style / colour pickers

/// The style choices, shared by the single-region panel and the bulk panel.
///
/// Text follows Dynamic Type; at accessibility sizes four chips no longer fit
/// side by side, so they wrap into two rows instead of shrinking past legibility.
private struct RedactionStylePicker: View {
    /// `nil` when the selected regions do not share one style.
    let selection: RedactionStyle?
    let isBulk: Bool
    let onSelect: (RedactionStyle) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let columns = dynamicTypeSize.isAccessibilitySize ? 2 : RedactionStyle.allCases.count
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(RedactionStyle.allCases, id: \.self) { style in
                let isActive = selection == style
                Button {
                    onSelect(style)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: style.symbolName)
                            .font(.subheadline)
                            .fontWeight(isActive ? .bold : .regular)
                        Text(style.displayName)
                            .font(.caption2)
                            .fontWeight(isActive ? .semibold : .regular)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        isActive ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(Color(.tertiarySystemFill)),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color(.separator), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isBulk ? "Apply \(style.displayName) style to selected regions" : "\(style.displayName) style"
                )
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .accessibilityIdentifier(isBulk ? "bulkStyleButton-\(style.rawValue)" : "styleButton-\(style.rawValue)")
            }
        }
    }
}

/// The emoji an `.emoji` region is covered with: a grid of favourites and a
/// field that takes any other emoji, typed or pasted.
private struct RedactionEmojiPicker: View {
    /// `nil` when the selected regions do not share one emoji.
    let selection: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
                ForEach(EmojiCover.choices, id: \.self) { emoji in
                    let isActive = selection == emoji
                    Button {
                        onSelect(emoji)
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                isActive ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(isActive ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .accessibilityIdentifier("emojiChoice-\(emoji)")
                }
            }
            HStack(spacing: 8) {
                if let selection, !EmojiCover.choices.contains(selection) {
                    Text(selection)
                        .font(.title2)
                        .accessibilityAddTraits(.isSelected)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                EmojiKeyboardField(placeholder: String(localized: "Search all emoji"), onPick: onSelect)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A field that opens straight onto the emoji keyboard — whose own search finds
/// any emoji, in the user's language — and hands back the first emoji chosen.
/// Without the emoji keyboard installed it falls back to the usual keyboard.
private struct EmojiKeyboardField: UIViewRepresentable {
    let placeholder: String
    let onPick: (String) -> Void

    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }

    final class Coordinator: NSObject {
        var onPick: (String) -> Void

        init(onPick: @escaping (String) -> Void) {
            self.onPick = onPick
        }

        @objc func changed(_ field: UITextField) {
            guard let emoji = EmojiCover.firstEmoji(in: field.text ?? "") else { return }
            field.text = ""
            field.resignFirstResponder()
            onPick(emoji)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.accessibilityIdentifier = "otherEmojiField"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.addTarget(field, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        field.placeholder = placeholder
        context.coordinator.onPick = onPick
    }
}

/// The colour swatches, shared by the single-region panel and the bulk panel.
/// The swatch art is 28 pt; its button is a full 44 pt touch target.
private struct RedactionColorPicker: View {
    /// `nil` when the selected regions do not share one colour.
    let selection: RedactionColor?
    let isBulk: Bool
    let onSelect: (RedactionColor) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
        HStack(spacing: 4) {
            ForEach(RedactionColor.allCases, id: \.self) { color in
                let isActive = selection == color
                Button {
                    onSelect(color)
                } label: {
                    ZStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 28, height: 28)
                        if color.isLight {
                            Circle()
                                .strokeBorder(Color(.separator), lineWidth: 1)
                                .frame(width: 28, height: 28)
                        }
                        if isActive {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                .frame(width: 34, height: 34)
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color.isLight ? Color.black : Color.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isBulk ? "Apply \(color.displayName) color to selected regions" : "\(color.displayName) color"
                )
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .accessibilityIdentifier(isBulk ? "bulkColorButton-\(color.rawValue)" : "colorButton-\(color.rawValue)")
            }
        }
        }
    }
}

/// How hard pixelate / blur scramble a region, shared by the single-region
/// panel and the bulk panel.
///
/// The thumb moves freely but the change is committed once, when the drag
/// ends, so one adjustment is one undo step.
private struct RedactionStrengthSlider: View {
    /// `nil` when the selected regions do not share one strength.
    let selection: Double?
    let isBulk: Bool
    let onCommit: (Double) -> Void

    @State private var value = RedactionStrength.standard

    var body: some View {
        Slider(
            value: $value,
            in: RedactionStrength.range,
            step: RedactionStrength.step
        ) {
            Text("Strength")
        } minimumValueLabel: {
            Image(systemName: "circle.dotted")
                .accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "circle.fill")
                .accessibilityHidden(true)
        } onEditingChanged: { isEditing in
            if !isEditing { onCommit(value) }
        }
        .frame(minHeight: 44)
        .foregroundStyle(.secondary)
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
        // VoiceOver's adjust actions change the value without an editing phase.
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? RedactionStrength.step : -RedactionStrength.step
            value = RedactionStrength.clamped(value + delta)
            onCommit(value)
        }
        .accessibilityIdentifier(isBulk ? "bulkStrengthSlider" : "strengthSlider")
        .onAppear { value = selection ?? RedactionStrength.standard }
        .onChange(of: selection) { _, new in value = new ?? RedactionStrength.standard }
    }
}

// MARK: - Redaction Editor Drawer

/// Bottom-panel UI that replaces `controlPanel` while the user is editing redaction regions.
///
/// **Single-select mode (default):** tapping a row selects it for image-preview focus and shows
/// the style / colour panel. The toggle and delete buttons appear on each row.
///
/// **Multi-select mode:** activated by the "Select" button in the header.
/// Each row shows a checkbox; tapping toggles it in `multiSelectedIDs`.
/// When at least one region is selected, a bulk style / colour panel appears and the
/// action bar shows Enable/Disable + Delete buttons for the whole selection.
/// Exiting multi-select (via the header "Done" button) clears the selection.
struct RedactionEditorDrawer: View {

    let regions: [RedactionRegion]
    let selectedRegionID: String?
    let canUndo: Bool
    let canRedo: Bool
    let isAddingRedaction: Bool
    /// Whether a tap on the photo can outline an object (iOS 27).
    var canSelectObjects = false

    // Single-region callbacks
    let onSelect: (String?) -> Void
    let onAdd: () -> Void
    let onAddCentered: () -> Void
    let onAdjust: (String, CGRect) -> Void
    let onToggleRegion: (String) -> Void
    let onDeleteRegion: (String) -> Void
    let onChangeStyle: (String, RedactionStyle) -> Void
    let onChangeColor: (String, RedactionColor) -> Void
    let onChangeStrength: (String, Double) -> Void

    // Bulk callbacks
    let onBulkChangeStyle: (Set<String>, RedactionStyle) -> Void
    let onBulkChangeColor: (Set<String>, RedactionColor) -> Void
    let onBulkChangeStrength: (Set<String>, Double) -> Void
    let onBulkDelete: (Set<String>) -> Void
    let onBulkToggle: (Set<String>) -> Void

    let onUndo: () -> Void
    let onRedo: () -> Void
    let onFit: () -> Void
    let onDone: () -> Void

    /// Covers only part of a finding (`RedactionRegion.partialCover`), or all of it.
    var onSetPartial: (String, Bool) -> Void = { _, _ in }
    var onChangeEmoji: (String, String) -> Void = { _, _ in }
    var onBulkChangeEmoji: (Set<String>, String) -> Void = { _, _ in }
    /// Gives every face the style and emoji of this one.
    var onApplyToAllFaces: ((String) -> Void)?
    /// Adds a finding's text to the Always Cover list.
    var onAlwaysCover: ((String) -> Void)?

    // MARK: - Multi-select local state

    @State private var showPosition = false
    @State private var showStyles = false
    @State private var isMultiSelectMode: Bool = false
    @State private var multiSelectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Label("Redaction Regions", systemImage: "square.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Select / Done — multi-select mode toggle
                if !regions.isEmpty {
                    Button(isMultiSelectMode ? "Done" : "Select") {
                        withAnimation(.spring(duration: 0.22)) {
                            isMultiSelectMode.toggle()
                            if !isMultiSelectMode {
                                multiSelectedIDs.removeAll()
                            } else {
                                // Clear VM single-select when entering multi-select
                                onSelect(nil)
                            }
                        }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(isMultiSelectMode ? "Exit multi-select mode" : "Enter multi-select mode")
                }

                if !isMultiSelectMode {
                    // Add / Cancel-Add toggle (only in normal mode)
                    Button(action: onAdd) {
                        Label(
                            isAddingRedaction ? "Cancel" : "Add Region",
                            systemImage: isAddingRedaction ? "xmark" : "plus"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("addRedactionButton")
                    .accessibilityAction(named: Text("Add centered region"), onAddCentered)
                    .accessibilityLabel(isAddingRedaction ? "Cancel drawing redaction" : "Draw a new redaction region")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // ── Multi-select sub-header ───────────────────────────────────
            if isMultiSelectMode {
                HStack(spacing: 12) {
                    Button(multiSelectedIDs.count == regions.count ? "Deselect All" : "Select All") {
                        withAnimation(.spring(duration: 0.18)) {
                            if multiSelectedIDs.count == regions.count {
                                multiSelectedIDs.removeAll()
                            } else {
                                multiSelectedIDs = Set(regions.map(\.id))
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                    Spacer()

                    if !multiSelectedIDs.isEmpty {
                        Text("^[\(multiSelectedIDs.count) region](inflect: true) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Draw-mode hint (single-select only) ──────────────────────
            if isAddingRedaction && !isMultiSelectMode {
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(canSelectObjects
                         ? "Drag on the photo to draw a redaction box, or tap an object"
                         : "Drag on the photo to draw a redaction box")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !isMultiSelectMode {
                Button("Add centered region", action: onAddCentered)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("addCenteredRedactionButton")
            }

            Divider()

            // ── Region list ───────────────────────────────────────────────
            if regions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "square.dashed")
                            .font(.title2.weight(.light))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text("No redaction regions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 18)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(regions) { region in
                            regionRow(region).id(region.id)
                            if region.id != regions.last?.id {
                                Divider()
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 160)
                .onChange(of: selectedRegionID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
                }
                .onChange(of: regions) { _, newRegions in
                    // Prune stale IDs (e.g. after undo removes regions)
                    let validIDs = Set(newRegions.map(\.id))
                    let stale = multiSelectedIDs.subtracting(validIDs)
                    if !stale.isEmpty {
                        multiSelectedIDs.subtract(stale)
                        if multiSelectedIDs.isEmpty {
                            withAnimation { isMultiSelectMode = false }
                        }
                    }
                }
            }

            Divider()

            // ── Style + Colour panel ──────────────────────────────────────
            // Single-select: show for the VM-selected region.
            // Multi-select: show bulk panel when at least one region is selected.
            if !isMultiSelectMode,
               let selectedRegion = regions.first(where: { $0.id == selectedRegionID }) {
                HStack {
                    Button { showStyles = true } label: {
                        Label(selectedRegion.style.displayName, systemImage: "paintbrush")
                    }
                    .accessibilityLabel("Style")
                    .accessibilityIdentifier("editRegionStyleButton")
                    Spacer()
                    Button("Position & size") { showPosition = true }
                        .accessibilityIdentifier("regionPositionButton")
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .padding(.horizontal, 16)
                Divider()
                if let label = selectedRegion.partialCoverLabel {
                    Toggle(label, isOn: Binding(
                        get: { selectedRegion.isPartial },
                        set: { onSetPartial(selectedRegion.id, $0) }
                    ))
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("partialCoverToggle")
                    Divider()
                }
                if let onAlwaysCover, let term = selectedRegion.alwaysCoverCandidate {
                    Button {
                        onAlwaysCover(term)
                    } label: {
                        Label("Always cover “\(term)”", systemImage: "pin")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("alwaysCoverThisButton")
                    Divider()
                }
            } else if isMultiSelectMode && !multiSelectedIDs.isEmpty {
                Button("Style") { showStyles = true }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("editBulkStyleButton")
                Divider()
            }

            // ── Action bar ────────────────────────────────────────────────
            if isMultiSelectMode {
                bulkActionBar
            } else {
                normalActionBar
            }
        }
        .sheet(isPresented: $showStyles) {
            NavigationStack {
                ScrollView {
                    if isMultiSelectMode { bulkStyleColorPanel() } else if let region = regions.first(where: { $0.id == selectedRegionID }) { styleColorPanel(for: region) }
                }
                .navigationTitle("Style")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showStyles = false }.accessibilityIdentifier("doneStyleButton")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showPosition) {
            if let region = regions.first(where: { $0.id == selectedRegionID }) {
                RegionPositionView(region: region, onAdjust: onAdjust)
            }
        }
        .animation(.spring(duration: 0.22), value: isAddingRedaction)
        .animation(.spring(duration: 0.22), value: regions.count)
        .animation(.spring(duration: 0.22), value: isMultiSelectMode)
        .animation(.spring(duration: 0.18), value: multiSelectedIDs)
    }

    // MARK: - Normal action bar

    private var normalActionBar: some View {
        HStack(spacing: 8) {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canUndo)
            .accessibilityLabel("Undo")
            .accessibilityIdentifier("undoRedactionButton")

            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canRedo)
            .accessibilityLabel("Redo")
            .accessibilityIdentifier("redoRedactionButton")

            Button(action: onFit) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Reset zoom to fit image")
            .accessibilityIdentifier("resetZoomButton")

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Done editing redactions")
            .accessibilityIdentifier("doneEditingRedactionsButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Bulk action bar

    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            // Toggle enable / disable for all selected
            Button {
                onBulkToggle(multiSelectedIDs)
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(multiSelectedIDs.isEmpty)
            .accessibilityLabel("Toggle visibility of selected regions")

            // Delete all selected
            Button {
                let ids = multiSelectedIDs
                onBulkDelete(ids)
                withAnimation(.spring(duration: 0.22)) {
                    multiSelectedIDs.removeAll()
                    isMultiSelectMode = false
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(multiSelectedIDs.isEmpty)
            .accessibilityLabel("Delete selected regions")

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Done editing redactions")
            .accessibilityIdentifier("doneEditingRedactionsButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Single-region Style + Colour Panel

    /// Compact contextual panel shown when exactly one region is selected.
    /// Style choices are always visible; the colour row is hidden for styles without a colour.
    @ViewBuilder
    private func styleColorPanel(for region: RedactionRegion) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            // ── Style row ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                RedactionStylePicker(selection: region.style, isBulk: false) { style in
                    onChangeStyle(region.id, style)
                }
            }

            if region.style.supportsStrength {
                Text("Blur and pixelation can leave details recognizable. Use Solid for secrets and identifying text.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // ── Emoji row ─────────────────────────────────────────────────
            if region.style == .emoji {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Emoji")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RedactionEmojiPicker(selection: region.emoji) { emoji in
                        onChangeEmoji(region.id, emoji)
                    }
                }
            }
            if region.type == .face, let onApplyToAllFaces,
               regions.contains(where: { $0.type == .face && $0.id != region.id }) {
                Button {
                    onApplyToAllFaces(region.id)
                } label: {
                    Label("Use this cover for every face", systemImage: "face.smiling")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("applyToAllFacesButton")
            }
            // ── Colour row (suppressed for pixelate / blur) ───────────────
            if region.style.supportsColor {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    RedactionColorPicker(selection: region.color, isBulk: false) { color in
                        onChangeColor(region.id, color)
                    }
                }
            }

            // ── Strength row (pixelate / blur only) ───────────────────────
            if region.style.supportsStrength {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Strength")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    RedactionStrengthSlider(selection: region.strength, isBulk: false) { strength in
                        onChangeStrength(region.id, strength)
                    }
                    // A new region gets a new slider, not the last one's thumb.
                    .id(region.id)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.18), value: region.style)
        .animation(.easeInOut(duration: 0.18), value: region.color)
    }

    // MARK: - Bulk Style + Colour Panel

    /// Style / colour panel shown in multi-select mode.
    ///
    /// Neither style nor colour shows an "active" selection when the set of selected
    /// regions has mixed values; tapping any option applies it to all selected regions.
    /// When all selected regions share the same style or colour, that option is highlighted.
    @ViewBuilder
    private func bulkStyleColorPanel() -> some View {
        let selectedRegions = regions.filter { multiSelectedIDs.contains($0.id) }

        // Shared style (non-nil only when ALL selected agree)
        let sharedStyle: RedactionStyle? = {
            let styles = Set(selectedRegions.map(\.style))
            return styles.count == 1 ? styles.first : nil
        }()

        // Shared colour (non-nil only when ALL selected agree and support colour)
        let sharedColor: RedactionColor? = {
            let colours = Set(selectedRegions.map(\.color))
            return colours.count == 1 ? colours.first : nil
        }()

        // Show colour row unless NONE of the selected regions can take a colour
        let showColorRow = selectedRegions.contains { $0.style.supportsColor }

        // Strength applies to pixelate / blur regions only
        let strengthRegions = selectedRegions.filter(\.style.supportsStrength)
        let sharedStrength: Double? = {
            let strengths = Set(strengthRegions.map(\.strength))
            return strengths.count == 1 ? strengths.first : nil
        }()

        VStack(alignment: .leading, spacing: 10) {

            // Context label
            Text("Apply to ^[\(multiSelectedIDs.count) region](inflect: true)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // ── Style row ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Style")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                RedactionStylePicker(selection: sharedStyle, isBulk: true) { style in
                    onBulkChangeStyle(multiSelectedIDs, style)
                }
            }

            if selectedRegions.contains(where: { $0.style.supportsStrength }) {
                Text("Blur and pixelation can leave details recognizable. Use Solid for secrets and identifying text.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // ── Emoji row ─────────────────────────────────────────────────
            let emojiRegions = selectedRegions.filter { $0.style == .emoji }
            if !emojiRegions.isEmpty {
                let emojis = Set(emojiRegions.map(\.emoji))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Emoji")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RedactionEmojiPicker(selection: emojis.count == 1 ? emojis.first : nil) { emoji in
                        onBulkChangeEmoji(Set(emojiRegions.map(\.id)), emoji)
                    }
                }
            }

            // ── Colour row ────────────────────────────────────────────────
            if showColorRow {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    RedactionColorPicker(selection: sharedColor, isBulk: true) { color in
                        onBulkChangeColor(multiSelectedIDs, color)
                    }
                }
            }

            // ── Strength row ──────────────────────────────────────────────
            if !strengthRegions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Strength")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    RedactionStrengthSlider(selection: sharedStrength, isBulk: true) { strength in
                        onBulkChangeStrength(multiSelectedIDs, strength)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Region Row

    @ViewBuilder
    private func regionRow(_ region: RedactionRegion) -> some View {
        let isSingleSelected = !isMultiSelectMode && region.id == selectedRegionID
        let isMultiChecked   = isMultiSelectMode  && multiSelectedIDs.contains(region.id)
        let isHighlighted    = isSingleSelected || isMultiChecked

        Button {
            if isMultiSelectMode {
                if multiSelectedIDs.contains(region.id) {
                    multiSelectedIDs.remove(region.id)
                } else {
                    multiSelectedIDs.insert(region.id)
                }
            } else {
                onSelect(isSingleSelected ? nil : region.id)
            }
        } label: {
            HStack(spacing: 12) {

                // ── Leading icon: risk-level colour for detected, accent for custom ──
                Group {
                    if let type = region.type {
                        Image(systemName: type.riskLevel.symbolName)
                            .foregroundStyle(type.riskLevel.color)
                    } else {
                        Image(systemName: "square.dashed")
                            .foregroundStyle(.accent)
                    }
                }
                .font(.callout.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(
                    (region.type.map { $0.riskLevel.color } ?? Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityHidden(true)

                // ── Middle: name + snippet + confidence + risk ──────────────
                VStack(alignment: .leading, spacing: 2) {
                    Text(region.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isSingleSelected ? Color.accentColor : .primary)

                    if let snippet = region.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    // Confidence score + risk badge on the same line
                    HStack(spacing: 6) {
                        if let score = region.score {
                            Text(ConfidenceLevel(score: score).matchLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let type = region.type {
                            Text(type.riskLevel.shortLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(type.riskLevel.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    type.riskLevel.color.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                    }
                }

                Spacer(minLength: 8)

                // ── Trailing: checkbox in multi-select; toggle+delete in normal ──
                if isMultiSelectMode {
                    Image(systemName: isMultiChecked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isMultiChecked ? Color.accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                } else {
                    HStack(spacing: 0) {
                        // Enable / disable toggle
                        Button {
                            onToggleRegion(region.id)
                        } label: {
                            Image(systemName: region.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(region.isEnabled ? .red : .secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(region.isEnabled
                            ? "Disable redaction for \(region.displayName)"
                            : "Enable redaction for \(region.displayName)")
                        .accessibilityIdentifier("toggleRegionButton-\(region.id)")

                        // Delete
                        Button {
                            onDeleteRegion(region.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(region.displayName) region")
                        .accessibilityIdentifier("deleteRedactionButton")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHighlighted ? Color.accentColor.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(region.isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: region.displayName))
        // The trait, not a hand-appended ", selected": VoiceOver announces it in
        // the user's language.
        .accessibilityAddTraits(isSingleSelected ? .isSelected : [])
        .accessibilityHint(
            isMultiSelectMode
                ? (isMultiChecked ? "Double tap to deselect" : "Double tap to add to selection")
                : (isSingleSelected ? "Double tap to deselect" : "Double tap to select and highlight on image")
        )
        .accessibilityIdentifier("regionRow-\(region.id)")
        .accessibilityAction(named: region.isEnabled ? "Disable redaction" : "Enable redaction") {
            onToggleRegion(region.id)
        }
        .accessibilityAction(named: "Delete redaction") {
            onDeleteRegion(region.id)
        }
    }
}
