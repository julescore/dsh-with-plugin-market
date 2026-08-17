#!/usr/bin/env python3
"""Install the repository-owned vision plugin into a desktop runtime."""

from pathlib import Path
import json
import shutil
import sys

ALIAS = "dsh-vision-image-model-bundled"
SOURCE_NAME = "dsh-vision-image-model"
CLIENT_SOURCE_ID = f'id: "{SOURCE_NAME}"'
CLIENT_ALIAS_ID = f'id: "{ALIAS}"'
REQUIRED_FILES = {
    "package.json",
    "dsh/index.js",
    "dsh/client.js",
    "dsh/candidates.js",
    "dsh/local-image.js",
    "dsh/vision.js",
}


def fail(platform: str, message: str) -> "NoReturn":
    raise SystemExit(f"{platform} build: {message}")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: install-vision-plugin.py RUNTIME SOURCE PLATFORM")
    runtime = Path(sys.argv[1]).resolve()
    source = Path(sys.argv[2]).resolve()
    platform = sys.argv[3]
    manifest_path = source / "package.json"
    if not manifest_path.is_file():
        fail(platform, "vision-image-model package manifest is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("name") != SOURCE_NAME or manifest.get("private") is not True:
        fail(platform, "vision-image-model package identity is unexpected")
    missing = sorted(path for path in REQUIRED_FILES if not (source / path).is_file())
    if missing:
        fail(platform, f"vision-image-model source is incomplete: {', '.join(missing)}")
    client_path = source / "dsh/client.js"
    client_source = client_path.read_text(encoding="utf-8")
    if client_source.count(CLIENT_SOURCE_ID) != 1 or CLIENT_ALIAS_ID in client_source:
        fail(platform, "vision-image-model client module id is unexpected")
    symlinks = sorted(path.relative_to(source).as_posix() for path in source.rglob("*") if path.is_symlink())
    if symlinks:
        fail(platform, f"vision-image-model source contains symlinks: {', '.join(symlinks)}")

    runtime_manifest_path = runtime / "package.json"
    if not runtime_manifest_path.is_file():
        fail(platform, "runtime package manifest is missing")
    runtime_manifest = json.loads(runtime_manifest_path.read_text(encoding="utf-8"))
    dependencies = runtime_manifest.setdefault("dependencies", {})
    if not isinstance(dependencies, dict):
        fail(platform, "runtime dependencies are invalid")
    expected_dependency = f"file:node_modules/{ALIAS}"
    existing_dependency = dependencies.get(ALIAS)
    if existing_dependency is not None and existing_dependency != expected_dependency:
        fail(platform, f"runtime declares unexpected bundled vision alias {existing_dependency}")

    target = runtime / "node_modules" / ALIAS
    if target.exists() or target.is_symlink():
        fail(platform, f"refusing to overwrite bundled vision plugin {target}")
    shutil.copytree(
        source,
        target,
        ignore=shutil.ignore_patterns("test", "stage-profile.sh", "cordis.patch.yml"),
    )
    bundled_client_path = target / "dsh/client.js"
    bundled_client = bundled_client_path.read_text(encoding="utf-8").replace(CLIENT_SOURCE_ID, CLIENT_ALIAS_ID, 1)
    bundled_client_path.write_text(bundled_client, encoding="utf-8")
    bundled_manifest_path = target / "package.json"
    bundled_manifest = json.loads(bundled_manifest_path.read_text(encoding="utf-8"))
    bundled_manifest["name"] = ALIAS
    bundled_manifest.pop("scripts", None)
    bundled_manifest_path.write_text(json.dumps(bundled_manifest, indent=2) + "\n", encoding="utf-8")
    dependencies[ALIAS] = expected_dependency
    runtime_manifest_path.write_text(json.dumps(runtime_manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
