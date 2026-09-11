import SwiftUI
import AppKit
import DevCleanerProCore

/// The row checkbox: on, off, or mixed.
///
/// A real `NSButton`, not a SwiftUI `Button` or a hand-drawn shape with a tap gesture. Two
/// reasons, both learned the hard way:
///
/// 1. **First-click delivery.** A `List` with a selection binding is an `NSTableView`
///    underneath, and its row click handling swallows the first click. A SwiftUI `Button` inside
///    such a row needs a *second* click to fire, which reads as "the checkbox is disabled" until
///    you click at it hard enough for one to land as a double-click. An `NSButton` is a real
///    control in the cell and gets the click the first time, every time.
/// 2. **Tri-state is native.** `allowsMixedState` is exactly the "some children selected" case,
///    and AppKit draws the dash, the focus ring and the disabled appearance correctly — in both
///    themes, at every accent colour, without reimplementing any of it.
struct TriStateToggle: NSViewRepresentable {
    let state: CheckState
    let isBlocked: Bool
    let blockedReason: String?
    let toggle: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator,
                              action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        // The row owns the label; the checkbox is the control only.
        button.imagePosition = .imageOnly
        button.setButtonType(.switch)
        button.focusRingType = .default
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.state = switch state {
        case .on: .on
        case .off: .off
        case .partial: .mixed
        }
        button.isEnabled = !isBlocked
        button.toolTip = blockedReason
        button.setAccessibilityLabel(accessibilityLabel)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(toggle: toggle)
    }

    private var accessibilityLabel: String {
        if let blockedReason { return "Cannot be selected: \(blockedReason)" }
        return switch state {
        case .on: "Selected"
        case .partial: "Partly selected"
        case .off: "Not selected"
        }
    }

    final class Coordinator: NSObject {
        var toggle: () -> Void

        init(toggle: @escaping () -> Void) {
            self.toggle = toggle
        }

        @objc func clicked() {
            // The model decides the next state — clicking never lands on `mixed`, which only
            // ever results from children disagreeing. AppKit's own cycling would step
            // off → on → mixed, so its state is overwritten by `updateNSView` straight after.
            toggle()
        }
    }
}

/// Marker for a row the app will never delete, with the explanation on hover.
struct InfoMarker: View {
    let explanation: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 16)
            .help(explanation)
            .accessibilityLabel("Information only. \(explanation)")
    }
}

/// `.help("")` still installs a tooltip that flashes an empty box on hover, so the modifier is
/// applied only when there is something to say.
struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}
