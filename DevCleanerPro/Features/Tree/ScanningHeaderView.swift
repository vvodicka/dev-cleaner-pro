import SwiftUI
import DevCleanerProCore

/// Inline progress while scanning. Partial results stay visible beneath it, which is the point:
/// the sizes that are already known are usable immediately (FR-1.2).
struct ScanningHeaderView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)

            Text(state.scanProgressLabel)
                .font(.system(size: 13))

            Text("\(ByteFormatting.string(state.totalBytes)) found so far")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button("Stop") { state.cancelScan() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}
