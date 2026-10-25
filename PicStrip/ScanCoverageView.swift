import SwiftUI

struct ScanCoverageView: View {
    @Bindable var viewModel: ScrubberViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.scanCoverage.requiresManualReview {
                Label("Some checks could not finish", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Inspect the whole photo and cover anything private before continuing.")
                    .font(.subheadline)
                Button {
                    viewModel.manualReviewAcknowledged.toggle()
                } label: {
                    Label("I reviewed this photo manually", systemImage: viewModel.manualReviewAcknowledged ? "checkmark.circle.fill" : "circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                    .buttonStyle(.bordered)
                    .accessibilityAddTraits(viewModel.manualReviewAcknowledged ? .isSelected : [])
                    .accessibilityIdentifier("manualReviewAcknowledgement")
            }

            if viewModel.findingsLeftVisible > 0 {
                Label("^[\(viewModel.findingsLeftVisible) finding](inflect: true) not covered",
                      systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
            }
            let retained = viewModel.outputFileFields.filter { !$0.isStructural }.count
            if retained > 0 {
                Label("^[\(retained) metadata field](inflect: true) retained", systemImage: "tag")
                    .font(.subheadline)
            }

            DisclosureGroup {
                ForEach(ScanCoverage.Check.allCases, id: \.self) { check in
                    HStack(alignment: .top) {
                        Text(check.title)
                        Spacer()
                        Text(viewModel.scanCoverage[check].title)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            } label: {
                // A full-height row, not just the line of text, to open it.
                Text("Checks performed")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .font(.subheadline)

            Text("Automatic detection can miss details. Names are optional and are not covered automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
