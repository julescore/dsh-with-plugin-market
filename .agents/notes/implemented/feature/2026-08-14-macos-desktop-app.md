# Agent Note: Native macOS desktop application

Status: implemented

English | [中文](2026-08-14-macos-desktop-app.zh.md)

## Problem

DeepSeek Harness is runnable from a terminal and exposes a Web client, but macOS users do not have a self-contained application that launches the assembled product with a double click. Requiring a separately installed Node.js toolchain and a manual Host command makes local desktop use depend on development setup. A desktop distribution must retain the existing Host, Web client, profile data, and credential ownership rather than fork them into a second product implementation.

## Decision

**A native AppKit shell owns desktop launch and presentation.** The application compiles from one Swift source file, creates a standard macOS window, and displays the existing Web client in `WKWebView`. It does not reproduce Harness services or client behavior in Swift.

**The bundle owns a pinned production runtime.** The build embeds the Apple Silicon Node.js 24.19.0 executable, the built CLI and Web assets, and their production dependency closure. It also embeds `dshmarket@1.2.3` and `pnpm@11.7.0` as distribution-only resources. The three archives are accepted only when their pinned SHA-256 digests match. Workspace packages omitted by deployment metadata are materialized from the same checked-out source and must already contain their built entry points.

**The desktop application preloads a plugin market without changing the CLI product.** An application-owned `--patch` mounts dshmarket only for the AppKit launch. The market restricts installation requests to its curated registry, prefers repository-mapped npm packages, and retains user confirmation; registry inclusion is not a security endorsement. The macOS distribution maps the `dsh-web-ui` repository URL and its current `packages/dsh-web-ui-all` catalog URL to the author's prebuilt `@linxin666/dsh-web-ui-all` aggregate because the repository root is not a profile bundle. It bypasses pnpm's one-day release wait only for `dshmarket` self-updates, allowing the first update attempt to repair an older market while ordinary plugin updates retain the upstream safety wait. Before installing that aggregate, it records `false` for the `cloudflared`, `cpu-features`, and `ssh2` build scripts when no user decision exists, preventing binary downloads and native compilation without broadening any permission. Existing decisions and all other registry entries remain untouched. Bundled pnpm makes plugin management independent of the user's shell setup. Market and package-manager license declarations ship beside the runtime.

**An existing local market requires an explicit source choice.** Before boot, the shell dumps the effective Web composition and checks its top-level rows for `dsh-market`. A conflict alert offers the local market, the packaged market, or exit. The local choice applies no desktop market patch. The packaged choice disables the local row only in the running composition and inserts the packaged code through the `dshmarket-bundled` alias, whose package metadata and client registration ID are rewritten together during assembly. The choice is not persisted, and neither branch edits or removes local profile data.

**The existing Web Host remains the application boundary.** The shell launches `dsh web --port 0` with the patch selected for the current market state, accepts only the reported `127.0.0.1` readiness origin in its Web view, and sends external HTTP or HTTPS navigation to the system browser. The random loopback port avoids a fixed-port collision and does not expose the Host on a LAN interface.

**Desktop use retains the normal user data location.** The Host starts from the user home directory and uses `~/.dsh`. Settings, sessions, and credential references are not copied into or migrated by the application bundle.

**The shell owns the Host lifecycle.** Application termination sends `SIGTERM` to the child process and escalates to `SIGKILL` after six seconds. Startup failure or an unexpected child exit replaces the loading surface with an error instead of leaving an inert Web view.

**The distribution retains the upstream product identity.** As refined by [the cross-platform identity decision](2026-08-15-cross-platform-desktop-distribution.md), the repository is `dsh-with-plugin-market`, while the application and DMG use `DeepSeek Harness`. The `io.github.julescore.dsh-with-plugin-market` bundle identifier records the distributor. Upstream `@deepseek-ai/*` package names and internal product composition remain unchanged so official source updates stay mergeable.

**GitHub automation builds releases and proposes upstream synchronization.** The desktop workflow builds and verifies macOS arm64 and Windows x64 artifacts on native runners and publishes a release only when both succeed for a version-matching `desktop-v*` tag. A weekly workflow merges official `deepseek-ai/deepseek-harness` `master` into a dedicated branch and opens a pull request; it never writes upstream changes directly to the distribution branch.

