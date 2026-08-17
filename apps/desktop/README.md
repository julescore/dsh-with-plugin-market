# Shared desktop distribution resources

English | [中文](README.zh.md)

This directory owns the version manifest, plugin-market policy, bundled vision-plugin layer, and checksum-pinned community agent presets shared by the native macOS and Windows distributions. Platform shells and installers remain under `apps/macos/` and `apps/windows/`.

`resources/agent-presets/` contains the two experimental presets copied from `xiaobright/dsh-anchored-standard`; `resources/anchored-standard-source.json` fixes the upstream commit and every source checksum. Both platform builders run `scripts/install-agent-presets.py`, which refuses checksum drift or a preset-id collision, and then run the keyless behavior verifier. The presets are selectable for new sessions but do not replace the upstream `standard` default.

Advance the shared application version once before producing a release:

```sh
node --import tsx/esm apps/desktop/scripts/version.ts bump
```

Both platform artifacts must report the same value from `apps/desktop/version.json`.

The bundled market treats each install and update as a profile transaction. It snapshots `package.json`, `pnpm-lock.yaml`, and `pnpm-workspace.yaml`, composes the complete Web profile with `dsh --profile web --dump-config`, and restores the exact files plus the old offline lockfile resolution when the new plugin tree is invalid. This prevents incompatible plugins, including duplicate loader entry ids, from breaking the next launch.

If an older application already left an invalid Web profile, both desktop shells offer **Back up and reset Web profile** on the startup error screen. Recovery moves only `$DSH_HOME/profiles/web` into `$DSH_HOME/profile-backups/`; sessions, settings, credentials, personal agent presets, and other profiles remain in place.

Before that fallback, a shared diagnosis script matches structured startup diagnostics (failed Cordis load/activation entries, unresolved modules, and `node_modules`/`.pnpm` paths) against the Web profile's `package.json` dependencies. When a startup failure names one or more installed plugins, the desktop shell lists them and offers one-click uninstall followed by an automatic restart.
