#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
VERSION="${1:?usage: release.sh vX.Y.Z}"
DESC="A terminal for Ainkrad — blocks, themes, SwiftTerm-backed."
AUTHOR="Ahmed M. Elhalaby"
LONG_DESC="AinkradTerminal brings a full terminal into Ainkrad's workspace: block-based command history, theme-matched colors driven by the host's DesignTokens, and a SwiftTerm-backed emulator underneath. Split panes, resize freely, and switch themes without losing your scroll history."

xcodegen generate
xcodebuild -scheme TerminalPlugin -configuration Release -derivedDataPath build -destination 'platform=macOS' build
BUNDLE="build/Build/Products/Release/TerminalPlugin.bundle"

rm -rf dist && mkdir -p dist
# Archive the bundle so the extracted tree contains TerminalPlugin.bundle at its root
# (PluginInstaller accepts root-is-bundle and .bundle-child layouts).
/usr/bin/ditto -c -k --keepParent "$BUNDLE" dist/terminal.bundle.zip
SHA="$(shasum -a 256 dist/terminal.bundle.zip | awk '{print $1}')"

# Promo shots served from the repo's default branch. This said `master`, which
# no longer exists — the family unified on main/staging/development.
SHOTS_BASE="https://raw.githubusercontent.com/AhmedMElhalaby/AinkradTerminal/main/screenshots"

# apiVersion is READ FROM THE BUILT BUNDLE, not hardcoded here.
#
# It was hardcoded — `7` on main, `1` on the branch this merged from — and both
# were wrong: the host loads a bundle only when its apiVersion is inside the
# supported generation range, so a stale constant here publishes a plugin the
# host refuses to load, with no build failure to warn anyone. The bundle's
# Info.plist is stamped at build time from the AinkradAppKit revision actually
# linked (scripts/stamp-api-version.sh), so it is the single source of truth.
API_VERSION="$(/usr/libexec/PlistBuddy -c 'Print AinkradAPIVersion' "$BUNDLE/Contents/Info.plist")"
[[ -n "$API_VERSION" ]] || { echo "error: could not read AinkradAPIVersion from the built bundle" >&2; exit 1; }

cat > dist/ainkrad-plugin.json <<JSON
{ "id": "terminal", "name": "Terminal", "icon": "terminal", "description": "$DESC", "apiVersion": $API_VERSION, "sha256": "$SHA",
  "author": "$AUTHOR", "longDescription": "$LONG_DESC",
  "screenshots": ["$SHOTS_BASE/terminal-1.png", "$SHOTS_BASE/terminal-2.png", "$SHOTS_BASE/terminal-3.png"],
  "links": [] }
JSON

gh release create "$VERSION" dist/ainkrad-plugin.json dist/terminal.bundle.zip \
  --title "Terminal $VERSION" --notes "Ainkrad Terminal plugin $VERSION"
echo "Released $VERSION (sha256 $SHA)"
