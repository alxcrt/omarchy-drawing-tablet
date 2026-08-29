#!/usr/bin/env bash
# Cut a release: bump manifest.json, commit, tag vX.Y.Z and push. The Release
# workflow on GitHub turns the tag into a release whose notes are the commits
# since the previous tag.
#
#   tools/release.sh 1.1.0
set -euo pipefail

version=${1:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: tools/release.sh X.Y.Z" >&2; exit 1; }
cd "$(dirname "$0")/.."

[[ -z $(git status --porcelain) ]] || { echo "commit or stash your changes first" >&2; exit 1; }
[[ $(git branch --show-current) == main ]] || { echo "release from main" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$version" >/dev/null || { echo "v$version already exists" >&2; exit 1; }

node --test tests/model.test.js >/dev/null
if command -v omarchy >/dev/null; then omarchy plugin validate . >/dev/null; fi

node -e '
const fs = require("fs")
const manifest = JSON.parse(fs.readFileSync("manifest.json", "utf8"))
manifest.version = process.argv[1]
fs.writeFileSync("manifest.json", JSON.stringify(manifest, null, 2) + "\n")
' "$version"

git add manifest.json
git commit -q -m "chore: bump the plugin version to $version"
git tag -a "v$version" -m "v$version"
git push -q origin main "v$version"
echo "v$version pushed; the Release workflow publishes the notes"
