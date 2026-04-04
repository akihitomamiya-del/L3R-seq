#!/bin/bash
# bump-version.sh — Update version strings across all files atomically.
# Usage: bash scripts/bump-version.sh 1.0.13

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "  e.g. $0 1.0.13"
    exit 1
fi

NEW_VERSION="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Validate version format (major.minor.patch)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Version must be in X.Y.Z format (got: $NEW_VERSION)" >&2
    exit 1
fi

# 1. CITATION.cff
sed -i "s/^version: \".*\"/version: \"$NEW_VERSION\"/" "$SCRIPT_DIR/CITATION.cff"

# 2. L3Rseq dispatcher
sed -i "s/^VERSION=\".*\"/VERSION=\"$NEW_VERSION\"/" "$SCRIPT_DIR/L3Rseq"

# 3. CHANGELOG.md — prepend new section if not already present
if ! grep -q "## \[$NEW_VERSION\]" "$SCRIPT_DIR/CHANGELOG.md"; then
    DATE=$(date +%Y-%m-%d)
    HEADER="## [$NEW_VERSION] - $DATE"
    # Insert after the first line that starts with "## ["
    sed -i "0,/^## \[/s/^## \[/$HEADER\n\n### Changed\n- (describe changes)\n\n## [/" "$SCRIPT_DIR/CHANGELOG.md"
fi

# Verify
echo "Version bumped to $NEW_VERSION:"
grep "^version:" "$SCRIPT_DIR/CITATION.cff"
grep "^VERSION=" "$SCRIPT_DIR/L3Rseq"
head -8 "$SCRIPT_DIR/CHANGELOG.md" | grep "## \["
