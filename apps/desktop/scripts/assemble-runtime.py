#!/usr/bin/env python3
"""Complete and validate the workspace package closure in a desktop runtime."""

from pathlib import Path
import json
import os
import shutil
import sys

runtime = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
platform = sys.argv[3]
workspace_manifests = [
    *root.glob("vendor/*/package.json"),
    *root.glob("packages/*/*/package.json"),
    *root.glob("apps/*/package.json"),
    *root.glob("native/*/package.json"),
    *root.glob("native/*/packages/*/package.json"),
]
workspace_packages = {}
for manifest in workspace_manifests:
    metadata = json.loads(manifest.read_text(encoding="utf-8"))
    name = metadata.get("name")
    if isinstance(name, str):
        workspace_packages[name] = manifest.parent

while True:
    missing = set()
    for manifest in runtime.rglob("package.json"):
        if ".pnpm" in manifest.parts:
            continue
        metadata = json.loads(manifest.read_text(encoding="utf-8"))
        for field in ("dependencies", "peerDependencies"):
            for dependency in metadata.get(field, {}):
                if dependency.startswith("@deepseek-ai/") and not (runtime / "node_modules" / dependency).exists():
                    missing.add(dependency)
    if not missing:
        break
    unresolved = sorted(missing - workspace_packages.keys())
    if unresolved:
        raise SystemExit(f"{platform} build: workspace dependencies cannot be resolved: {', '.join(unresolved)}")
    for dependency in sorted(missing):
        source = workspace_packages[dependency]
        destination = runtime / "node_modules" / dependency
        shutil.copytree(
            source,
            destination,
            ignore=shutil.ignore_patterns("node_modules", ".artifacts", "tsconfig.json", "tsdown.config.ts"),
        )
        metadata = json.loads((destination / "package.json").read_text(encoding="utf-8"))
        entry = metadata.get("module") or metadata.get("main")
        if isinstance(entry, str) and not (destination / entry).exists():
            raise SystemExit(f"{platform} build: {dependency} is missing its built entry: {entry}")

replacements = {
    root / "apps/cli": runtime,
    root / "vendor/cosmokit": runtime / "node_modules/@deepseek-ai/cosmokit",
    root / "vendor/schemastery": runtime / "node_modules/@deepseek-ai/schemastery",
}
optional_fragments = (
    "native/landlock-run/packages/linux-arm64",
    "native/landlock-run/packages/linux-x64",
    "native/landlock-run/packages/darwin-arm64",
    "native/landlock-run/packages/darwin-x64",
)
for link in [entry for entry in runtime.rglob("*") if entry.is_symlink() and not entry.exists()]:
    resolved = link.resolve(strict=False)
    normalized = resolved.as_posix()
    if any(fragment in normalized for fragment in optional_fragments):
        link.unlink()
        continue
    target = replacements.get(resolved)
    if target is None:
        continue
    if not target.exists():
        raise SystemExit(f"{platform} build: replacement target is missing: {target}")
    link.unlink()
    link.symlink_to(os.path.relpath(target, link.parent), target_is_directory=True)

broken = [entry for entry in runtime.rglob("*") if entry.is_symlink() and not entry.exists()]
if broken:
    formatted = "\n".join(f"  {entry} -> {entry.readlink()}" for entry in broken)
    raise SystemExit(f"{platform} build: broken runtime links remain:\n{formatted}")
