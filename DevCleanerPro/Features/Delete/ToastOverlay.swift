import SwiftUI

/// Transient confirmation, bottom-centre. In Trash mode it offers to empty the Trash, because
/// moving files there has not actually reclaimed anything yet.
struct ToastOverlay: View {
    @Environment(AppState.self) private var state
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 13))
            if toast.offersEmptyTrash {
                Button("Empty Trash") { state.emptyTrash() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(radius: 12, y: 4)
        .padding(.bottom, 60)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            // Long enough to read and act on, short enough not to sit in the way.
            try? await Task.sleep(for: .seconds(toast.offersEmptyTrash ? 8 : 3))
            state.dismissToast()
        }
    }
}
