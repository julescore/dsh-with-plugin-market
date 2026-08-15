# DSH with Plugin Market

English | [中文](README.zh.md)

A community desktop distribution of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) with a built-in plugin marketplace.

Install one application, open **Settings → Plugin Market**, and browse or install curated community plugins without separately setting up Node.js or pnpm. The application runs the original DeepSeek Harness Web UI and keeps its plugin-based architecture; this repository adds the desktop packaging, bundled marketplace, and distribution checks.

> This is an independent community distribution, not an official DeepSeek AI release. DeepSeek Harness is in developer preview and may introduce compatibility-breaking changes.

## What you get

- A self-contained desktop application with the DeepSeek Harness runtime, Node.js, pnpm, and `dshmarket` included.
- A built-in plugin marketplace with search, categories, themes, install, update, and uninstall actions.
- One-click installation for curated plugins, including a distribution-safe mapping for the `dsh-web-ui` collection.
- A startup choice when a local plugin market conflicts with the packaged market, so exactly one market is active.
- Isolated packaging verification that exercises marketplace install, restart, update, and uninstall flows before a release is accepted.

Community plugins execute third-party code on your computer. Review and trust a plugin's source before installing it. Registry inclusion is not a security endorsement, and build scripts remain blocked unless an explicit distribution rule or user decision allows them.

<a id="run"></a>

## Download and use

Download the latest DMG from [GitHub Releases](https://github.com/julescore/dsh-with-plugin-market/releases), open it, and drag **DSH with Plugin Market** into Applications.

Current packaged target:

- macOS 15 or later
- Apple Silicon (`arm64`)
- ad-hoc signed for local/community testing; not Apple-notarized

After launch, open **Settings → Plugin Market** to install plugins. Settings, sessions, credentials, and profile plugins use the normal `~/.dsh` directory, so the desktop application and the `dsh` CLI share local state.

<a id="run-from-source"></a>

## Build locally

Prerequisites: macOS 15+, Xcode Command Line Tools, Node.js `^22.19 || >=24`, Corepack, and first-build network access.

```sh
git clone https://github.com/julescore/dsh-with-plugin-market.git
cd dsh-with-plugin-market
corepack enable
pnpm install --frozen-lockfile
pnpm run build:macos
pnpm run verify:macos
```

The versioned DMG is written under `.artifacts/macos/`. See the [macOS packaging reference](apps/macos/README.md) for release-version commands, embedded components, conflict behavior, and verification details.

## GitHub Actions

[Desktop Build](.github/workflows/desktop-build.yml) builds and verifies the macOS artifact on GitHub-hosted Apple Silicon runners. Manual runs upload an Actions artifact; tags named `desktop-vX.Y.Z` or `desktop-vX.Y.Z-rc.N` also create a GitHub Release with the DMG and checksum.

[Sync Upstream](.github/workflows/sync-upstream.yml) checks the official `deepseek-ai/deepseek-harness` `master` branch weekly and opens or updates a pull request into this repository. Upstream changes are reviewed and built before merge rather than being written directly to the distribution branch.

## Upstream and development

DeepSeek Harness uses an architecture where **everything is a plugin**, powered by [Cordis](https://github.com/cordiverse/cordis). This distribution intentionally keeps upstream package names and product internals unchanged so official updates remain mergeable.

For upstream architecture and development documentation, see [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md), and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Third-party dependencies and bundled distribution tools are disclosed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [apps/macos/resources/THIRD-PARTY-NOTICES.md](apps/macos/resources/THIRD-PARTY-NOTICES.md).
