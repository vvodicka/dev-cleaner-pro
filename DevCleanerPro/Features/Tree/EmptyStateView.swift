import SwiftUI
import DevCleanerProCore

/// Frame 1g. Shown before the first scan — which, with auto-scan on, most launches skip.
struct EmptyStateView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "internaldrive")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)

            Text("No scan yet")
                .font(.system(size: 17, weight: .semibold))

            Text("DevCleanerPro measures developer caches, build products and simulator data. "
                 + "Nothing is deleted until you select it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            HStack(spacing: 10) {
                Button("Scan Now") { state.rescanAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                AddFolderButton(style: .prominent)
                    .controlSize(.large)
            }

            Text("⌘R · \(state.lastScanFinished == nil ? "Last scan: never" : state.scanSummary)")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
