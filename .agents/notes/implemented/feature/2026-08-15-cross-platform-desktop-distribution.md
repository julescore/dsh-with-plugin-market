# Agent Note: Cross-platform desktop distribution identity

Status: implemented

English | [中文](2026-08-15-cross-platform-desktop-distribution.zh.md)

## Problem

The first community desktop package used the repository distribution label as the macOS application name and implemented only an AppKit shell. Repository naming must not replace the upstream product identity, and a release advertised as a desktop distribution needs a native Windows installation path with equivalent runtime and plugin-market behavior.

## Decision

**The repository and product identities are independent.** The repository remains `dsh-with-plugin-market`, while installed applications, windows, shortcuts, disk images, installers, and release titles use **DeepSeek Harness**. Platform bundle identifiers may retain repository ownership metadata because they identify the distributor rather than visible product branding.

**Platform shells remain native and share the assembled product.** macOS keeps its AppKit and `WKWebView` shell. Windows uses a .NET 8 WinForms shell and the system Microsoft Edge WebView2 Runtime. Neither shell reimplements Harness services or Web client behavior; both launch the same bundled production runtime on an ephemeral loopback port, restrict embedded navigation to that origin, and send external links to the system browser.

**Both platforms use one distribution policy and version.** `apps/desktop` owns the release manifest, plugin-market patches, curated source mapping, and market patcher. macOS and Windows package the same pinned Node.js, pnpm, `dshmarket`, Harness runtime, conflict choices, and `dsh-web-ui` install policy. A release tag is valid only when both artifacts report the same shared version.

**Windows ships a self-contained native shell and a conventional installer.** The x64 build publishes the .NET runtime with the WinForms shell, embeds Node and Harness, and uses Inno Setup to create a per-user-capable installer. WebView2 Runtime stays a system prerequisite because supported Windows versions normally provide it and the application emits a direct error when it is absent.

**A release requires native validation on both operating systems.** macOS verification mounts the DMG and exercises the runtime and market. Windows verification silently installs into an isolated directory, runs shell resource and branding checks, starts the installed runtime, calls the market registry, installs and removes the curated aggregate, and checks both conflict compositions. The release job depends on both platform jobs and cannot publish a one-platform artifact set.

## Alternatives considered

**Rename only the macOS bundle.** Rejected because release files, window titles, shortcuts, documentation, and future platforms would continue to drift between repository and product identity.

**Use the macOS Swift shell on Windows.** Rejected because AppKit and `WKWebView` are macOS-only. A native Windows shell preserves lifecycle and presentation ownership without adding a full Chromium runtime.

**Use Electron for both platforms.** Rejected for this change because it would replace the already verified native macOS shell and add another browser runtime. Native system Web views keep the distribution smaller and leave product behavior in the existing Web client.

**Publish Windows before running it on Windows.** Rejected because cross-compiling or checking source on macOS cannot establish installer behavior, process-tree shutdown, path quoting, WebView2 loading, or Windows plugin installation.

## Consequences

Users see the upstream DeepSeek Harness product name regardless of where they downloaded the community build. The GitHub release can provide macOS arm64 and Windows x64 installers from one versioned source. Windows users do not need Node.js, pnpm, or .NET installed separately, but they need WebView2 Runtime. The two native shells require platform-specific maintenance, while shared distribution resources prevent marketplace and version behavior from diverging.
