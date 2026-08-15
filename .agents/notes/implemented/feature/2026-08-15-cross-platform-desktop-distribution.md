# Agent Note: Cross-platform desktop distribution identity

Status: implemented

English | [中文](2026-08-15-cross-platform-desktop-distribution.zh.md)

## Problem

The first community desktop package used the repository distribution label as the macOS application name and implemented only an AppKit shell. Repository naming must not replace the upstream product identity, and a release advertised as a desktop distribution needs a native Windows installation path with equivalent runtime and plugin-market behavior.

## Decision

**The repository and product identities are independent.** The repository remains `dsh-with-plugin-market`, while installed applications, windows, shortcuts, disk images, installers, and release titles use **DeepSeek Harness**. Platform bundle identifiers may retain repository ownership metadata because they identify the distributor rather than visible product branding.

**Platform shells remain native and share the assembled product.** macOS keeps its AppKit and `WKWebView` shell. Windows uses a .NET 8 WinForms shell and the system Microsoft Edge WebView2 Runtime. Neither shell reimplements Harness services or Web client behavior; both launch the same bundled production runtime on an ephemeral loopback port, restrict embedded navigation to that origin, and send external links to the system browser.

**Both platforms use one distribution policy and version.** `apps/desktop` owns the release manifest, plugin-market patches, curated source mapping, market patcher, and checksum-pinned community preset sources. macOS and Windows package the same pinned Node.js, pnpm, `dshmarket`, Harness runtime, conflict choices, `dsh-web-ui` install policy, and two presets from `xiaobright/dsh-anchored-standard`. The community presets retain their experimental names, appear as selectable system presets, and leave `standard` as the default. A release tag is valid only when both artifacts report the same shared version.

**Windows ships a self-contained native shell and a conventional installer.** The x64 build publishes the .NET runtime with the WinForms shell, embeds Node and Harness, and uses Inno Setup to create a per-user-capable installer. WebView2 Runtime stays a system prerequisite because supported Windows versions normally provide it and the application emits a direct error when it is absent.

**A release requires native validation on both operating systems.** Both builders reject a community-preset checksum mismatch or id collision and run a keyless test of each preset's bootstrap and promotion behavior. macOS verification mounts the DMG and exercises the runtime and market. Windows verification silently installs into an isolated directory and runs shell resource and branding checks. Each installed-runtime verifier asks the Host API to list both presets and create a blank session from each, proving the complete Cordis compositions mount. The market checks still install and remove the curated aggregate and exercise both conflict choices. The release job depends on both platform jobs and cannot publish a one-platform artifact set.

## Alternatives considered

**Rename only the macOS bundle.** Rejected because release files, window titles, shortcuts, documentation, and future platforms would continue to drift between repository and product identity.

**Use the macOS Swift shell on Windows.** Rejected because AppKit and `WKWebView` are macOS-only. A native Windows shell preserves lifecycle and presentation ownership without adding a full Chromium runtime.

**Use Electron for both platforms.** Rejected for this change because it would replace the already verified native macOS shell and add another browser runtime. Native system Web views keep the distribution smaller and leave product behavior in the existing Web client.

**Publish Windows before running it on Windows.** Rejected because cross-compiling or checking source on macOS cannot establish installer behavior, process-tree shutdown, path quoting, WebView2 loading, or Windows plugin installation.

**Install the community presets into each user's writable preset directory.** Rejected because an application update would then mutate user state, collide with locally owned preset ids, and leave old copies behind. Shipping them in the read-only system preset root makes provenance and replacement follow the application version.

**Make an experimental community preset the default.** Rejected because its upstream evidence is model- and workload-specific. Bundling makes the modes available without treating a local evaluation result as a universal improvement.

## Consequences

Users see the upstream DeepSeek Harness product name regardless of where they downloaded the community build. The GitHub release can provide macOS arm64 and Windows x64 installers from one versioned source. The two experimental community presets are immediately available for new sessions without changing the Standard default or writing to the user's preset directory. Updating their pinned commit is an explicit source-review task because each preset snapshots the upstream Standard composition. Windows users do not need Node.js, pnpm, or .NET installed separately, but they need WebView2 Runtime. The two native shells require platform-specific maintenance, while shared distribution resources prevent marketplace, preset, and version behavior from diverging.
