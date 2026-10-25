import SwiftUI

// MARK: - Scrolling at accessibility sizes

/// A panel that fits as it is at ordinary text sizes, and scrolls at
/// accessibility sizes rather than squeezing its text into truncated lines.
///
/// It takes only the height its content needs; beside a flexible view in a
/// stack — the photo above the editor's controls — it gets at most an even
/// share, so the photo stays in view.
private struct ScrollsAtAccessibilitySizes: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight)
            .scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    /// Scrolls at accessibility text sizes; unchanged otherwise.
    func scrollsAtAccessibilitySizes() -> some View {
        modifier(ScrollsAtAccessibilitySizes())
    }
}

// MARK: - Stacking at accessibility sizes

/// Side by side at ordinary text sizes; one above the other, leading-aligned,
/// at accessibility sizes, where side by side each part gets too narrow.
struct AccessibilityStack<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: spacing))
        layout { content }
    }
}
