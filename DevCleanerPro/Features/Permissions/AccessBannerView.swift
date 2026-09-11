import SwiftUI
import DevCleanerProCore

/// The dismissible Full Disk Access banner.
///
/// Worded to name what is actually unmeasurable rather than implying the whole scan is
/// compromised — most of what this app measures needs no grant at all
/// (`docs/00-decisions.md`, corrections).
struct AccessBannerView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("Full Disk Access not granted — \(FullDiskAccess.affectedAreas) can't be measured.")
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Button("Open System Settings") { state.openFullDiskAccessSettings() }
                .controlSize(.small)

            Button {
                state.bannerDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
