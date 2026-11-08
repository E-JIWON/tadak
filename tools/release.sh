#!/bin/sh
# tools/release.sh 1.2 — publishes Tadak 1.2: pushes main, uploads Tadak.zip as GitHub release v1.2, and points the
# Homebrew cask (E-JIWON/homebrew-tap) at it, so `brew upgrade --cask tadak` and install.sh both pick it up.
set -e
V=$1
[ -n "$V" ] || { echo "usage: tools/release.sh <version>" >&2; exit 1; }
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first" >&2; exit 1; }
VERSION=$V ./build.sh release
git push origin main
gh release create "v$V" Tadak.zip --title "Tadak $V" --notes "설치·업데이트: \`brew install --cask e-jiwon/tap/tadak\` 또는 README의 한 줄 명령"
SHA=$(shasum -a 256 Tadak.zip | cut -d' ' -f1)
TAP=$(mktemp -d); trap 'rm -rf "$TAP"' EXIT
gh repo clone E-JIWON/homebrew-tap "$TAP" -- -q
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/tadak.rb"
# the tap's commits use the GitHub no-reply address
git -C "$TAP" -c user.name=E-JIWON -c user.email=45556338+E-JIWON@users.noreply.github.com commit -qam "tadak $V"
git -C "$TAP" push -q
echo "released $V"
