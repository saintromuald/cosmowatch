#!/usr/bin/env bash
# Build a release ZIP of the Windows tool for distribution.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(date +%Y%m%d)}"
OUT="CosmoWatch-$VERSION.zip"
rm -f "$OUT"
zip -r "$OUT" CosmoWatch.ps1 CosmoWatch.cmd README.md site-integration.md LICENSE
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
