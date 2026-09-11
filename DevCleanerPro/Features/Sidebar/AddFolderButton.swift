import SwiftUI
import DevCleanerProCore

/// "Add folder…" — the same thing the Custom locations settings tab does, put where it can
/// actually be found.
///
/// The setting itself lives in `config.json`, so a folder added here is still there after a
/// restart, and can equally be edited by hand or in Settings.
struct AddFolderButton: View {
    @Environment(AppState.self) private var state

    /// `.prominent` for the empty state, `.compact` for the sidebar footer.
    enum Style { case prominent, compact }
    var style: Style = .compact

    @State private var showingImporter = false
    @State private var refusal: String?

    var body: some View {
        button
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                guard case .success(let urls) = result else { return }
                for url in urls {
                    if case .refused(let reason) = state.addCustomLocation(url) {
                        refusal = reason
                        break
                    }
                }
            }
            .alert("Cannot add that folder", isPresented: Binding(
                get: { refusal != nil },
                set: { if !$0 { refusal = nil } }
            )) {
                Button("OK") { refusal = nil }
            } message: {
                Text(refusal ?? "")
            }
    }

    @ViewBuilder
    private var button: some View {
        switch style {
        case .prominent:
            Button {
                showingImporter = true
            } label: {
                Label("Add a folder to scan…", systemImage: "plus")
            }
            .help("Scan a folder of your own alongside the built-in modules")

        case .compact:
            Button {
                showingImporter = true
            } label: {
                Label("Add folder…", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Scan a folder of your own alongside the built-in modules. "
                  + "It is remembered between launches.")
        }
    }
}
