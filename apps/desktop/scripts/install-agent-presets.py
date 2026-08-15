#!/usr/bin/env python3
"""Install checksum-pinned community presets into a desktop runtime."""

from hashlib import sha256
from pathlib import Path
import json
import shutil
import sys


def fail(platform: str, message: str) -> "NoReturn":
    raise SystemExit(f"{platform} build: {message}")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: install-agent-presets.py RUNTIME DESKTOP_DIR PLATFORM")
    runtime = Path(sys.argv[1]).resolve()
    desktop = Path(sys.argv[2]).resolve()
    platform = sys.argv[3]
    source = desktop / "resources/agent-presets"
    manifest_path = desktop / "resources/anchored-standard-source.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("repository") != "https://github.com/xiaobright/dsh-anchored-standard":
        fail(platform, "anchored-standard repository provenance is unexpected")
    commit = manifest.get("commit")
    if not isinstance(commit, str) or len(commit) != 40 or any(char not in "0123456789abcdef" for char in commit):
        fail(platform, "anchored-standard source commit is invalid")
    if manifest.get("license") != "MIT":
        fail(platform, "anchored-standard license is unexpected")
    presets = manifest.get("presets")
    if not isinstance(presets, dict) or set(presets) != {"anchored-standard", "zero-anchored-standard"}:
        fail(platform, "anchored-standard preset manifest is unexpected")

    expected_paths: set[Path] = set()
    for preset_id, files in presets.items():
        if not isinstance(files, dict) or "agent.cordis.yml" not in files or "preset.yml" not in files:
            fail(platform, f"{preset_id} source manifest is incomplete")
        for relative, expected_hash in files.items():
            path = source / preset_id / relative
            expected_paths.add(path)
            if not path.is_file():
                fail(platform, f"{preset_id} source file is missing: {relative}")
            actual_hash = sha256(path.read_bytes()).hexdigest()
            if actual_hash != expected_hash:
                fail(platform, f"{preset_id} checksum mismatch for {relative}")

    actual_paths = {path for path in source.rglob("*") if path.is_file()}
    if actual_paths != expected_paths:
        unexpected = sorted(str(path.relative_to(source)) for path in actual_paths - expected_paths)
        fail(platform, f"anchored-standard source contains unexpected files: {', '.join(unexpected)}")

    target_root = runtime / "config/agent-presets"
    if not (target_root / "standard/agent.cordis.yml").is_file():
        fail(platform, "runtime shipped preset root is missing")
    for preset_id in presets:
        target = target_root / preset_id
        if target.exists() or target.is_symlink():
            fail(platform, f"refusing to overwrite shipped preset {preset_id}")
        shutil.copytree(source / preset_id, target)


if __name__ == "__main__":
    main()
