import SwiftUI
import DevCleanerProCore

/// The detail pane: banner, scanning header, column header, and one flat list of rows covering
/// every module.
///
/// A `List` over pre-flattened rows rather than nested `OutlineGroup`s: the flattener already
/// walks only expanded branches, and one flat array gives exact control over the design's
/// indent, row heights and tinted module rows — which nested disclosure groups fight against.
struct ScanTreeView: View {
    @Environment(AppState.self) private var state
    /// Keyboard focus, separate from the tri-state checkboxes: arrow keys move it and Space
    /// toggles whatever it is on, which is how a macOS list is expected to behave.
    @State private var focused: ScanNode.ID?

    var body: some View {
        VStack(spacing: 0) {
            if state.showBanner { AccessBannerView() }
            if state.isScanning { ScanningHeaderView() }

            if state.rows.isEmpty && !state.isScanning {
                NoResultsView()
            } else {
                columnHeader
                rowList
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            headerButton("Item", order: .nameAscending)
            Spacer(minLength: 8)
            Text("Risk")
                .frame(width: 78, alignment: .leading)
            headerButton("Size", order: .sizeDescending)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// FR-2.3 wants sortable columns; the design drew the header without an affordance, so the
    /// arrow is added here rather than invented elsewhere (`docs/00-decisions.md` #13).
    private func headerButton(_ title: String, order: TreeSortOrder) -> some View {
        Button {
            state.setSortOrder(order)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if state.sortOrder == order {
                    Image(systemName: order == .sizeDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var rowList: some View {
        ScrollViewReader { proxy in
            List(selection: $focused) {
                ForEach(state.rows) { row in
                    ItemRow(row: row)
                        .id(row.id)
                        .tag(row.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.visible)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 30)
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                state.scrollTarget = nil
            }
            .onKeyPress(.space) {
                guard let focused,
                      let row = state.rows.first(where: { $0.id == focused })
                else { return .ignored }
                state.toggleSelection(row.node)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard let focused,
                      let row = state.rows.first(where: { $0.id == focused }),
                      row.node.hasChildren, !state.isExpanded(focused)
                else { return .ignored }
                state.toggleExpanded(focused)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard let focused, state.isExpanded(focused) else { return .ignored }
                state.toggleExpanded(focused)
                return .handled
            }
        }
    }
}

/// Shown when the filter has hidden everything that was found.
struct NoResultsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Nothing above \(state.config.minItemSizeMB) MB")
                .font(.system(size: 15, weight: .semibold))
            Text("Everything found is smaller than the current filter.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button("Show everything") {
                state.updateConfig { $0.minItemSizeMB = 0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
