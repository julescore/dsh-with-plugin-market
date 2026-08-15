# Shared desktop distribution resources

English | [中文](README.zh.md)

This directory owns the version manifest, plugin-market policy, and checksum-pinned community agent presets shared by the native macOS and Windows distributions. Platform shells and installers remain under `apps/macos/` and `apps/windows/`.

`resources/agent-presets/` contains the two experimental presets copied from `xiaobright/dsh-anchored-standard`; `resources/anchored-standard-source.json` fixes the upstream commit and every source checksum. Both platform builders run `scripts/install-agent-presets.py`, which refuses checksum drift or a preset-id collision, and then run the keyless behavior verifier. The presets are selectable for new sessions but do not replace the upstream `standard` default.

Advance the shared application version once before producing a release:

```sh
node --import tsx/esm apps/desktop/scripts/version.ts bump
```

Both platform artifacts must report the same value from `apps/desktop/version.json`.
