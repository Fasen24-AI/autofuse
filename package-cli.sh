#!/bin/bash
# Package CLI tools for Homebrew distribution
set -euo pipefail

VERSION="4.1"
TARBALL="autofuse-${VERSION}.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

echo "Packaging AutoFuse CLI v${VERSION}..."

# Verify required files exist
for f in cli/autofuse mount.sh discover.sh config.json; do
    if [ ! -f "$f" ]; then
        echo "Error: Missing $f"
        exit 1
    fi
done

# Create tarball (includes cli/ subdirectory structure)
tar czf "$TARBALL" cli/autofuse mount.sh discover.sh config.json

echo "Created: $TARBALL"
echo ""
echo "SHA-256:"
shasum -a 256 "$TARBALL"
echo ""
echo "Update autofuse.rb with the sha256 above, then:"
echo "  brew install --formula ./autofuse.rb"
