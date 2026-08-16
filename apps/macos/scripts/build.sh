#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
app_dir="$root/apps/macos"
desktop_dir="$root/apps/desktop"
out_dir="$root/.artifacts/macos"
cache_dir="$root/.artifacts/toolchains"
app="$out_dir/DeepSeek Harness.app"
runtime="$out_dir/runtime"
stage="$out_dir/dmg-stage"
node_version=24.19.0
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_sha256=8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d
node_url="https://nodejs.org/dist/v${node_version}/${node_archive}"
pnpm_version=11.7.0
pnpm_archive="pnpm-${pnpm_version}.tgz"
pnpm_sha256=deafa7ec98a1218b6a047289b92fbe2395c1e22d3495bb711653013218ee15ee
pnpm_url="https://registry.npmjs.org/pnpm/-/${pnpm_archive}"
market_version=1.2.3
market_archive="dshmarket-${market_version}.tgz"
market_sha256=4824945d4d3966aca37b7cc71717e74b4ae0609ed731dd71b346e03576ab7ece
market_url="https://registry.npmjs.org/dshmarket/-/${market_archive}"

mkdir -p "$cache_dir" "$out_dir"
if [[ ! -f "$cache_dir/$node_archive" ]]; then
  curl --fail --location --silent --show-error "$node_url" --output "$cache_dir/$node_archive"
fi
echo "$node_sha256  $cache_dir/$node_archive" | shasum -a 256 --check --status
if [[ ! -x "$cache_dir/node-v${node_version}-darwin-arm64/bin/node" ]]; then
  tar -xzf "$cache_dir/$node_archive" -C "$cache_dir"
fi
node_root="$cache_dir/node-v${node_version}-darwin-arm64"
if [[ ! -f "$cache_dir/$pnpm_archive" ]]; then
  curl --fail --location --silent --show-error "$pnpm_url" --output "$cache_dir/$pnpm_archive"
fi
echo "$pnpm_sha256  $cache_dir/$pnpm_archive" | shasum -a 256 --check --status
pnpm_root="$cache_dir/pnpm-${pnpm_version}"
if [[ ! -f "$pnpm_root/bin/pnpm.cjs" ]]; then
  rm -rf "$pnpm_root"
  mkdir -p "$pnpm_root"
  tar -xzf "$cache_dir/$pnpm_archive" --strip-components=1 -C "$pnpm_root"
fi
if [[ ! -f "$cache_dir/$market_archive" ]]; then
  curl --fail --location --silent --show-error "$market_url" --output "$cache_dir/$market_archive"
fi
echo "$market_sha256  $cache_dir/$market_archive" | shasum -a 256 --check --status
market_root="$cache_dir/dshmarket-${market_version}"
if [[ ! -f "$market_root/package.json" ]]; then
  rm -rf "$market_root"
  mkdir -p "$market_root"
  tar -xzf "$cache_dir/$market_archive" --strip-components=1 -C "$market_root"
fi
export PATH="$node_root/bin:$PATH"
if [[ $(node --version) != "v${node_version}" ]]; then
  echo "macOS build: expected Node v${node_version}" >&2
  exit 1
fi

version=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show version)
bundle_version=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show bundle-version)
build_number=$(node --import tsx/esm "$desktop_dir/scripts/version.ts" show build)
dmg="$out_dir/DeepSeek-Harness-${version}-macos-arm64.dmg"

corepack pnpm -C "$root" run build
python3 - "$runtime" "$app" "$stage" "$dmg" <<'PY_CLEAN'
from pathlib import Path
import shutil
import sys
for value in sys.argv[1:]:
    path = Path(value)
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()
PY_CLEAN
restore_workspace_install=true
restore_workspace_dependencies() {
  if [[ "$restore_workspace_install" == true ]]; then
    corepack pnpm -C "$root" install --frozen-lockfile
  fi
}
trap restore_workspace_dependencies EXIT
CI=true corepack pnpm -C "$root" --filter @deepseek-ai/dsh deploy --legacy --prod \
  --config.node-linker=hoisted \
  --config.auto-install-peers=false \
  --config.link-workspace-packages=true \
  "$runtime"
