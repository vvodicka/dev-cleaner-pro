import SwiftUI
import DevCleanerProCore

/// Frame 1d. Lists every path and command that will run, grouped by module, before anything is
/// touched. In permanent mode an acknowledgement gates the button.
struct DeleteConfirmSheet: View {
    @Environment(AppState.self) private var state
    let plan: DeletionPlan

    @State private var acknowledged = false
    /// Long groups are collapsed to keep the sheet scannable; expanding shows every path.
    @State private var expandedGroups: Set<String> = []

    private static let collapseThreshold = 6

    private var isPermanent: Bool { plan.mode == .permanent }
    /// `warnOnCareful` adds the same gate to Trash mode when user data is involved.
    private var needsAcknowledgement: Bool {
        isPermanent || (state.config.warnOnCareful && plan.hasCareful)
    }
    private var canProceed: Bool { !needsAcknowledgement || acknowledged }

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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ByteFormatting.string(plan.totalBytes))
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                Text(isPermanent ? "will be freed" : "will be moved to the Trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var title: String {
        let n = plan.totalCount
        let noun = n == 1 ? "item" : "items"
        return isPermanent
            ? "Delete \(n) \(noun) permanently?"
            : "Move \(n) \(noun) to the Trash?"
    }

    private var explanation: String {
        if isPermanent {
            return "DevCleanerPro will run the operations below. Nothing goes to the Trash."
        }
        return "Items go to the Trash, so space is not reclaimed until you empty it."
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(plan.groups) { group in
                    groupHeader(group)
                    ForEach(visibleItems(of: group)) { item in
                        itemRow(item)
                    }
                    if let hidden = hiddenCount(of: group) {
                        Button {
                            expandedGroups.insert(group.id)
                        } label: {
                            HStack {
                                Text("\(hidden) more in \(group.title)")
                                Spacer()
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 7)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func visibleItems(of group: DeletionPlan.Group) -> [DeletionPlan.Item] {
        guard !expandedGroups.contains(group.id),
              group.items.count > Self.collapseThreshold
        else { return group.items }
        return Array(group.items.prefix(Self.collapseThreshold))
    }

    private func hiddenCount(of group: DeletionPlan.Group) -> Int? {
        let hidden = group.items.count - visibleItems(of: group).count
        return hidden > 0 ? hidden : nil
    }

    private func groupHeader(_ group: DeletionPlan.Group) -> some View {
        HStack {
            Text(group.title)
            Spacer()
            Text(ByteFormatting.string(group.bytes))
                .monospacedDigit()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func itemRow(_ item: DeletionPlan.Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(item.operations.enumerated()), id: \.offset) { index, operation in
                HStack(spacing: 8) {
                    if item.isCommand, index == 0 {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(operation)
                        .font(.system(size: 11.5).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if index == 0 {
                        Text(ByteFormatting.string(item.node.size))
                            .font(.system(size: 11.5).monospacedDigit())
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stated once rather than per row: the mode toggle simply does not apply to these.
            if plan.hasCommands {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("Marked items run a tool and cannot be undone, even in Trash mode.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if needsAcknowledgement {
                Toggle(isOn: $acknowledged) {
                    Text(isPermanent
                         ? "I understand this can't be undone"
                         : "I understand this includes user data")
                    .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { state.cancelDelete() }
                    .keyboardShortcut(.cancelAction)
                Button(plan.mode.confirmButtonTitle) { state.confirmDelete() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isPermanent ? .red : .accentColor)
                    .disabled(!canProceed)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
