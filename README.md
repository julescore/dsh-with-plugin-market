# dsh-with-plugin-market

English | [中文](README.zh.md)

A community desktop distribution of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) with a built-in plugin marketplace. The repository is named `dsh-with-plugin-market`; the installed application remains **DeepSeek Harness** on every platform.

Install one application, open **Settings → Plugin Market**, and browse or install curated community plugins without separately setting up Node.js or pnpm. The application runs the original DeepSeek Harness Web UI and keeps its plugin-based architecture; this repository adds native desktop packaging, a bundled marketplace, and distribution checks.

> This is an independent community distribution, not an official DeepSeek AI release. DeepSeek Harness is in developer preview and may introduce compatibility-breaking changes.

## What you get

- Native **DeepSeek Harness** applications for macOS Apple Silicon and Windows x64.
- A self-contained runtime with Node.js, pnpm, and `dshmarket` included.
- A built-in plugin marketplace with search, categories, themes, install, update, and uninstall actions.
- One-click installation for curated plugins, including a distribution-safe mapping for the `dsh-web-ui` collection.
- A startup choice when a local plugin market conflicts with the packaged market, so exactly one market is active.
- Isolated platform packaging verification before a release is accepted.

Community plugins execute third-party code on your computer. Review and trust a plugin's source before installing it. Registry inclusion is not a security endorsement, and build scripts remain blocked unless an explicit distribution rule or user decision allows them.

<a id="run"></a>

## Download and use

Download the latest installer from [GitHub Releases](https://github.com/julescore/dsh-with-plugin-market/releases):

- **macOS 15+ Apple Silicon:** open the `.dmg`, then drag **DeepSeek Harness** into Applications. The community build is ad-hoc signed and is not Apple-notarized.
- **Windows 10/11 x64:** run the `windows-x64-setup.exe` installer. Microsoft Edge WebView2 Runtime is required and is normally included with supported Windows versions.

After launch, open **Settings → Plugin Market** to install plugins. Settings, sessions, credentials, and profile plugins use the normal `.dsh` user directory, so the desktop application and `dsh` CLI share local state.

<a id="run-from-source"></a>

## Build locally

Install Node.js `^22.19 || >=24`, Corepack, and the platform toolchain, then install workspace dependencies:

```sh
git clone https://github.com/julescore/dsh-with-plugin-market.git
cd dsh-with-plugin-market
corepack enable
pnpm install --frozen-lockfile
```

On macOS 15+ with Xcode Command Line Tools:

```sh
pnpm run build:macos
pnpm run verify:macos
```

On Windows 10/11 x64 with .NET 8 SDK and Inno Setup 6:

```powershell
pnpm run build:windows
pnpm run verify:windows
```

See the [shared desktop version reference](apps/desktop/README.md), [macOS packaging reference](apps/macos/README.md), and [Windows packaging reference](apps/windows/README.md).

## GitHub Actions

[Desktop Build](.github/workflows/desktop-build.yml) builds and verifies macOS arm64 and Windows x64 artifacts on native GitHub-hosted runners. Manual runs upload both Actions artifacts; tags named `desktop-vX.Y.Z` or `desktop-vX.Y.Z-rc.N` create a GitHub Release only after both platform jobs succeed.

[Sync Upstream](.github/workflows/sync-upstream.yml) checks the official `deepseek-ai/deepseek-harness` `master` branch weekly and opens or updates a pull request into this repository. Upstream changes are reviewed and built before merge rather than being written directly to the distribution branch.

## Upstream and development

DeepSeek Harness uses an architecture where **everything is a plugin**, powered by [Cordis](https://github.com/cordiverse/cordis). This distribution intentionally keeps upstream package names and product identity unchanged so official source updates stay mergeable.

For upstream architecture and development documentation, see [docs/architecture.md](docs/architecture.md), [docs/development.md](docs/development.md), and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). Distribution-specific third-party notices are included beside each platform runtime.
