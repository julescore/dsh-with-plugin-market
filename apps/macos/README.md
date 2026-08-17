# macOS application

English | [中文](README.zh.md)

This directory owns the native macOS arm64 distribution. The installed application and disk image are branded **DeepSeek Harness**; `dsh-with-plugin-market` is only the repository name.

## Runtime and plugin market

`src/main.swift` creates an AppKit window containing `WKWebView`. It starts the bundled Node.js 24.19.0 production Harness runtime on an ephemeral loopback port and limits embedded navigation to that origin. External HTTP and HTTPS links open in the default browser. The child uses the user's home directory, normal `~/.dsh` state, and bundled pnpm 11.7.0; the application never copies credentials.

A menu-bar status item is installed at launch. Closing the window only hides it; the Harness process keeps running, and clicking the status item (or the Dock icon) reopens the window. Quitting through the application or status-item menu stops the background process.

The application always mounts the repository-owned `vision-image-model` plugin, which provides a settings card and the local-path-only `vision_read_image` tool, and mounts the shared `apps/desktop/resources/market.patch.yml`, which preloads `dshmarket@1.2.3`. If `dsh web --dump-config` detects an existing `dsh-market` row, the user chooses the local market or the packaged market for that launch. The packaged choice disables the local row only in process composition; it does not modify plugins, sessions, credentials, or profile files.

The shared distribution policy maps the `dsh-web-ui` repository and catalog subdirectory to `@linxin666/dsh-web-ui-all`, bypasses the release-age wait only for market self-updates, and explicitly denies the `cloudflared`, `cpu-features`, and `ssh2` build scripts unless the user already made a choice. It also installs the checksum-pinned **Anchored Standard (experimental)** and **Zero-Anchored Standard (experimental)** community presets as non-default system presets. Community plugins and presets remain third-party code and require user trust.

Every market install or update must pass a complete Web-profile composition before it is accepted. A failure restores the dependency manifest, lockfile, build policy, and prior installed resolution. If startup still encounters an invalid profile created by an older build or another tool, the error page can move only the Web profile to a timestamped backup under `$DSH_HOME/profile-backups/` and reopen the application; sessions, settings, credentials, and personal presets are preserved. When the startup diagnostic names specific installed plugins, the error page lists them and offers one-click uninstall and restart before the full-profile reset fallback.

## Build and verify

Requirements: macOS 15+, Apple Silicon, Xcode Command Line Tools, Node.js `^22.19 || >=24`, Corepack, and first-build network access.

```sh
pnpm install --frozen-lockfile
pnpm run build:macos
pnpm run verify:macos
```

The build embeds the runtime, pinned Node and pnpm archives, patched market, native AppKit executable, icon, and notices. It validates every embedded arm64 Mach-O minimum OS, applies ad-hoc signing, and creates:

```text
.artifacts/macos/DeepSeek Harness.app
.artifacts/macos/DeepSeek-Harness-<version>-macos-arm64.dmg
```

`verify:macos` mounts the DMG in a clean location and checks the bundle identity, signature, runtime closure, packaged recovery behavior, bundled vision package/configuration/settings client/tool declaration, both community preset behaviors, preset discovery and complete composition through the Host API, plugin market registry, `dsh-web-ui` install/restart/uninstall path, both conflict choices, and a real `dshmarket@1.1.0` to `1.2.3` first-click update.

## Shared version and release

[`../desktop/version.json`](../desktop/version.json) is the only desktop release version and build-number source for both macOS and Windows. Rebuild the current version with the commands above. To advance the shared version and package macOS transactionally:

```sh
pnpm run package:macos
pnpm run package:macos -- --bump release
pnpm run package:macos -- --version 1.2.0-rc.1
```

The default bump advances `rc.N`. A failed build restores the previous shared version and removes incomplete current-attempt artifacts. Commit the updated shared manifest with the release changes.

## Distribution limitation

The current DMG uses ad-hoc signing and is not Apple-notarized. Public trust without a Gatekeeper warning requires Developer ID signing, notarization, and stapling; signing credentials are intentionally outside this repository.
