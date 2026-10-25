import SwiftUI

nonisolated struct RedactionOutlineShape: Shape {
    let shape: RedactionShape
    var vertices: [CGPoint] = []

    func path(in rect: CGRect) -> Path { Path(shape.path(in: rect, vertices: vertices)) }
}

struct RedactionShapePicker: View {
    let selection: RedactionShape
    let onSelect: (RedactionShape) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { choices }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) { choices }
        }
    }

    private var choices: some View {
        ForEach(RedactionShape.allCases, id: \.self) { shape in
            Button { onSelect(shape) } label: {
                VStack(spacing: 4) {
                    Image(systemName: shape.symbolName)
                    Text(shape.displayName).font(.caption).fixedSize()
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 4)
                .foregroundStyle(selection == shape ? Color.accentColor : .primary)
                .background(selection == shape ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == shape ? .isSelected : [])
            .accessibilityIdentifier("shapeButton-\(shape.rawValue)")
        }
    }
}

/// The outline can be traced with a finger or edited a vertex at a time.
/// Nothing changes in the document until Save; the whole edit is one undo.
struct RedactionOutlineEditor: View {
    let region: RedactionRegion
    let image: UIImage?
    let onSave: ([CGPoint]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var vertices: [CGPoint] = []
    @State private var isDrawing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Trace an outline. Lift your finger to close it, or adjust its points below.")
                        .font(.callout).foregroundStyle(.secondary)
                    drawingArea
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxHeight: 350)
                        .accessibilityLabel("Custom outline preview")
                    Button("Reset Outline") { vertices = RedactionShape.defaultVertices }
                        .frame(minHeight: 44)
                    ForEach(vertices.indices, id: \.self) { index in
                        VStack(alignment: .leading) {
                            Text("Point \(index + 1)").font(.headline)
                            coordinate("Horizontal position", index: index, keyPath: \.x)
                            coordinate("Vertical position", index: index, keyPath: \.y)
                            if vertices.count > 3 {
                                Button("Remove Point", role: .destructive) { vertices.remove(at: index) }
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    Button("Add Point") {
                        guard let last = vertices.last, let first = vertices.first, vertices.count < 32 else { return }
                        vertices.append(CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
                    }
                    .frame(minHeight: 44)
                    .disabled(vertices.count >= 32)
                }.padding()
            }
            .navigationTitle("Custom Outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(vertices); dismiss() }
                        .disabled(!RedactionShape.validVertices(vertices))
                        .accessibilityIdentifier("saveOutlineButton")
                }
            }
            .onAppear { vertices = RedactionShape.validVertices(region.vertices) ? region.vertices : RedactionShape.defaultVertices }
        }
    }

    private var aspect: CGFloat {
        guard let image else { return 1 }
        return max(0.1, region.rect.width * image.size.width / max(1, region.rect.height * image.size.height))
    }

    private var drawingArea: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color(.secondarySystemBackground)
                if let image {
                    Image(uiImage: image).resizable()
                        .frame(width: size.width / region.rect.width, height: size.height / region.rect.height)
                        .offset(x: -region.rect.minX * size.width / region.rect.width,
                                y: -region.rect.minY * size.height / region.rect.height)
                }
                let path = Path(RedactionShape.custom.path(in: CGRect(origin: .zero, size: size), vertices: vertices))
                path.fill(Color.accentColor.opacity(0.3))
                path.stroke(Color.accentColor, lineWidth: 3)
                ForEach(vertices.indices, id: \.self) { index in
                    Text("\(index + 1)").font(.caption2.bold())
                        .padding(4).background(.background, in: Circle())
                        .position(x: vertices[index].x * size.width, y: vertices[index].y * size.height)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                if !isDrawing { vertices = []; isDrawing = true }
                let point = CGPoint(x: min(1, max(0, value.location.x / size.width)),
                                    y: min(1, max(0, value.location.y / size.height)))
                if vertices.count < 256, vertices.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.015 }) ?? true {
                    vertices.append(point)
                }
            }.onEnded { _ in isDrawing = false })
        }
    }

    private func coordinate(_ label: LocalizedStringKey, index: Int, keyPath: WritableKeyPath<CGPoint, CGFloat>) -> some View {
        Slider(value: Binding(get: { vertices.indices.contains(index) ? vertices[index][keyPath: keyPath] : 0 },
                              set: { if vertices.indices.contains(index) { vertices[index][keyPath: keyPath] = $0 } }), in: 0...1, step: 0.01) {
            Text(label)
        }
        .accessibilityValue(Text(Double(vertices[index][keyPath: keyPath]), format: .percent.precision(.fractionLength(0))))
    }
}
