# DSH with Plugin Market

[English](README.md) | 中文

这是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的社区桌面发行版，安装包内置插件市场。

只需安装一个应用，打开**设置 → 插件市场**，即可浏览或一键安装精选社区插件，无需另外配置 Node.js 或 pnpm。应用运行原版 DeepSeek Harness Web UI 并保留“一切皆插件”的架构；本仓库增加桌面封装、内置市场与发行验证。

> 这是独立社区发行版，不是 DeepSeek AI 官方发行版。DeepSeek Harness 仍处于开发者预览阶段，后续可能出现破坏兼容性的变更。

## 主要能力

- 自包含桌面应用，内置 DeepSeek Harness 运行时、Node.js、pnpm 与 `dshmarket`。
- 内置插件市场，支持搜索、分类、主题、安装、更新与卸载。
- 对精选插件提供一键安装，并为 `dsh-web-ui` 合集提供经过验证的安全映射。
- 本地插件市场与安装包市场冲突时让用户选择来源，保证同一时间只启用一个市场。
- 每次发行前在隔离环境中验证市场安装、重启、更新与卸载流程。

社区插件会在你的电脑上执行第三方代码。安装前请自行检查并信任插件源码；被目录收录不代表安全背书。构建脚本默认保持禁用，除非安装包的精确规则或用户决定明确允许。

<a id="run"></a>

## 下载与使用

从 [GitHub Releases](https://github.com/julescore/dsh-with-plugin-market/releases) 下载最新 DMG，打开后将 **DSH with Plugin Market** 拖入“应用程序”。

当前安装包支持：

- macOS 15 或更高版本
- Apple Silicon（`arm64`）
- 使用 ad-hoc 签名，适合本地与社区测试；尚未经过 Apple 公证

启动后进入**设置 → 插件市场**即可安装插件。设置、会话、凭据与 profile 插件仍使用标准的 `~/.dsh` 目录，因此桌面应用和 `dsh` CLI 会共享本地状态。

<a id="run-from-source"></a>

## 本地构建

前置条件：macOS 15+、Xcode Command Line Tools、Node.js `^22.19 || >=24`、Corepack，以及首次构建时可访问网络。

```sh
git clone https://github.com/julescore/dsh-with-plugin-market.git
cd dsh-with-plugin-market
corepack enable
pnpm install --frozen-lockfile
pnpm run build:macos
pnpm run verify:macos
```

带版本号的 DMG 会生成到 `.artifacts/macos/`。版本命令、内置组件、冲突处理与验证细节见 [macOS 打包参考](apps/macos/README.md)。

## GitHub Actions

[Desktop Build](.github/workflows/desktop-build.yml) 使用 GitHub 托管的 Apple Silicon runner 构建并验证 macOS 安装包。手动运行会上传 Actions 构建产物；创建 `desktop-vX.Y.Z` 或 `desktop-vX.Y.Z-rc.N` 标签时，还会创建包含 DMG 与校验值的 GitHub Release。

[Sync Upstream](.github/workflows/sync-upstream.yml) 每周检查官方 `deepseek-ai/deepseek-harness` 的 `master` 分支，并在本仓库创建或更新同步 PR。官方更新必须先经过审查和构建验证，不会直接写入发行分支。

## 上游与开发

DeepSeek Harness 由 [Cordis](https://github.com/cordiverse/cordis) 驱动，采用**一切皆插件**的架构。本发行版特意保持上游包名和产品内部结构不变，减少同步官方更新时的冲突。

上游架构与开发资料见 [docs/architecture.md](docs/architecture.md)、[docs/development.md](docs/development.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

采用 [MIT](LICENSE) 许可证。第三方依赖与内置发行工具的声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [apps/macos/resources/THIRD-PARTY-NOTICES.md](apps/macos/resources/THIRD-PARTY-NOTICES.md)。
