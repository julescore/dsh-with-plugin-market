# dsh-with-plugin-market

[English](README.md) | 中文

这是 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的内置插件市场社区桌面发行版。Git 仓库名是 `dsh-with-plugin-market`；所有平台安装后的应用名称仍然是 **DeepSeek Harness**。

只需安装一个应用，打开**设置 → 插件市场**，即可浏览或一键安装精选社区插件，无需另外配置 Node.js 或 pnpm。应用运行原版 DeepSeek Harness Web UI 并保留“一切皆插件”的架构；本仓库增加原生桌面封装、内置市场与发行验证。

> 这是独立社区发行版，不是 DeepSeek AI 官方发行版。DeepSeek Harness 仍处于开发者预览阶段，后续可能出现破坏兼容性的变更。

## 主要能力

- 提供 macOS Apple Silicon 和 Windows x64 原生 **DeepSeek Harness** 应用。
- 自包含运行环境，内置 Node.js、pnpm 与 `dshmarket`。
- 内置插件市场，支持搜索、分类、主题、安装、更新与卸载。
- 对精选插件提供一键安装，并为 `dsh-web-ui` 合集提供经过验证的安全映射。
- 本地插件市场与安装包市场冲突时让用户选择来源，保证同一时间只启用一个市场。
- 每次发行前在对应平台的隔离环境中验证安装包。

社区插件会在你的电脑上执行第三方代码。安装前请自行检查并信任插件源码；被目录收录不代表安全背书。构建脚本默认保持禁用，除非安装包的精确规则或用户决定明确允许。

<a id="run"></a>

## 下载与使用

从 [GitHub Releases](https://github.com/julescore/dsh-with-plugin-market/releases) 下载对应安装包：

- **macOS 15+ Apple Silicon：**打开 `.dmg`，将 **DeepSeek Harness** 拖入“应用程序”。社区构建使用 ad-hoc 签名，尚未经过 Apple 公证。
- **Windows 10/11 x64：**运行 `windows-x64-setup.exe` 安装程序。应用需要 Microsoft Edge WebView2 Runtime，受支持的 Windows 通常已内置。

启动后进入**设置 → 插件市场**即可安装插件。设置、会话、凭据与 profile 插件仍使用标准的 `.dsh` 用户目录，因此桌面应用和 `dsh` CLI 会共享本地状态。

<a id="run-from-source"></a>

## 本地构建

安装 Node.js `^22.19 || >=24`、Corepack 和对应平台工具链，再安装工作区依赖：

```sh
git clone https://github.com/julescore/dsh-with-plugin-market.git
cd dsh-with-plugin-market
corepack enable
pnpm install --frozen-lockfile
```

在装有 Xcode Command Line Tools 的 macOS 15+ 上：

```sh
pnpm run build:macos
pnpm run verify:macos
```

在装有 .NET 8 SDK 和 Inno Setup 6 的 Windows 10/11 x64 上：

```powershell
pnpm run build:windows
pnpm run verify:windows
```

详细说明见[桌面共享版本参考](apps/desktop/README.md)、[macOS 打包参考](apps/macos/README.md)和 [Windows 打包参考](apps/windows/README.md)。

## GitHub Actions

[Desktop Build](.github/workflows/desktop-build.yml) 会在 GitHub 原生 runner 上构建并验证 macOS arm64 与 Windows x64 产物。手动运行会上传两个 Actions 产物；创建 `desktop-vX.Y.Z` 或 `desktop-vX.Y.Z-rc.N` 标签时，只有两个平台都成功才会创建 GitHub Release。

[Sync Upstream](.github/workflows/sync-upstream.yml) 每周检查官方 `deepseek-ai/deepseek-harness` 的 `master` 分支，并在本仓库创建或更新同步 PR。官方更新必须先经过审查和构建验证，不会直接写入发行分支。

## 上游与开发

DeepSeek Harness 由 [Cordis](https://github.com/cordiverse/cordis) 驱动，采用**一切皆插件**的架构。本发行版特意保持上游包名和产品标识不变，减少同步官方源码时的冲突。

上游架构与开发资料见 [docs/architecture.md](docs/architecture.md)、[docs/development.md](docs/development.md) 和 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

采用 [MIT](LICENSE) 许可证。各平台运行时旁均包含发行专用的第三方依赖声明。