restore_workspace_dependencies
restore_workspace_install=false
trap - EXIT
python3 - "$runtime/package.json" "$market_version" <<'PY_MARKET_DEPENDENCY'
from pathlib import Path
import json
import sys

manifest_path = Path(sys.argv[1])
version = sys.argv[2]
manifest = json.loads(manifest_path.read_text())
dependencies = manifest.setdefault("dependencies", {})
existing = dependencies.get("dshmarket-bundled")
expected = f"npm:dshmarket@{version}"
if existing is not None and existing != expected:
    raise SystemExit(f"macOS build: runtime declares unexpected bundled market alias {existing}")
dependencies.pop("dshmarket", None)
dependencies["dshmarket-bundled"] = expected
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
PY_MARKET_DEPENDENCY
python3 "$desktop_dir/scripts/install-agent-presets.py" "$runtime" "$desktop_dir" macOS
node "$desktop_dir/scripts/verify-agent-presets.mjs" "$runtime/config/agent-presets"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/node/bin" "$app/Contents/Resources/runtime" \
  "$app/Contents/Resources/pnpm" "$app/Contents/Resources/desktop"
swiftc -parse-as-library -O -whole-module-optimization \
  -target arm64-apple-macos15.0 \
  -framework Cocoa -framework WebKit \
  "$app_dir/src/main.swift" \
  -o "$app/Contents/MacOS/DeepSeek Harness"
cp "$app_dir/resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $bundle_version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
cp "$node_root/bin/node" "$app/Contents/Resources/node/bin/node"
cp "$node_root/LICENSE" "$app/Contents/Resources/node/LICENSE"
cp -R "$pnpm_root"/. "$app/Contents/Resources/pnpm/"
cat > "$app/Contents/Resources/node/bin/pnpm" <<'PNPM_LAUNCHER'
#!/bin/sh
set -eu
bin_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$bin_dir/node" "$bin_dir/../../pnpm/bin/pnpm.cjs" "$@"
PNPM_LAUNCHER
chmod 755 "$app/Contents/Resources/node/bin/pnpm"
cp "$desktop_dir/resources/market.patch.yml" "$app/Contents/Resources/desktop/market.patch.yml"
cp "$desktop_dir/resources/market-conflict.patch.yml" "$app/Contents/Resources/desktop/market-conflict.patch.yml"
cp "$desktop_dir/scripts/reset-web-profile.mjs" "$app/Contents/Resources/desktop/reset-web-profile.mjs"
cp "$desktop_dir/scripts/diagnose-web-plugins.mjs" "$app/Contents/Resources/desktop/diagnose-web-plugins.mjs"
cp "$app_dir/resources/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp -R "$runtime"/. "$app/Contents/Resources/runtime/"
mkdir -p "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled"
cp -R "$market_root"/. "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled/"
python3 "$desktop_dir/scripts/patch-market.py" \
  "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled" \
  "$desktop_dir/resources/market-overrides.json"
node --check "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled/lib/registry.js"
node --check "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled/lib/routes.js"
node --check "$app/Contents/Resources/runtime/node_modules/dshmarket-bundled/client/client.js"
python3 - "$app" "$root" <<'PY_LINKS'
from pathlib import Path
import os
import shutil
import sys

app = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
runtime = app / "Contents/Resources/runtime"
workspace_manifests = [
    *root.glob("vendor/*/package.json"),
    *root.glob("packages/*/*/package.json"),
    *root.glob("apps/*/package.json"),
    *root.glob("native/*/package.json"),
    *root.glob("native/*/packages/*/package.json"),
]
workspace_packages = {}
for manifest in workspace_manifests:
    import json

    metadata = json.loads(manifest.read_text())
    name = metadata.get("name")
    if isinstance(name, str):
        workspace_packages[name] = manifest.parent

