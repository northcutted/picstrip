import SwiftUI

// MARK: - BatchConfigView

/// Half-sheet presented when the user selects multiple photos.
/// Collects a global privacy policy (BatchConfig) and drives the sequential
/// processing loop.  Transitions to BatchSummaryView via a NavigationStack
/// push once `viewModel.batchComplete` becomes true.
struct BatchConfigView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var config = BatchConfig()
    @State private var showReplaceConfirm = false

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(isPresented: $viewModel.batchComplete) {
                    BatchSummaryView(viewModel: viewModel)
                }
                .navigationTitle(viewModel.isBatchProcessing ? "Processing…" : "Batch Process")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !viewModel.isBatchProcessing {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                viewModel.clearBatchState()
                                dismiss()
                            }
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(viewModel.isBatchProcessing)
        .onAppear {
            // Default export format for batch is PNG (maximum privacy).
            viewModel.selectedExportFormat = .png
            config.outputFormat = .png
        }
    }

    // MARK: - Content switcher

    @ViewBuilder
    private var content: some View {
        if viewModel.isBatchProcessing {
            progressView
        } else {
            configForm
        }
    }

    // MARK: - Config form

    private var configForm: some View {
        ScrollView {
            VStack(spacing: 20) {

                // ── Header ─────────────────────────────────────────────────
                HStack(spacing: 14) {
                    Image(systemName: "photo.stack")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(viewModel.batchItems.count) Photos Selected")
                            .font(.headline)
                        Text("Apply a single privacy policy to all of them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                // ── Privacy Policy toggles ──────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("PRIVACY POLICY")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        Toggle("Strip Privacy Metadata", isOn: $config.stripMetadata)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)

                        Divider()
                            .padding(.leading, 16)

                        Toggle("Redact Sensitive Visual Data", isOn: $config.redactVisualPII)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                // ── Save Mode picker ────────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVE MODE")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Picker("Save Mode", selection: $config.saveMode) {
                        Text("Save as New").tag(BatchSaveMode.saveAsNew)
                        Text("Replace Original").tag(BatchSaveMode.replaceOriginal)
                    }
                    .pickerStyle(.segmented)

                    if config.saveMode == .replaceOriginal {
                        Text("Original photos will be permanently deleted after cleaning.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                }

                // ── Export Format picker ────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text("EXPORT FORMAT")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    AdvancedOptionsView(
                        viewModel: viewModel,
                        hasPII: config.redactVisualPII
                    )
                }

                // ── Start button ────────────────────────────────────────────
                Button(role: config.saveMode == .replaceOriginal ? .destructive : nil) {
                    config.outputFormat = viewModel.selectedExportFormat
                    if config.saveMode == .replaceOriginal {
                        showReplaceConfirm = true
                    } else {
                        Task { await viewModel.processBatch(config: config) }
                    }
                } label: {
                    Label("Start Batch Process", systemImage: "play.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .alert(
                    "Replace \(viewModel.batchItems.count) Original Photo\(viewModel.batchItems.count == 1 ? "" : "s")?",
                    isPresented: $showReplaceConfirm
                ) {
                    Button("Replace", role: .destructive) {
                        Task { await viewModel.processBatch(config: config) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("The original photos will be permanently deleted after cleaning. This cannot be undone.")
                }

                // Error banner (e.g. photo library access denied)
                if let error = viewModel.batchErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Progress view

    private var progressView: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            VStack(spacing: 8) {
                Text("Processing Photos")
                    .font(.title3.weight(.semibold))
                Text("\(viewModel.batchProgress.current) of \(viewModel.batchProgress.total)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: viewModel.batchProgress.current)
            }

            ProgressView(
                value: Double(viewModel.batchProgress.current),
                total:  Double(max(viewModel.batchProgress.total, 1))
            )
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)
            .animation(.easeInOut(duration: 0.4), value: viewModel.batchProgress.current)

            Text("Please keep the app open.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    BatchConfigView(viewModel: {
        let vm = ScrubberViewModel()
        // Simulate 5 items selected
        return vm
    }())
}
