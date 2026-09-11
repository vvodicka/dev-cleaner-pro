import SwiftUI
import DevCleanerProCore

/// Frame 1e. Per-item status while deleting, with failures called out in place rather than
/// summarised away.
struct DeleteProgressSheet: View {
    @Environment(AppState.self) private var state
    @Bindable var progress: DeleteProgress

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.isFinished ? finishedHeadline : progress.headline)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(progress.byteProgress)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(progress.failureCount > 0 ? .orange : .accentColor)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var finishedHeadline: String {
        progress.failureCount == 0
            ? "Done — \(progress.totalCount) of \(progress.totalCount)"
            : "Finished with problems"
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(progress.outcomes) { outcome in
                    DeleteTaskRow(outcome: outcome)
                }
                if progress.remainingCount > 0 {
                    HStack(spacing: 10) {
                        Text("·").frame(width: 12)
                        Text("\(progress.remainingCount) remaining")
                            .font(.system(size: 11.5).monospaced())
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack {
            if let summary = progress.failureSummary {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !progress.isFinished {
                Button("Stop") { state.stopDelete() }
            }
            Button("Done") { state.dismissProgress() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!progress.isFinished)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

/// One row of the progress list. A failure keeps its own tinted band and puts the reason directly
/// under the path, because that is the only place the user can act on it.
struct DeleteTaskRow: View {
    let outcome: DeleteOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(systemName: outcome.succeeded ? "checkmark" : "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(outcome.succeeded ? .green : .red)
                    .frame(width: 12)

                Text(outcome.detail)
                    .font(.system(size: 11.5).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if outcome.succeeded {
                    Text(ByteFormatting.string(outcome.freed))
                        .font(.system(size: 11.5).monospacedDigit())
                }
            }
            if let error = outcome.error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(outcome.succeeded ? Color.clear : Color.red.opacity(0.07))
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }
}
