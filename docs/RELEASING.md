# Releasing

Signed, notarized DMG → GitHub release → Homebrew cask. Everything after the one-time setup is
two commands.

## One-time setup

### 1. Developer ID certificate

Signing is automatic. The app archives with the team's development identity and
`xcodebuild -exportArchive` re-signs it with **Developer ID Application**, which is what lets it
open on a machine other than the one it was built on. That requires a paid Apple Developer
Program membership and an Apple ID signed in under Xcode › Settings › Accounts.

`scripts/release.sh` passes `-allowProvisioningUpdates`, so on the first release Xcode requests
the Developer ID certificate itself; there is nothing to create by hand. If it refuses — some
accounts only let the Account Holder issue one — make it manually: Xcode › Settings › Accounts ›
select the team › Manage Certificates › **+** › *Developer ID Application*.

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Once it exists, back it up (Keychain Access › export as `.p12`). Apple issues a limited number
per account, and losing one without a backup is a nuisance.

### 2. Notarization credentials

Notarization needs an app-specific password, not your Apple ID password. Create one at
[appleid.apple.com](https://appleid.apple.com) › Sign-In and Security › App-Specific Passwords,
then store it in the keychain under the profile name the release script expects:

```sh
xcrun notarytool store-credentials devcleanerpro \
  --apple-id <your-apple-id> \
  --team-id FPU5BPQ3UD \
  --password <app-specific-password>

xcrun notarytool history --keychain-profile devcleanerpro   # confirms it works
```

### 3. GitHub CLI — optional

`gh` is only used by `--publish` to create the release and upload the DMG to it. Git itself
pushes the code and the tag; what it cannot do is attach a binary to a release, because that is a
GitHub API call rather than a git operation.

```sh
brew install gh
gh auth login
```

Without it, `--publish` still pushes the tag, writes the release notes to a file, and prints the
URL of the "new release" page to finish by hand — create the release for the tag and drag the
`.dmg` and `.dmg.sha256` onto it. The Homebrew cask needs the DMG to be downloadable from the
release, so this step cannot be skipped entirely, only done in the browser.

### 4. The Homebrew tap

The tap is a **separate public repository** that must be named `homebrew-tap`, so that
`brew tap vvodicka/tap` resolves to it. Create it on github.com like any other repository, or:

```sh
gh repo create vvodicka/homebrew-tap --public --clone \
  --description "Homebrew tap for vvodicka's macOS apps"
```

`scripts/update-cask.sh` expects it at `../homebrew-tap` relative to this repository, or wherever
`DCP_TAP` points.

## Cutting a release

```sh
scripts/release.sh 1.0.0              # build, sign, notarize, staple, DMG into dist/
scripts/release.sh 1.0.0 --publish    # the same, then tag and create the GitHub release
scripts/update-cask.sh 1.0.0          # regenerate, commit and push the cask
```

Useful variants:

| Command | What it does |
|---|---|
| `scripts/release.sh 1.0.0 --install` | also replaces `/Applications/DevCleanerPro.app` |
| `scripts/release.sh 1.0.0 --skip-notarize` | local smoke test; the result will **not** open elsewhere |

The version argument sets `MARKETING_VERSION`; the build number is `git rev-list --count HEAD`,
so it increases on its own and never needs editing in the project file.

Notarization takes a few minutes. `--wait` blocks until Apple answers; on rejection, read the log:

```sh
xcrun notarytool log <submission-id> --keychain-profile devcleanerpro
```

The usual causes are a missing hardened runtime, a missing secure timestamp, or a nested binary
that was not signed. The script checks the hardened runtime and that the export really came out
Developer ID signed before it submits anything.

## Verifying what a colleague will actually get

```sh
spctl --assess --type open --context context:primary-signature --verbose=2 dist/DevCleanerPro-1.0.0.dmg
xcrun stapler validate dist/DevCleanerPro-1.0.0.dmg
```

Both must pass. For a real end-to-end check, download the DMG from the release page with a
browser (so it carries the quarantine attribute), then open it.

## Release checklist

1. `docs/CHANGELOG.md` has a `## <version>` section — the release notes are taken from it.
2. Working tree is clean; `--publish` refuses otherwise.
3. Run the manual test matrix in `docs/04-implementation-plan.md`.
4. `scripts/release.sh <version> --publish`
5. `scripts/update-cask.sh <version>`
6. `brew update && brew upgrade --cask devcleanerpro` on a second machine, or at least
   `brew info --cask devcleanerpro`.

Homebrew 6 will not load a cask from an untrusted tap. Anyone installing for the first time
needs `brew trust vvodicka/tap` between the tap and the install, or it fails with the
unhelpful "No Cask with this name exists". The README install block says so.

## Notes

- Changing `PRODUCT_BUNDLE_IDENTIFIER` or the signing team revokes every user's Full Disk Access
  grant. Don't, outside a fork.
- The certificate expires after five years; the notarized, stapled DMG keeps working, because the
  signature carries a secure timestamp. You only need a new certificate to build a *new* release.
- There is no auto-updater in the app and there will not be one — it would be a third-party
  dependency. `brew upgrade --cask` is the update path.
