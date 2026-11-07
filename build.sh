#!/usr/bin/env bash
# Packages the module/ directory into a flashable Magisk module zip.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(grep '^version=' module/module.prop | cut -d= -f2)
OUT="dist"
ZIP="$PWD/$OUT/MicroG-Flasher-${VERSION}.zip"

mkdir -p "$OUT"
rm -f "$ZIP"

if command -v zip >/dev/null 2>&1; then
  (cd module && zip -r9Xq "$ZIP" .)
else
  python3 - "$ZIP" <<'EOF'
import os, sys, zipfile
zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for root, _, files in os.walk("module"):
        for f in sorted(files):
            full = os.path.join(root, f)
            z.write(full, os.path.relpath(full, "module"))
EOF
fi

echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
