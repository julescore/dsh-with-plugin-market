#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
app_dir="$root/apps/macos"
desktop_dir="$root/apps/desktop"
out_dir="$root/.artifacts/macos"
version=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show version)
bundle_version=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show bundle-version)
build_number=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show build)
dmg="$out_dir/DeepSeek-Harness-${version}-macos-arm64.dmg"
mount_point=$(mktemp -d /private/tmp/deepseek-harness-macos.XXXXXX)
fresh_home=$(mktemp -d /private/tmp/deepseek-harness-fresh-home.XXXXXX)
conflict_home=$(mktemp -d /private/tmp/deepseek-harness-conflict-home.XXXXXX)
stdout=$(mktemp /private/tmp/deepseek-harness-stdout.XXXXXX)
stderr=$(mktemp /private/tmp/deepseek-harness-stderr.XXXXXX)
dump=$(mktemp /private/tmp/deepseek-harness-dump.XXXXXX)
mounted_app="$mount_point/DeepSeek Harness.app"
pid=""
port=""
url=""
attached=false

cleanup() {
  set +e
  stop_host >/dev/null 2>&1
  if [[ "$attached" == true ]]; then hdiutil detach "$mount_point" -force -quiet >/dev/null 2>&1 || true; fi
  python3 - "$mount_point" "$fresh_home" "$conflict_home" "$stdout" "$stderr" "$dump" <<'PY_CLEAN'
from pathlib import Path
import shutil
import sys
for value in sys.argv[1:]:
    path = Path(value)
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)
PY_CLEAN
}
trap cleanup EXIT

stop_host() {
  if [[ -z "$pid" ]]; then return; fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid"
    for _ in {1..100}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "macOS verify: embedded Host did not exit" >&2
    return 1
  fi
  wait "$pid"
  pid=""
  if [[ -n "$port" ]] && lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | grep -q .; then
    echo "macOS verify: loopback port $port was not released" >&2
    return 1
  fi
  port=""
  url=""
}

