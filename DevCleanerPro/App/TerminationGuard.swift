import AppKit
import SwiftUI

/// App-level lifecycle: quit when the window closes, and never quit out from under a running
/// deletion.
@MainActor
final class TerminationGuard: NSObject, NSApplicationDelegate {
    /// Set once at launch. Weak so the delegate never keeps the state alive.
    weak var state: AppState?

    private var windowObserver: (any NSObjectProtocol)?
    private var isTerminating = false

    /// This is a launch, clean, quit tool — doc 00 is explicit that it is "not a background app".
    /// A process still alive behind a closed window would make it exactly that.
    @objc func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    /// Belt and braces for the above.
    ///
    /// `applicationShouldTerminateAfterLastWindowClosed` depends on AppKit agreeing that the last
    /// window has gone, and SwiftUI's `WindowGroup` manages windows on its own terms. Watching
    /// for the close directly does not depend on that agreement.
    @objc func applicationDidFinishLaunching(_ notification: Notification) {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let closing = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                self?.windowWillClose(closing)
            }
        }
    }

    private func windowWillClose(_ closing: NSWindow) {
        // `terminate` closes windows on its way out, so without this the handler re-enters.
        guard !isTerminating, isDocumentWindow(closing) else { return }

        // The closing window is still in `NSApp.windows` at this point, so it is excluded
        // explicitly rather than counted.
        let remaining = NSApp.windows.filter {
            $0 !== closing && $0.isVisible && isDocumentWindow($0)
        }
        guard remaining.isEmpty else { return }

        isTerminating = true
        NSApp.terminate(nil)
    }

    /// A real window the user thinks of as "the app", as opposed to a panel, a tooltip, a sheet
    /// or the Settings window — so closing Settings does not take the app with it.
    private func isDocumentWindow(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), !window.isExcludedFromWindowsMenu else { return false }
        return window.styleMask.contains(.titled)
            && window.contentViewController != nil
            && window.title != "Settings"
    }

    @objc func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let state, state.isDeleting else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A deletion is still running."
        alert.informativeText = "Quitting now would leave a folder half-removed. "
            + "DevCleanerPro can stop after the item it is working on, which takes a moment."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Deleting")

        guard alert.runModal() == .alertFirstButtonReturn else {
            isTerminating = false
            return .terminateCancel
        }

        // Stop asks the engine not to start the next item; the current one is allowed to finish,
        // because a half-deleted directory is worse than a slower quit.
        state.stopDelete()
        Task { @MainActor in
            while state.isDeleting {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