**The repository build produces local-installation artifacts.** `pnpm run build:macos` creates an arm64 `.app` and versioned compressed DMG under `.artifacts/macos`. It applies and verifies an ad-hoc signature. Developer ID signing and Apple notarization remain external release operations because the repository does not own distribution credentials.

**The desktop distributions have an independent shared release version.** `apps/desktop/version.json` is the only source for the macOS and Windows release version and monotonically increasing build number; the root workspace package version does not control desktop releases. RC suffixes remain in the DMG name while `CFBundleShortVersionString` receives the stable three-part version and `CFBundleVersion` receives the integer build number.

**Formal packaging advances and verifies the version transactionally.** `pnpm run package:macos` advances the release candidate by default, builds the application, and verifies the mounted DMG with an isolated temporary `DSH_HOME`. Explicit release, semantic-version, and target-version transitions are available. The new manifest remains only after all steps succeed; a failure restores the prior bytes and removes incomplete output without deleting older versioned DMGs.

## Alternatives considered

**Electron or another bundled browser runtime.** Rejected because the product already has a Web client and macOS supplies WebKit. AppKit plus `WKWebView` adds substantially less runtime and packaging surface while preserving the existing client.

**Open the Web client in the default browser.** Rejected because it does not provide an application window or desktop lifecycle ownership and leaves the Host process detached from the surface users close.

**Rewrite the client or Host as native Swift.** Rejected because it would create a second implementation of plugin composition, session behavior, settings, and the client experience rather than distribute the assembled product.

**Require system Node.js or pnpm installations.** Rejected because double-click launch and market installation must not depend on shell configuration or a compatible developer toolchain. Pinning the embedded tools also makes their versions explicit.

**Add the market to the shipped Web profile.** Rejected because that changes every CLI and Web launch. A desktop-only overlay keeps the requested distribution behavior within the DMG.

**Use a fixed local port.** Rejected because simultaneous development or application instances could collide. The Host already supports selecting an available port and reporting its readiness URL.

**Use the root package version for desktop releases.** Rejected because the workspace and desktop artifact have different release cadences; coupling them would create unrelated workspace version changes.

**Repeat versions in scripts and `Info.plist`.** Rejected because multiple editable copies drift. The build injects both Apple fields and the DMG name from one validated manifest.

**Advance the version even when packaging fails.** Rejected because an unshipped attempt must not consume a release identifier or build number. The package command commits the manifest change only by completing build and verification.

## Verification contract

The bundle must pass strict deep signature verification, contain no broken symbolic links, and contain no arm64 Mach-O whose load commands require a macOS version above the plist declaration. A launch from the mounted DMG must create a visible layer-zero window, start a child Host listening only on `127.0.0.1`, expose the market Host route and Web client, and release both the child process and its port after application termination. With only the bundled package manager on `PATH`, verification must install `dsh-web-ui` through the market, prove that the npm aggregate is a profile layer, inspect the three explicit build-script denials, restart the Host, find all seven aggregate clients in the Web boot graph, and uninstall the aggregate. Isolated fresh and conflicting homes must prove that the fresh, local-choice, and packaged-choice launches each activate exactly one market client and that both conflict choices preserve the profile manifest. The packaging verifier must leave the user credential store untouched and keep existing installed application processes running. Documentation gates keep the English and Chinese references and this decision record paired.

## Consequences

A macOS Apple Silicon user can install the DMG, launch the same Harness Web product, and manage curated plugins without installing Node.js or pnpm. The application continues to share the CLI profile and credentials, so desktop and terminal use are not isolated. Plugins installed from the desktop market therefore also change the shared Web profile. The bundle is larger because it carries Node.js, pnpm, dshmarket, and the complete production dependency graph. It requires macOS 15.0 or later because that is the highest minimum encoded by the bundled arm64 native dependency set. Successful formal packaging increments the application build number and preserves earlier versioned DMGs, while ordinary rebuilds keep the current version. The ad-hoc signature is suitable for local delivery and verification but not frictionless public download; a release intended for external users still needs Apple signing and notarization. Intel Macs are unsupported until the build adds an x64 runtime and executable or produces a universal application.