start_host() {
  local home=$1
  shift
  : >"$stdout"
  : >"$stderr"
  (
    cd "$HOME"
    exec env -i \
      HOME="$HOME" \
      DSH_HOME="$home" \
      USER="${USER:-}" \
      LOGNAME="${LOGNAME:-}" \
      SHELL="${SHELL:-/bin/zsh}" \
      PATH="$node_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      TMPDIR="${TMPDIR:-/private/tmp}" \
      "$node" "$launcher" web "$@" --port 0 >"$stdout" 2>"$stderr"
  ) &
  pid=$!
  url=""
  for _ in {1..300}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      pid=""
      echo "macOS verify: embedded Host exited before readiness" >&2
      cat "$stderr" >&2
      return 1
    fi
    url=$(sed -n 's/^dsh web: \(http:\/\/127\.0\.0\.1:[0-9][0-9]*\).*/\1/p' "$stdout" | tail -n 1)
    [[ -n "$url" ]] && break
    sleep 0.1
  done
  if [[ -z "$url" ]]; then
    echo "macOS verify: embedded Host did not become ready" >&2
    cat "$stderr" >&2
    return 1
  fi
  port=${url##*:}
  local listener
  listener=$(lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN | awk 'NR > 1 { print $9; exit }')
  [[ "$listener" == "127.0.0.1:$port" ]] || {
    echo "macOS verify: unexpected listener ${listener:-none}" >&2
    return 1
  }
}

assert_market_client() {
  local expected=$1
  local excluded=$2
  local index
  index=$(curl --fail --silent --show-error --max-time 5 "$url/")
  [[ "$index" == *"\"id\":\"$expected\""* ]] || {
    echo "macOS verify: expected market client $expected is absent from the Web boot graph" >&2
    return 1
  }
  [[ "$index" != *"\"id\":\"$excluded\""* ]] || {
    echo "macOS verify: excluded market client $excluded is present in the Web boot graph" >&2
    return 1
  }
  curl --fail --silent --show-error --max-time 15 "$url/dsh-market/registry"
}

[[ -f "$dmg" ]] || { echo "macOS verify: missing $dmg" >&2; exit 1; }
hdiutil verify "$dmg" >/dev/null
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_point" -quiet
attached=true
[[ -d "$mounted_app" ]] || { echo "macOS verify: mounted application is missing" >&2; exit 1; }
plutil -lint "$mounted_app/Contents/Info.plist" >/dev/null
[[ $(plutil -extract CFBundleDisplayName raw "$mounted_app/Contents/Info.plist") == "DeepSeek Harness" ]]
[[ $(plutil -extract CFBundleName raw "$mounted_app/Contents/Info.plist") == "DeepSeek Harness" ]]
[[ $(plutil -extract CFBundleExecutable raw "$mounted_app/Contents/Info.plist") == "DeepSeek Harness" ]]
[[ $(plutil -extract CFBundleShortVersionString raw "$mounted_app/Contents/Info.plist") == "$bundle_version" ]]
[[ $(plutil -extract CFBundleVersion raw "$mounted_app/Contents/Info.plist") == "$build_number" ]]
codesign --verify --deep --strict "$mounted_app"
[[ $(find -L "$mounted_app" -type l | wc -l | tr -d " ") == 0 ]]

node="$mounted_app/Contents/Resources/node/bin/node"
node_bin="$mounted_app/Contents/Resources/node/bin"
launcher="$mounted_app/Contents/Resources/runtime/lib/bin.js"
market_patch="$mounted_app/Contents/Resources/desktop/market.patch.yml"
market_conflict_patch="$mounted_app/Contents/Resources/desktop/market-conflict.patch.yml"
market_package="$mounted_app/Contents/Resources/runtime/node_modules/dshmarket-bundled/package.json"
pnpm="$node_bin/pnpm"
[[ -x "$pnpm" ]] || { echo "macOS verify: bundled pnpm launcher is missing" >&2; exit 1; }
[[ $("$pnpm" --version) == "11.7.0" ]] || { echo "macOS verify: unexpected bundled pnpm version" >&2; exit 1; }
[[ -f "$market_patch" && -f "$market_conflict_patch" && -f "$market_package" ]] || {
  echo "macOS verify: bundled market resources are missing" >&2
  exit 1
}
[[ $("$node" -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).name" "$market_package") == "dshmarket-bundled" ]]
[[ $("$node" -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" "$market_package") == "1.2.3" ]] || {
  echo "macOS verify: unexpected bundled market version" >&2
  exit 1
}

# A fresh profile receives exactly the packaged market.
env DSH_HOME="$fresh_home" "$node" "$launcher" web --patch "$market_patch" --dump-config >"$dump"
[[ $(grep -c '^- id: dsh-market$' "$dump") == 1 ]]
[[ $(grep -c '^  name: dshmarket-bundled$' "$dump") == 1 ]]
start_host "$fresh_home" --patch "$market_patch"
registry=$(assert_market_client "dshmarket-bundled" "dshmarket")
REGISTRY="$registry" python3 - <<'PY_REGISTRY'
import json
import os
payload = json.loads(os.environ["REGISTRY"])
plugins = payload.get("registry", {}).get("plugins", [])
matches = [item for item in plugins if item.get("url") in {
    "https://github.com/zhu1090093659/dsh-web-ui",
    "https://github.com/zhu1090093659/dsh-web-ui/tree/main/packages/dsh-web-ui-all",
}]
if len(matches) != 1:
    raise SystemExit("macOS verify: bundled market registry lacks the unique dsh-web-ui entry")
entry = matches[0]
if entry.get("npm") != "@linxin666/dsh-web-ui-all":
    raise SystemExit(f"macOS verify: dsh-web-ui does not use its npm aggregate: {entry}")
if entry.get("install") != "dsh plugin --profile web add @linxin666/dsh-web-ui-all":
    raise SystemExit(f"macOS verify: dsh-web-ui displays an unexpected install command: {entry}")
PY_REGISTRY
install=$(curl --fail --silent --show-error --max-time 300 \
  -H "Content-Type: application/json" \
  -H "Origin: $url" \
  --data '{"url":"https://github.com/zhu1090093659/dsh-web-ui/tree/main/packages/dsh-web-ui-all"}' \
  "$url/dsh-market/install")
INSTALL="$install" python3 - <<'PY_INSTALL'
import json
import os
payload = json.loads(os.environ["INSTALL"])
if payload.get("ok") is not True:
    raise SystemExit(f"macOS verify: dsh-web-ui market install failed: {payload}")
if "@linxin666/dsh-web-ui-all" not in payload.get("installed", {}):
    raise SystemExit("macOS verify: dsh-web-ui npm aggregate is absent from the profile")
if "dsh-web-ui" in payload.get("installed", {}):
    raise SystemExit("macOS verify: dsh-web-ui monorepo root was installed instead of the aggregate")
PY_INSTALL
aggregate="$fresh_home/profiles/web/node_modules/@linxin666/dsh-web-ui-all/package.json"
[[ -f "$aggregate" ]] || {
  echo "macOS verify: market did not materialize the dsh-web-ui npm aggregate" >&2
  exit 1
}
python3 - "$fresh_home/profiles/web/pnpm-workspace.yaml" <<'PY_BUILD_POLICY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for package in ("cloudflared", "cpu-features", "ssh2"):
    if text.count(f"  {package}: false") != 1:
        raise SystemExit(f"macOS verify: expected an explicit build-script denial for {package}")
    if f"  {package}: true" in text or f"  {package}: set this to true or false" in text:
        raise SystemExit(f"macOS verify: unsafe or undecided build-script policy for {package}")
PY_BUILD_POLICY
stop_host

# A restart proves the aggregate is a profile layer and its clients actually boot.
env DSH_HOME="$fresh_home" "$node" "$launcher" web --patch "$market_patch" --dump-config >"$dump"
[[ $(grep -c '^# == @linxin666/dsh-web-ui-all$' "$dump") == 1 ]]
start_host "$fresh_home" --patch "$market_patch"
assert_market_client "dshmarket-bundled" "dshmarket" >/dev/null
index=$(curl --fail --silent --show-error --max-time 15 "$url/")
for client in \
  @linxin666/dsh-client-ui-task-board \
  @linxin666/dsh-client-ui-git-graph \
  @linxin666/dsh-pet \
  @linxin666/dsh-remote-web-ui \
  @linxin666/dsh-live-stats \
  @linxin666/dsh-ssh \
  @linxin666/dsh-client-ui-web-ui-settings; do
  [[ "$index" == *"\"id\":\"$client\""* ]] || {
    echo "macOS verify: dsh-web-ui client $client is absent from the Web boot graph" >&2
    exit 1
  }
done
uninstall=$(curl --fail --silent --show-error --max-time 300 \
  -H "Content-Type: application/json" \
  -H "Origin: $url" \
  --data '{"name":"@linxin666/dsh-web-ui-all"}' \
  "$url/dsh-market/uninstall")
UNINSTALL="$uninstall" python3 - <<'PY_UNINSTALL'
import json
import os
payload = json.loads(os.environ["UNINSTALL"])
if payload.get("ok") is not True:
    raise SystemExit(f"macOS verify: dsh-web-ui aggregate uninstall failed: {payload}")
if "@linxin666/dsh-web-ui-all" in payload.get("installed", {}):
    raise SystemExit("macOS verify: uninstalled dsh-web-ui aggregate remains in the profile")
PY_UNINSTALL
stop_host

# Install the previous market release in an isolated profile to exercise both conflict choices and a real update.
env -i \
  HOME="$HOME" DSH_HOME="$conflict_home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}" \
  PATH="$node_bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/private/tmp}" CI=true \
  "$node" "$launcher" web --dump-config >"$dump"
env -i \
  HOME="$HOME" DSH_HOME="$conflict_home" USER="${USER:-}" LOGNAME="${LOGNAME:-}" SHELL="${SHELL:-/bin/zsh}" \
  PATH="$node_bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/private/tmp}" CI=true \
  "$node" "$launcher" plugin --profile web add dshmarket@1.1.0
[[ $("$node" -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" \
  "$conflict_home/profiles/web/node_modules/dshmarket/package.json") == "1.1.0" ]] || {
  echo "macOS verify: previous market fixture is not dshmarket@1.1.0" >&2
  exit 1
}
manifest="$conflict_home/profiles/web/package.json"
manifest_before=$(shasum -a 256 "$manifest" | awk '{print $1}')
env DSH_HOME="$conflict_home" "$node" "$launcher" web --dump-config >"$dump"
[[ $(grep -c '^- id: dsh-market$' "$dump") == 1 ]]
[[ $(grep -c '^  name: dshmarket$' "$dump") == 1 ]]

# "Use local" adds no desktop patch.
start_host "$conflict_home"
assert_market_client "dshmarket" "dshmarket-bundled" >/dev/null
stop_host
[[ $(shasum -a 256 "$manifest" | awk '{print $1}') == "$manifest_before" ]] || {
  echo "macOS verify: local-market launch changed the profile manifest" >&2
  exit 1
}

# "Use packaged" disables the local row only in this run and inserts the packaged alias.
env DSH_HOME="$conflict_home" "$node" "$launcher" web --patch "$market_conflict_patch" --dump-config >"$dump"
[[ $(grep -c '^- id: dsh-market$' "$dump") == 1 ]]
[[ $(grep -c '^- id: dsh-market-packaged$' "$dump") == 1 ]]
[[ $(grep -c '^  name: dshmarket-bundled$' "$dump") == 1 ]]
start_host "$conflict_home" --patch "$market_conflict_patch"
assert_market_client "dshmarket-bundled" "dshmarket" >/dev/null
[[ $(shasum -a 256 "$manifest" | awk '{print $1}') == "$manifest_before" ]] || {
  echo "macOS verify: packaged-market launch changed the profile manifest" >&2
  exit 1
}
market_update=$(curl --fail --silent --show-error --max-time 300 \
  -H "Content-Type: application/json" \
  -H "Origin: $url" \
  --data '{"name":"dshmarket"}' \
  "$url/dsh-market/update")
MARKET_UPDATE="$market_update" python3 - <<'PY_MARKET_UPDATE'
import json
import os
payload = json.loads(os.environ["MARKET_UPDATE"])
if payload.get("ok") is not True:
    raise SystemExit(f"macOS verify: first-click market update failed: {payload}")
if payload.get("stale") is True:
    raise SystemExit(f"macOS verify: market update still hit the release-age wait: {payload}")
PY_MARKET_UPDATE
market_updated_version=$("$node" -p "JSON.parse(require('node:fs').readFileSync(process.argv[1], 'utf8')).version" \
  "$conflict_home/profiles/web/node_modules/dshmarket/package.json")
MARKET_UPDATED_VERSION="$market_updated_version" python3 - <<'PY_MARKET_VERSION'
import os
import re

before = (1, 1, 0)
after_text = os.environ["MARKET_UPDATED_VERSION"]
match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", after_text)
if match is None or tuple(map(int, match.groups())) <= before:
    raise SystemExit(
        f"macOS verify: market update did not advance dshmarket beyond 1.1.0: {after_text}"
    )
PY_MARKET_VERSION
stop_host

sha256=$(shasum -a 256 "$dmg" | awk '{print $1}')
printf 'macOS verification passed\nVERSION=%s\nBUNDLE_VERSION=%s\nBUILD=%s\nMARKET=dshmarket@1.2.3\nMARKET_DSH_WEB_UI=@linxin666/dsh-web-ui-all\nMARKET_DENIED_BUILDS=cloudflared,cpu-features,ssh2\nMARKET_CONFLICT_CHOICES=local,bundled\nMARKET_FIRST_CLICK_UPDATE=1.1.0-to-%s\nPNPM=11.7.0\nDMG=%s\nSHA256=%s\n' \
  "$version" "$bundle_version" "$build_number" "$market_updated_version" "$dmg" "$sha256"
