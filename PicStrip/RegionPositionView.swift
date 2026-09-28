import SwiftUI

/// The same normalized geometry used by drag gestures, exposed to VoiceOver and Switch Control.
struct RegionPositionView: View {
    let region: RedactionRegion
    let onAdjust: (String, CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rect = CGRect.zero

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coordinate("Horizontal position", keyPath: \.origin.x, range: 0...max(0.001, 1 - rect.width))
                    coordinate("Vertical position", keyPath: \.origin.y, range: 0...max(0.001, 1 - rect.height))
                    coordinate("Width", keyPath: \.size.width, range: 0.01...max(0.01, 1 - rect.minX))
                    coordinate("Height", keyPath: \.size.height, range: 0.01...max(0.01, 1 - rect.minY))
                } footer: {
                    Text("Positions are measured from the top-left of the image. Each adjustment can be undone.")
                }
            }
            .navigationTitle("Position & size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { rect = region.rect }
        }
    }

    private func coordinate(_ title: LocalizedStringKey, keyPath: WritableKeyPath<CGRect, CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(Double(rect[keyPath: keyPath]), format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, rect[keyPath: keyPath])) },
                                  set: { rect[keyPath: keyPath] = $0 }), in: range, step: 0.01) {
                Text(title)
            } onEditingChanged: { editing in
                if !editing { onAdjust(region.id, rect) }
            }
            .accessibilityValue(Text(Double(rect[keyPath: keyPath]), format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 0.01 : -0.01
                rect[keyPath: keyPath] = min(range.upperBound, max(range.lowerBound, rect[keyPath: keyPath] + delta))
                onAdjust(region.id, rect)
            }
            .frame(minHeight: 44)
        }
    }
}
