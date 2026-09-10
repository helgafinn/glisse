#!/bin/bash
# Regenerates Resources/AppIcon.icns from the artwork in
# Sources/GlisseKit/Utilities/LogoArtwork.swift.
#
# The drawing lives in the app rather than in a standalone script so the menu bar
# glyph, the About panel and the .icns file are literally the same code and cannot
# drift apart. This wrapper just builds, exports an .iconset and converts it.
#
# usage: Scripts/make-icon.sh [--previews <dir>]

set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(swift build --show-bin-path)/Glisse"
swift build >/dev/null

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$BIN" --export-icon "$TMP" >/dev/null
iconutil --convert icns "$TMP/AppIcon.iconset" --output Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"

# Optional: keep the previews for inspection.
if [ "${1:-}" = "--previews" ] && [ -n "${2:-}" ]; then
  mkdir -p "$2"
  cp "$TMP"/preview-*.png "$2"/
  echo "wrote previews to $2"
fi
