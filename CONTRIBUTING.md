# Contributing

Thanks for looking. This is a small, opinionated app; the fastest way to get a change merged is
to keep it inside the grain described below.

## Ground rules

- **No third-party dependencies.** Nothing in `Package.swift`, nothing vendored.
- **No `sudo`, ever.** Anything that would need it is shown as an information row with the
  command for the user to run by hand.
- **`PathGuard` is never bypassed.** A module may only delete inside the roots it declares, and
  the deny-list overrides everything.
- **Core logic in `Packages/DevCleanerProCore`**, which never imports SwiftUI. UI lives in
  `DevCleanerPro/`.
- **Commands run through `Shell` as argv arrays**, never `sh -c` with an interpolated string.
- Swift 6 strict concurrency; anything crossing a task boundary is `Sendable`.
- System semantic colours only. The four risk badge hues in the asset catalog are the single
  exception. SF Symbols for icons. Every number gets `.monospacedDigit()`.

## Adding a module

One file, one registry line, zero UI changes:

1. `Packages/DevCleanerProCore/Sources/DevCleanerProCore/Scanning/Modules/<Name>Module.swift`,
   conforming to `ScanModule`.
2. Declare in `roots` every directory the module may delete — and nothing else. Paths you measure
   but never delete must stay outside that list.
3. One line in `ModuleRegistry.allModules`.

Pick the risk level honestly: `safe` (regenerates on its own), `moderate` (shown as **Rebuild** —
the next build is slower), `careful` (you may not get it back), `info` (not deletable by the app).

## Verifying

There is no test suite; this is verified by hand against a real machine.

```sh
swift run dcp-scan --tree <moduleID>     # what the module sees
swift run dcp-scan --self-check          # PathGuard against the real filesystem
du -sh <path>                            # the number your module must agree with
```

Sizes are compared against `du -sh`, and parsers against the captured tool output in
`docs/samples/`. If you add a parser, add the sample it was written against — anonymized, with no
hostnames, registries, usernames or project names from a real employer.

Then build, run the app, and check the change in both Light and Dark against the matching frame
in `docs/design/`.

## Commits and pull requests

- One logical change per commit: `feat: …`, `fix: …`, `docs: …`.
- Say in the PR what you verified and on what — macOS version, which tools were installed.
- Update `docs/CHANGELOG.md`.

## Reporting a bug

Include the macOS version, whether Full Disk Access is granted, the module involved, and — if a
size looks wrong — the `du -sh` output for the path in question. Please redact paths that identify
an employer or a client.