while True:
    missing = set()
    for manifest in runtime.rglob("package.json"):
        if ".pnpm" in manifest.parts:
            continue
        import json

        metadata = json.loads(manifest.read_text())
        for field in ("dependencies", "peerDependencies"):
            for dependency in metadata.get(field, {}):
                if dependency.startswith("@deepseek-ai/") and not (runtime / "node_modules" / dependency).exists():
                    missing.add(dependency)
    if not missing:
        break
    unresolved = sorted(missing - workspace_packages.keys())
    if unresolved:
        raise SystemExit(f"macOS build: workspace dependencies cannot be resolved: {', '.join(unresolved)}")
    for dependency in sorted(missing):
        source = workspace_packages[dependency]
        destination = runtime / "node_modules" / dependency
        shutil.copytree(
            source,
            destination,
            ignore=shutil.ignore_patterns("node_modules", ".artifacts", "tsconfig.json", "tsdown.config.ts"),
        )
        metadata = json.loads((destination / "package.json").read_text())
        entry = metadata.get("module") or metadata.get("main")
        if isinstance(entry, str) and not (destination / entry).exists():
            raise SystemExit(f"macOS build: {dependency} is missing its built entry: {entry}")
replacements = {
    app / "apps/cli": runtime,
    app / "vendor/cosmokit": runtime / "node_modules/@deepseek-ai/cosmokit",
    app / "vendor/schemastery": runtime / "node_modules/@deepseek-ai/schemastery",
}
optional = {
    app / "native/landlock-run/packages/linux-arm64",
    app / "native/landlock-run/packages/linux-x64",
}

for link in [entry for entry in app.rglob("*") if entry.is_symlink() and not entry.exists()]:
    resolved = link.resolve(strict=False)
    if resolved in optional:
        link.unlink()
        continue
    target = replacements.get(resolved)
    if target is None:
        continue
    if not target.exists():
        raise SystemExit(f"macOS build: replacement target is missing: {target}")
    link.unlink()
    link.symlink_to(os.path.relpath(target, link.parent), target_is_directory=True)

broken = [entry for entry in app.rglob("*") if entry.is_symlink() and not entry.exists()]
if broken:
    formatted = "\n".join(f"  {entry} -> {entry.readlink()}" for entry in broken)
    raise SystemExit(f"macOS build: broken runtime symlinks remain:\n{formatted}")
PY_LINKS
python3 - "$app" <<'PY_MINIMUM_OS'
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1])
with (app / "Contents/Info.plist").open("rb") as stream:
    declared_text = plistlib.load(stream)["LSMinimumSystemVersion"]

def version(value):
    return tuple(int(part) for part in value.split("."))

declared = version(declared_text)
magics = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
failures = []
verified = 0
for path in app.rglob("*"):
    if path.is_symlink() or not path.is_file():
        continue
    try:
        with path.open("rb") as stream:
            if stream.read(4) not in magics:
                continue
    except OSError:
        continue
    architectures = subprocess.run(
        ["lipo", "-archs", str(path)], capture_output=True, text=True, check=True
    ).stdout.split()
    if "arm64" not in architectures:
        continue
    output = subprocess.run(
        ["otool", "-arch", "arm64", "-l", str(path)], capture_output=True, text=True, check=True
    ).stdout
    minimums = []
    for block in re.split(r"(?=Load command \d+)", output):
        if "cmd LC_BUILD_VERSION" in block:
            match = re.search(r"\bminos\s+([0-9]+(?:\.[0-9]+){1,2})", block)
        elif "cmd LC_VERSION_MIN_MACOSX" in block:
            match = re.search(r"\bversion\s+([0-9]+(?:\.[0-9]+){1,2})", block)
        else:
            continue
        if match:
            minimums.append(version(match.group(1)))
    if not minimums:
        failures.append(f"{path}: no macOS minimum version load command")
        continue
    required = max(minimums)
    verified += 1
    if required > declared:
        rendered = ".".join(str(part) for part in required)
        failures.append(f"{path}: requires macOS {rendered}, plist declares {declared_text}")
if failures:
    raise SystemExit("macOS build: incompatible arm64 binaries:\n  " + "\n  ".join(failures))
print(f"macOS build: verified {verified} arm64 Mach-O files against macOS {declared_text}")
PY_MINIMUM_OS
"$app_dir/scripts/create-icon.sh" "$app_dir/resources/icon.svg" "$app/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "DeepSeek Harness" -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg" >/dev/null
sha256=$(shasum -a 256 "$dmg" | awk '{print $1}')
printf 'VERSION=%s\nBUNDLE_VERSION=%s\nBUILD=%s\nAPP=%s\nDMG=%s\nSHA256=%s\n' \
  "$version" "$bundle_version" "$build_number" "$app" "$dmg" "$sha256"
