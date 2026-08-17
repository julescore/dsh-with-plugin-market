#!/usr/bin/env bash
# Build-time profile staging for the standalone vision-image-model bundle.
#
# Usage:
#   bash vision-image-model/stage-profile.sh <stage-home> [profile]
#
# Produces a portable DSH_HOME at <stage-home>:
#   - the named profile is initialized from the dsh installation's template;
#   - this plugin is installed into the profile with `dsh plugin add file:...`;
#   - the absolute `file:` spec pnpm writes is removed from the profile
#     manifest, while the installed copy in the profile's node_modules and the
#     `dsh.profile.bundles` entry are kept, so the staged home can be copied to
#     another machine;
#   - a bundled default selection is written to settings.yaml when both
#     VISION_IMAGE_PROVIDER and VISION_IMAGE_MODEL are set.
#
# Optional environment:
#   DSH_BIN                 Command that runs the dsh CLI; defaults to "pnpm dsh".
#   VISION_IMAGE_PROVIDER   Provider route for the bundled default selection.
#   VISION_IMAGE_MODEL      Model id for the bundled default selection.
#
# This script lives inside the isolated folder and touches nothing outside it
# except the requested <stage-home>.

set -euo pipefail

stage_home="${1:-}"
profile="${2:-web}"
if [[ -z "$stage_home" ]]; then
  echo "usage: stage-profile.sh <stage-home> [profile]" >&2
  exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
plugin_dir="$root/vision-image-model"
dsh_bin="${DSH_BIN:-pnpm dsh}"

echo "vision-image-model: staging profile '$profile' into $stage_home"
rm -rf "$stage_home/profiles/$profile"
mkdir -p "$stage_home"

(
  cd "$root"
  DSH_HOME="$stage_home" $dsh_bin plugin --profile "$profile" add "file:$plugin_dir"
)

manifest="$stage_home/profiles/$profile/package.json"
node - "$manifest" <<'NODE'
const fs = require('node:fs')
const path = process.argv[2]
const manifest = JSON.parse(fs.readFileSync(path, 'utf8'))
delete (manifest.dependencies ?? {})['dsh-vision-image-model']
const bundles = manifest.dsh?.profile?.bundles ?? []
if (!bundles.includes('dsh-vision-image-model')) {
  throw new Error('staged profile bundles do not include dsh-vision-image-model')
}
fs.writeFileSync(path, `${JSON.stringify(manifest, null, 2)}\n`)
NODE

installed="$stage_home/profiles/$profile/node_modules/dsh-vision-image-model/dsh/index.js"
if [[ ! -f "$installed" ]]; then
  echo "vision-image-model: staged install is missing $installed" >&2
  exit 1
fi

if [[ -n "${VISION_IMAGE_PROVIDER:-}" && -n "${VISION_IMAGE_MODEL:-}" ]]; then
  settings="$stage_home/settings.yaml"
  if [[ -e "$settings" ]]; then
    echo "vision-image-model: $settings already exists; leaving it untouched" >&2
  else
    cat > "$settings" <<YAML
vision-image-model:
  provider: "$VISION_IMAGE_PROVIDER"
  model: "$VISION_IMAGE_MODEL"
YAML
    echo "vision-image-model: bundled default selection ${VISION_IMAGE_PROVIDER}/${VISION_IMAGE_MODEL}"
  fi
fi

(
  cd "$root"
  DSH_HOME="$stage_home" $dsh_bin --profile "$profile" --dump-config \
    | grep -Fq -- '- id: vision-image-model'
)

echo "vision-image-model: staged profile verified"
echo "DSH_HOME=$stage_home"
