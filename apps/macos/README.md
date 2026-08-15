# macOS application

English | [中文](README.zh.md)

This directory owns the native macOS distribution of DSH with Plugin Market, a community distribution of DeepSeek Harness. It packages the existing Web application behind a small AppKit shell; it does not introduce a separate desktop product runtime.

## Runtime

`src/main.swift` creates an AppKit window containing `WKWebView`. On launch it uses the bundled Node.js 24.19.0 executable to inspect the effective Web profile and then starts the bundled production Harness runtime. A profile without a market receives `macos/market.patch.yml`; a profile that already contains the `dsh-market` row triggers the market-source choice described below.

The Host chooses an available loopback port and reports an `http://127.0.0.1:<port>` readiness URL. The shell loads only that origin, `about:` URLs, and `blob:` URLs in the embedded view. Other HTTP and HTTPS navigation opens in the default browser.

The child process starts with the user home directory as its working directory, so an ordinary application launch uses the normal `~/.dsh` settings, sessions, and credential references. The bundle does not copy credentials. Quitting the application sends `SIGTERM` to the child and sends `SIGKILL` if it has not exited after six seconds.

## Bundled plugin market

The macOS distribution preloads [`dshmarket@1.2.3`](https://github.com/dsh-market/dsh-market) through an application-owned `--patch` layer. This affects only the desktop application; ordinary CLI and Web launches keep their existing profile composition. The market appears under Settings → Plugin Market and reads a curated registry with an offline snapshot. Registry inclusion is not an endorsement: installing a plugin loads third-party code on the user's computer, so users must review and trust its source.

Before adding that layer, the shell runs `dsh web --dump-config` and checks the composed top-level rows for `dsh-market`. When a local market already exists, an alert offers **Use Local Plugin Market**, **Use Packaged Plugin Market**, or exit. The local choice starts without a desktop market patch. The packaged choice disables the local row for that process and inserts the bundled package under the distribution-only `dshmarket-bundled` alias. The choice is requested on every conflicting launch and changes no profile manifest, patch file, installed plugin, session, or credential.

Plugin management uses the bundled `pnpm@11.7.0`; double-click launches do not depend on a package manager in the user's shell. The distribution maps both the `dsh-web-ui` repository URL and its current `packages/dsh-web-ui-all` catalog URL to the author's prebuilt `@linxin666/dsh-web-ui-all` npm aggregate instead of installing the monorepo root. The packaged market also skips the normal one-day release wait only when updating `dshmarket` itself, so its first update click can repair an older market; ordinary plugin updates retain the wait unless the user explicitly chooses the upstream **Update now** override. Before that one aggregate is installed, the market records explicit `false` build-script choices for `cloudflared`, `cpu-features`, and `ssh2` unless the user already chose a value. This prevents an automatic Cloudflared binary download and native extension compilation while retaining the packages' non-install-script paths. Other registry entries and existing build permissions are unchanged. Both market and package-manager npm tarballs are version-pinned and accepted only when their SHA-256 digests match. The market and pnpm license declarations are recorded in `Contents/Resources/THIRD-PARTY-NOTICES.md`.

## Requirements

Building requires macOS 15.0 or later, Xcode Command Line Tools, Node.js `^22.19 || >=24`, pnpm through Corepack, and first-build network access for the pinned Node.js, pnpm, and dshmarket archives. The output supports Apple Silicon only.

Install the workspace dependencies after updating the checkout:

```sh
pnpm install --frozen-lockfile
```

## Version ownership

[`version.json`](version.json) is the only source for the macOS release version and Apple build number. It is intentionally independent from the root workspace package version.

```json
{
  "version": "0.1.0-rc.8",
  "build": 8
}
```

`version` accepts `X.Y.Z` and `X.Y.Z-rc.N`. It names the DMG and records the distributable release. `CFBundleShortVersionString` receives the stable `X.Y.Z` portion because Apple bundle marketing versions do not accept the release-candidate suffix. `CFBundleVersion` receives `build`, a positive integer incremented for every successful version transition. For example, release `0.1.0-rc.8` has bundle version `0.1.0` and build `8`.

Do not edit `Info.plist` to release a version. Its placeholder values are replaced from `version.json` during every build.

## Local rebuild

Rebuild the current version without consuming a new version number:

```sh
pnpm run build:macos
pnpm run verify:macos
```

`build:macos` builds the Harness workspaces, assembles the production dependency closure, embeds the pinned market and package manager, compiles the Swift shell and icon, verifies that the bundle has no broken symbolic links and that every arm64 Mach-O supports the declared macOS 15.0 minimum, applies an ad-hoc signature, and creates the current versioned DMG. `verify:macos` mounts that DMG read-only and checks its versions and signature. It then uses isolated fresh and conflicting `DSH_HOME` fixtures to prove that the fresh, local-market, and packaged-market paths each activate exactly one market client, preserve the conflicting profile manifest, listen only on loopback, and shut down cleanly. With only the bundled pnpm on `PATH`, the fresh path installs `dsh-web-ui` through the current catalog subdirectory URL, verifies the npm aggregate and its seven clients after a restart, checks the three explicit build-script denials, and uninstalls the aggregate. The conflict fixture installs `dshmarket@1.1.0` and proves one click updates it to 1.2.3 without the release-age wait. These fixtures prevent verification from reading or modifying the user's settings, sessions, or credentials.

## Formal package

After a code update and its relevant tests, create the next release candidate with:

```sh
pnpm run package:macos
```

The default transition advances `rc.N`, then builds and verifies the new artifact. A successful command retains the new `version.json`; a build or verification failure restores the previous file byte-for-byte and removes incomplete output for the attempted version. Older versioned DMGs remain available.

Use an explicit transition when the default is not appropriate:

```sh
pnpm run package:macos -- --bump rc
pnpm run package:macos -- --bump release
pnpm run package:macos -- --bump patch
pnpm run package:macos -- --bump minor
pnpm run package:macos -- --bump major
pnpm run package:macos -- --version 1.2.0-rc.1
pnpm run package:macos -- --version 1.2.0
```

The default `rc` transition changes `0.1.0-rc.8` to `0.1.0-rc.9`. When the current version is stable, it starts the next patch line, such as `0.1.0` to `0.1.1-rc.1`. `release` removes the RC suffix, while `patch`, `minor`, and `major` produce the next stable semantic version. An explicit version must be greater than the current release. Every successful transition increments `build` by exactly one.

The artifact paths are:

```text
.artifacts/macos/DSH with Plugin Market.app
.artifacts/macos/DSH-with-Plugin-Market-<version>-macos-arm64.dmg
```

The package command prints the final version, path, and SHA-256 digest. Before delivery, retain that output, optionally mount the DMG and launch the application for a visual smoke test, and confirm the expected version in Finder or `Info.plist`. Commit the updated `version.json` with the release source changes; do not commit `.artifacts/` unless a separate distribution policy requires binary artifacts in Git.

## Distribution limits

The current output uses an ad-hoc signature for local installation and is not Developer ID signed or notarized. Gatekeeper may therefore reject or warn about a downloaded copy. Public distribution requires a Developer ID Application signature, a Developer ID Installer or signed DMG as appropriate, Apple notarization, and staple verification; those credentials are intentionally outside this repository build.
