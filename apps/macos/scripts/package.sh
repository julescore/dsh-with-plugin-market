#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
app_dir="$root/apps/macos"
desktop_dir="$root/apps/desktop"
out_dir="$root/.artifacts/macos"
app="$out_dir/DeepSeek Harness.app"
stage="$out_dir/dmg-stage"
version_file="$desktop_dir/version.json"
backup=$(mktemp)
cp "$version_file" "$backup"
succeeded=false
build_started=false
dmg=""
cleanup() {
  if [[ "$succeeded" != true ]]; then
    cp "$backup" "$version_file"
    if [[ "$build_started" == true ]]; then
      python3 - "$dmg" "$app" "$stage" <<'PY_ARTIFACT'
from pathlib import Path
import shutil
import sys
for value in sys.argv[1:]:
    path = Path(value)
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)
PY_ARTIFACT
    fi
    echo "macOS package: restored the previous version after failure" >&2
  fi
  python3 - "$backup" <<'PY_BACKUP'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY_BACKUP
}
trap cleanup EXIT

node --import tsx/esm "$desktop_dir/scripts/version.ts" bump "$@"
version=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show version)
dmg="$out_dir/DeepSeek-Harness-${version}-macos-arm64.dmg"
build_started=true
bash "$app_dir/scripts/build.sh"
bash "$app_dir/scripts/verify.sh"
sha256=$(shasum -a 256 "$dmg" | awk '{print $1}')
succeeded=true
printf 'macOS package complete\nVERSION=%s\nDMG=%s\nSHA256=%s\n' "$version" "$dmg" "$sha256"
