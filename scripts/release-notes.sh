#!/bin/bash
#
# Prints the release notes for one version on stdout: the matching section of
# docs/CHANGELOG.md if there is one, otherwise the commit subjects since the
# previous tag. Used by scripts/release.sh --publish.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-notes.sh <version>}"
CHANGELOG="docs/CHANGELOG.md"

section=""
if [[ -f "$CHANGELOG" ]]; then
  section="$(awk -v v="$VERSION" '
    $0 ~ "^## (v)?" v "([^0-9]|$)" { printing = 1; next }
    printing && /^## / { exit }
    printing { print }
  ' "$CHANGELOG")"
fi

if [[ -n "${section// /}" ]]; then
  printf '%s\n' "$section"
else
  prev="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  echo "### Changes"
  echo
  if [[ -n "$prev" ]]; then
    git log --no-merges --pretty='- %s' "$prev..HEAD"
  else
    git log --no-merges --pretty='- %s' -20
  fi
fi

cat <<'EOF'

---

**Install**

```sh
brew tap vvodicka/tap
brew install --cask devcleanerpro
```

Or download the DMG below. The build is signed with a Developer ID certificate and notarized by
Apple, so it opens without a Gatekeeper prompt. Verify the download with the `.sha256` file.
EOF
