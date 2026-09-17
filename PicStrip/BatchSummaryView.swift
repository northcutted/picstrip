import SwiftUI
import UIKit

// MARK: - BatchSummaryView

/// Pushed onto the BatchConfigView NavigationStack once `processBatch` finishes.
/// Shows a completion headline, aggregate stats, and a JSON audit log export button.
struct BatchSummaryView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var auditURL: URL?

    // MARK: - Derived stats

    private var totalFieldsStripped: Int {
        viewModel.batchReports
            .flatMap(\.metadataStripped)
            .reduce(0) { $0 + $1.strippedFields.count }
    }

    private var totalVisualRedactions: Int {
        viewModel.batchReports
            .flatMap(\.visualRedactions)
            .reduce(0) { $0 + $1.instanceCount }
    }

    private var succeeded: Int { viewModel.batchSucceededCount }
    private var failed: Int { viewModel.batchFailedCount }

    private var outcomeSymbol: String {
        if succeeded == 0 { return "xmark.octagon.fill" }
        return failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var outcomeColor: Color {
        if succeeded == 0 { return .red }
        return failed > 0 ? .orange : .green
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                // ── Outcome icon ────────────────────────────────────────────
                Image(systemName: outcomeSymbol)
                    .font(.system(size: 72))
                    .foregroundStyle(outcomeColor)
                    .accessibilityHidden(true)

                // ── Headline ────────────────────────────────────────────────
                VStack(spacing: 6) {
                    Text("Batch Complete")
                        .font(.title2.weight(.bold))
                    if succeeded > 0 {
                        Text("Successfully cleaned and saved ^[\(succeeded) photo](inflect: true).")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if failed > 0 {
                        Text("^[\(failed) photo](inflect: true) could not be cleaned. Nothing was saved for those photos.")
                            .font(.body)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("batchFailureLabel")
                    }
                }

                // ── Stats card ──────────────────────────────────────────────
                statsCard

                // ── Export JSON button ──────────────────────────────────────
                Button {
                    auditURL = viewModel.generateBatchAuditJSON()
                } label: {
                    Label("Export Batch Audit Log (JSON)", systemImage: "doc.text.magnifyingglass")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.secondary)

                Spacer(minLength: 24)
            }
            .padding(24)
        }
        .navigationTitle("Batch Complete")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    viewModel.clearBatchState()
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: Binding(
            get: { auditURL != nil },
            set: { if !$0 { auditURL = nil } }
        )) {
            if let url = auditURL {
                ActivityView(activityItems: [url])
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Stats card

    private var statsCard: some View {
        let fields     = totalFieldsStripped
        let redactions = totalVisualRedactions
        let photos     = succeeded

        return VStack(spacing: 12) {
            Label(
                "^[\(photos) photo](inflect: true) processed",
                systemImage: "photo.stack"
            )
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)

            if fields > 0 || redactions > 0 {
                Divider()
            }

            if fields > 0 {
                Label(
                    "^[\(fields) privacy field](inflect: true) stripped",
                    systemImage: "tag.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if redactions > 0 {
                Label(
                    "^[\(redactions) visual region](inflect: true) redacted",
                    systemImage: "eye.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BatchSummaryView(viewModel: ScrubberViewModel())
    }
}
