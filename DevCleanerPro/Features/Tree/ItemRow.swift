import SwiftUI
import DevCleanerProCore

/// One row of the unified tree.
///
/// Layout and metrics come from the component spec: indent `14 + 19 × depth`, module rows 34 pt
/// and bold on a tinted background, everything else 30 pt, risk column 78, size column 84 and
/// right-aligned in monospaced digits so the column does not jitter while modules finish.
struct ItemRow: View {
    @Environment(AppState.self) private var state
    let row: FlatRow

    private var node: ScanNode { row.node }
    private var checkState: CheckState { state.selection.state(of: node.id) }

    var body: some View {
        HStack(spacing: 2) {
            disclosure
            marker

            Spacer().frame(width: 6)

            if row.isModuleRow {
                Image(systemName: moduleSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }

            Text(node.title)
                .font(.system(size: row.isModuleRow ? 13.5 : 13,
                              weight: row.isModuleRow ? .bold : .regular))
                .foregroundStyle(node.isSelectable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            if let subtitle = node.subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Group {
                if !row.isModuleRow {
                    // The rolled-up risk, so a group never claims "Safe" while something
                    // beneath it is "Careful".
                    RiskBadge(risk: node.rolledUpRisk)
                }
            }
            .frame(width: 78, alignment: .leading)

            Text(ByteFormatting.string(node.size))
                .font(.system(size: row.isModuleRow ? 13.5 : 13,
                              weight: row.isModuleRow ? .bold : .regular)
                    .monospacedDigit())
                .foregroundStyle(node.isSelectable ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.leading, row.indent)
        .padding(.trailing, 14)
        .frame(height: row.height)
        .background(row.isModuleRow ? Color(nsColor: .controlBackgroundColor) : .clear)
        .contentShape(.rect)
        .modifier(OptionalHelp(text: node.blockedReason))
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var disclosure: some View {
        if node.hasChildren {
            // Same first-click problem as the checkbox, same remedy — see `TriStateToggle`.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(state.isExpanded(node.id) ? 90 : 0))
                .frame(width: 14, height: 14)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .simultaneousGesture(TapGesture().onEnded {
                    state.toggleExpanded(node.id)
                })
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(state.isExpanded(node.id) ? "Collapse" : "Expand")
        } else {
            // Not `Color.clear`, which is hit-testable and would quietly swallow clicks
            // aimed at the checkbox beside it.
            Spacer().frame(width: 22, height: 14)
        }
    }

    @ViewBuilder
    private var marker: some View {
        if !node.isSelectable {
            InfoMarker(explanation: node.subtitle ?? node.risk.explanation)
        } else {
            TriStateToggle(
                state: checkState,
                isBlocked: node.isBlocked,
                blockedReason: node.blockedReason
            ) {
                state.toggleSelection(node)
            }
            .frame(width: 16, height: 18)
        }
    }

    /// Read as one sentence: what it is, how big, how risky, and why it cannot be touched.
    /// Spelling it out beats VoiceOver reading five sibling elements in isolation.
    private var accessibilitySummary: String {
        var parts = [node.title, ByteFormatting.string(node.size)]
        if !row.isModuleRow { parts.append("risk \(node.rolledUpRisk.displayLabel)") }
        if let subtitle = node.subtitle { parts.append(subtitle) }
        if let blocked = node.blockedReason { parts.append("cannot be selected: \(blocked)") }
        else if !node.isSelectable { parts.append("information only") }
        else { parts.append(state.selection.state(of: node.id) == .on ? "selected" : "not selected") }
        if node.hasChildren {
            parts.append(state.isExpanded(node.id) ? "expanded" : "collapsed")
        }
        return parts.joined(separator: ", ")
    }

    private var moduleSymbol: String {
        state.modules.first { $0.id == node.id }?.systemImage ?? "folder"
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !node.isSelectable {
            Button("Copy commands") { state.copyToClipboard(commandsText) }
        } else {
            if node.url != nil {
                Button("Reveal in Finder") { state.reveal(node) }
            }
            Button("Select all safe") { state.selectAllSafe(under: node) }
            Button("Select all") { state.selectAll(under: node) }
        }

        Divider()

        if let url = node.url {
            Button("Copy path") { state.copyToClipboard(url.path) }
        }
        if case .command(let exe, let args, _) = node.action {
            Button("Copy command") {
                state.copyToClipboard(([exe] + args).joined(separator: " "))
            }
        }

        if row.isModuleRow {
            Divider()
            Button("Rescan module") { state.rescan(moduleID: node.id) }
            Button("Collapse others") { state.collapseOthers(keeping: node.id) }
            Button("Hide module") { state.hideModule(node.id) }
        }
    }

    /// Info rows exist to tell the user what to run by hand, so the menu hands them the text.
    private var commandsText: String {
        var lines: [String] = []
        node.forEachNode { child in
            if case .command(let exe, let args, _) = child.action {
                lines.append(([exe] + args).joined(separator: " "))
            }
        }
        if lines.isEmpty, let subtitle = node.subtitle { lines.append(subtitle) }
        return lines.joined(separator: "\n")
    }
}
