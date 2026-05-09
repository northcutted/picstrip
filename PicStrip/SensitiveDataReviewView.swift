import SwiftUI

/// Sheet presenting a scrollable list of every detected PII type with
/// per-type redaction toggles and bulk "Redact All" / "Deselect All" controls.
///
/// Opened from the "Sensitive data found" banner in the control panel.
/// Tapping a row calls `focusPIIResult(_:)` so the canvas highlights that
/// detection type when the sheet is dismissed.
struct SensitiveDataReviewView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    private var allRedacted: Bool {
        !viewModel.detectedPII.isEmpty &&
        viewModel.detectedPII.allSatisfy { viewModel.typesToRedact.contains($0.type) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.detectedPII) { result in
                        SensitiveDataRowView(
                            result: result,
                            isEnabled: viewModel.typesToRedact.contains(result.type),
                            onToggle: { toggleType(result.type) },
                            onFocus: { viewModel.focusPIIResult(result) }
                        )
                        .accessibilityIdentifier("sensitiveDataRow_\(result.type.rawValue)")
                    }
                } header: {
                    Text("^[\(viewModel.detectedPII.count) type](inflect: true) detected")
                        .textCase(nil)
                }
            }
            .navigationTitle("Sensitive Data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allRedacted ? "Deselect All" : "Redact All") {
                        if allRedacted {
                            viewModel.typesToRedact = []
                        } else {
                            viewModel.typesToRedact = Set(viewModel.detectedPII.map(\.type))
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("sensitiveDataDoneButton")
                }
            }
            .accessibilityIdentifier("sensitiveDataReview")
        }
    }

    private func toggleType(_ type: PIIType) {
        if viewModel.typesToRedact.contains(type) {
            viewModel.typesToRedact.remove(type)
        } else {
            viewModel.typesToRedact.insert(type)
        }
    }
}

// MARK: - Row

private struct SensitiveDataRowView: View {

    let result: DetectionResult
    let isEnabled: Bool
    let onToggle: () -> Void
    let onFocus: () -> Void

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 12) {

                // Confidence icon
                Image(systemName: confidenceIcon(result.confidence))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(confidenceColor(result.confidence))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                // Type name + instance count + score
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.type.description)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(
                        "^[\(result.matchCount) instance](inflect: true) · \(result.scorePercent)% confidence"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // Per-type redaction toggle
                Toggle(
                    "Redact \(result.type.description)",
                    isOn: Binding(get: { isEnabled }, set: { _ in onToggle() })
                )
                .labelsHidden()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isEnabled
                ? "\(result.type.description): redacting \(result.matchCount) instances"
                : "\(result.type.description): not redacting \(result.matchCount) instances"
        )
    }

    // MARK: Confidence helpers (mirrors ContentView)

    private func confidenceIcon(_ level: ConfidenceLevel) -> String {
        switch level {
        case .high:   return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low:    return "info.circle.fill"
        }
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .blue
        }
    }
}
