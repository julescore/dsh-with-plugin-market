# Shared desktop distribution resources

English | [中文](README.zh.md)

This directory owns the version manifest and plugin-market policy shared by the native macOS and Windows distributions. Platform shells and installers remain under `apps/macos/` and `apps/windows/`.

Advance the shared application version once before producing a release:

```sh
node --import tsx/esm apps/desktop/scripts/version.ts bump
```

Both platform artifacts must report the same value from `apps/desktop/version.json`.
