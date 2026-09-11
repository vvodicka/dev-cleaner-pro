import SwiftUI
import DevCleanerProCore

/// Shown at launch. Says plainly what this app is, before anyone selects anything.
///
/// Deliberately not softened. The app carries out exactly what you tick, without second-guessing
/// whether you meant it — and dressing that up would make the one screen whose whole purpose is
/// to be clear the least clear thing in the app.
struct DisclaimerSheet: View {
    @Environment(AppState.self) private var state
    @State private var dontShowAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(of: points)
            Divider()
            footer
        }
        .frame(width: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("This app deletes what you tick.")
                    .font(.system(size: 17, weight: .semibold))
                Text("It does not ask a second time, and it cannot tell whether you meant it. "
                     + "Treat every checkbox as `rm -rf` over that folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private struct Point: Identifiable {
        let id = UUID()
        let symbol: String
        let colour: Color
        let text: String
    }

    private var points: [Point] {
        [
            Point(symbol: "trash", colour: .secondary,
                  text: "**Move to Trash is the default** and is the recoverable one. "
                      + "Delete permanently is not — nothing goes to the Trash and there is no undo."),
            Point(symbol: "bolt.fill", colour: .orange,
                  text: "Rows marked ⚡ run a tool — `docker`, `xcrun simctl`, `git gc`. "
                      + "Those are **always irreversible**, whichever mode is set."),
            Point(symbol: "checkmark.shield", colour: .green,
                  text: "The app refuses to touch anything outside the folders its modules "
                      + "declare, and never uses `sudo`. That is a boundary, not a safety net: "
                      + "inside those folders it does exactly what you ask."),
            Point(symbol: "person.fill.questionmark", colour: .secondary,
                  text: "It assumes you know what a cache, a build folder and a simulator "
                      + "runtime are. **Losses from something you ticked are yours**, and no "
                      + "warranty is offered or implied."),
            Point(symbol: "externaldrive.badge.checkmark", colour: .secondary,
                  text: "Have a backup you trust before a first large clean-up. "
                      + "Every risk badge is a judgement, and judgements can be wrong.")
        ]
    }

    private func body(of points: [Point]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(points) { point in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: point.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(point.colour)
                        .frame(width: 18)
                    Text(.init(point.text))
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Toggle("Don't show this again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            Spacer()
            Button("I understand") {
                state.dismissDisclaimer(remember: dontShowAgain)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
