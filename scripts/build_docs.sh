#!/bin/bash
# Build PlayerKit DocC documentation.
# Output: .build/docs/  (open .build/docs/index.html in a browser)
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ Building PlayerKit symbol graph…"
xcrun swift package dump-symbol-graph --minimum-access-level public

SYMBOL_DIR=$(find .build -type d -name symbolgraph | head -1)
if [ -z "$SYMBOL_DIR" ]; then
  echo "✗ symbol graph not found"; exit 1
fi
echo "→ Symbol graph at: $SYMBOL_DIR"

echo "→ Running docc convert…"
xcrun docc convert \
  --additional-symbol-graph-dir "$SYMBOL_DIR" \
  --output-dir .build/docs \
  --fallback-display-name PlayerKit \
  --fallback-bundle-identifier io.reflux.PlayerKit

echo
echo "✓ Docs generated at .build/docs/index.html"
echo "  open file://$PWD/.build/docs/index.html"
