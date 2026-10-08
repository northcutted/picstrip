import SwiftUI

// MARK: - BatchConfigView

/// Sheet presented when the user picks several photos, several videos, or
/// photos and videos together.
/// Collects a global privacy policy (BatchConfig) and drives the sequential
/// processing loop.  Transitions to BatchSummaryView via a NavigationStack
/// push once `viewModel.batchComplete` becomes true.
struct BatchConfigView: View {

    @Bindable var viewModel: ScrubberViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // A long batch must not stop because the phone locked itself.
        .onChange(of: viewModel.isBatchProcessing) { _, isProcessing in
            UIApplication.shared.isIdleTimerDisabled = isProcessing
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onAppear {
            // HEIC by default: a batch is mostly camera photos, and PNG made
            // each one several times larger and slower to encode and save.
            viewModel.selectedExportFormat = .heic
            config.outputFormat = .heic
        }
    }

    private var hasVideos: Bool { viewModel.batchVideoCount > 0 }
    private var hasPhotos: Bool { viewModel.batchCount > 0 }

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
                    Image(systemName: hasVideos ? "photo.on.rectangle.angled" : "photo.stack")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        if hasVideos {
                            Text(hasPhotos ? "Photos and Videos" : "Videos")
                                .font(.headline)
                            Text(hasPhotos
                                 ? "Photos: \(viewModel.batchCount) · Videos: \(viewModel.batchVideoCount)"
                                 : "Videos: \(viewModel.batchVideoCount)")
                                .font(.subheadline)
                                .monospacedDigit()
                        } else {
                            Text("^[\(viewModel.batchCount) Photo](inflect: true) Selected")
                                .font(.headline)
                        }
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
                        .accessibilityAddTraits(.isHeader)
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

                    if hasVideos {
                        Text(config.redactVisualPII
                             ? "In videos, every face found is blurred and text and codes are covered, with nothing reviewed — open a video on its own to check each cover. Videos always lose their location, device and dates."
                             : "Videos always lose their location, device and dates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }

                if hasVideos {
                    Label {
                        Text("Videos are scanned frame by frame and saved again, which can take several minutes each. Keep PicStrip open; the screen stays on until the batch is done.")
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock").foregroundStyle(.orange)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("videoBatchNote")
                }

                // ── Save Mode picker ────────────────────────────────────────
                // Captured pages were never in the library: nothing to replace.
                if viewModel.batchAllowsReplaceOriginal {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SAVE MODE")
                            .accessibilityAddTraits(.isHeader)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        Picker("Save Mode", selection: $config.saveMode) {
                            Text("Save as New").tag(BatchSaveMode.saveAsNew)
                            Text("Replace Original").tag(BatchSaveMode.replaceOriginal)
                        }
                        .pickerStyle(.segmented)

                        if config.saveMode == .replaceOriginal {
                            Label {
                                Text(hasVideos
                                     ? "The originals will be permanently deleted after cleaning."
                                     : "Original photos will be permanently deleted after cleaning.")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                            .font(.caption)
                            .padding(.horizontal, 4)
                        }
                    }
                }

                // ── Export Format picker (photos; videos stay videos) ───────
                if hasPhotos {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("EXPORT FORMAT")
                            .accessibilityAddTraits(.isHeader)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)

                        // No PNG recommendation here: it is for a single photo of
                        // text, and a batch — mostly camera photos — is HEIC by default.
                        AdvancedOptionsView(viewModel: viewModel)
                    }
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
                .disabled(!config.hasWork)
                .accessibilityHint(config.hasWork ? "" : "Turn on at least one privacy option to start.")
                .alert(
                    hasVideos ? "Replace the Originals?" : "Replace ^[\(viewModel.batchCount) Original Photo](inflect: true)?",
                    isPresented: $showReplaceConfirm
                ) {
                    Button("Replace", role: .destructive) {
                        Task { await viewModel.processBatch(config: config) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(hasVideos
                         ? "The original photos and videos will be permanently deleted after cleaning. This cannot be undone."
                         : "The original photos will be permanently deleted after cleaning. This cannot be undone.")
                }

                if !config.hasWork {
                    Text("Turn on at least one privacy option to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }

                // Error banner (e.g. photo library access denied)
                if let error = viewModel.batchErrorMessage {
                    // Colour on the icon only: red footnote text is not legible enough.
                    Label {
                        Text(error).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    .font(.footnote)
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
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(hasVideos ? "Cleaning Photos and Videos" : "Processing Photos")
                    .font(.title3.weight(.semibold))
                Text("\(viewModel.batchProgress.current) of \(viewModel.batchProgress.total)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: viewModel.batchProgress.current)
            }

            ProgressView(
                value: Double(viewModel.batchProgress.current),
                total: Double(max(viewModel.batchProgress.total, 1))
            )
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)
            .animation(.easeInOut(duration: 0.4), value: viewModel.batchProgress.current)
            .accessibilityLabel("Processing photos, \(viewModel.batchProgress.current) of \(viewModel.batchProgress.total) complete")

            if let fraction = viewModel.batchVideoFraction {
                VStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text("This video: \(fraction, format: .percent.precision(.fractionLength(0)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 40)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("batchVideoProgress")
            }

            Button("Stop batch") { viewModel.cancelBatch() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stopBatchButton")
            Text(hasVideos ? "Keep PicStrip open. The screen stays on until the batch is done." : "Please keep the app open.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding()
        .scrollsAtAccessibilitySizes()
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
