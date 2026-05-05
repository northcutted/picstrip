import SwiftUI
import UIKit

// MARK: - BatchSummaryView

/// Pushed onto the BatchConfigView NavigationStack once `processBatch` finishes.
/// Shows a completion headline, aggregate stats, and a JSON audit log export button.
struct BatchSummaryView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var auditURL: URL? = nil

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

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)

                // ── Success icon ────────────────────────────────────────────
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)

                // ── Headline ────────────────────────────────────────────────
                VStack(spacing: 6) {
                    Text("Batch Complete")
                        .font(.title2.weight(.bold))
                    Text("Successfully cleaned and saved ^[\(viewModel.batchItems.count) photo](inflect: true).")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
        let photos     = viewModel.batchItems.count

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
