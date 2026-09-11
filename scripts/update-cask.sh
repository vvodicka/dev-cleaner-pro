#!/bin/bash
#
# Regenerates Casks/devcleanerpro.rb in the Homebrew tap from a released DMG,
# then commits and pushes it.
#
#   scripts/update-cask.sh 1.0.0            uses dist/DevCleanerPro-1.0.0.dmg
#   DCP_TAP=~/src/homebrew-tap scripts/update-cask.sh 1.0.0
#
# The tap is a separate repository named `homebrew-tap`, so that
# `brew tap vvodicka/tap` finds it. See docs/RELEASING.md.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/update-cask.sh <version>}"
TAP="${DCP_TAP:-$(cd .. && pwd)/homebrew-tap}"
DMG="dist/DevCleanerPro-$VERSION.dmg"
REPO="vvodicka/dev-cleaner-pro"

[[ -f "$DMG" ]] || { echo "no such file: $DMG — run scripts/release.sh $VERSION first" >&2; exit 1; }
[[ -d "$TAP/.git" ]] || { echo "no tap repository at $TAP (set DCP_TAP)" >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
mkdir -p "$TAP/Casks"

cat > "$TAP/Casks/devcleanerpro.rb" <<EOF
cask "devcleanerpro" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/DevCleanerPro-#{version}.dmg"
  name "DevCleanerPro"
  desc "Reclaims disk space from developer caches and build directories"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :tahoe"

  app "DevCleanerPro.app"

  zap trash: [
    "~/Library/Application Support/DevCleanerPro",
    "~/Library/Preferences/dev.vodicka.DevCleanerPro.plist",
    "~/Library/Saved Application State/dev.vodicka.DevCleanerPro.savedState",
  ]
end
EOF

echo "wrote $TAP/Casks/devcleanerpro.rb"
echo "  version $VERSION"
echo "  sha256  $SHA"

git -C "$TAP" add Casks/devcleanerpro.rb
git -C "$TAP" commit -m "devcleanerpro $VERSION"
git -C "$TAP" push

echo
echo "Verify with:"
echo "  brew update && brew info --cask devcleanerpro"
echo "  brew install --cask devcleanerpro"
