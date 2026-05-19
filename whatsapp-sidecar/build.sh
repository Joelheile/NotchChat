#!/bin/bash
# Builds the WhatsApp sidecar binary and drops it where the app bundle picks it
# up. boringNotch/private is an Xcode "synchronized" folder, so any file placed
# there is copied into boringNotch.app automatically on the next build.
set -euo pipefail
cd "$(dirname "$0")"

DEST="../boringNotch/private/whatsapp-sidecar"

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go is not installed. Install with: brew install go" >&2
  exit 1
fi

echo "Resolving dependencies..."
go mod tidy

echo "Building (CGO required for go-sqlite3)..."
CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" -o "$DEST" .
chmod +x "$DEST"

# Ad-hoc sign so the sandboxed app can spawn it in a local/dev build.
codesign --force --sign - "$DEST" 2>/dev/null || true

echo "Built: $DEST"
echo "Now build boringNotch in Xcode; the binary ships inside the app bundle."
