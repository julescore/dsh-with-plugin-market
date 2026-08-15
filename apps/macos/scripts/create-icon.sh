#!/bin/bash
set -euo pipefail
source_svg=${1:?source SVG is required}
out_icns=${2:?output ICNS is required}
work=$(mktemp -d)
cleanup() { python3 - "$work" <<'PY_CLEAN'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY_CLEAN
}
trap cleanup EXIT
base="$work/icon-1024.png"
sips -s format png -z 1024 1024 "$source_svg" --out "$base" >/dev/null
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$base" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$base" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$out_icns"
