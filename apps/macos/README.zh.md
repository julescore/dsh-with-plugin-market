# macOS 应用

[English](README.md) | 中文

本目录负责 DSH with Plugin Market 的原生 macOS 分发；它是 DeepSeek Harness 的社区发行版。它用轻量的 AppKit 外壳承载既有 Web 应用，不引入独立的桌面产品运行时。

## 运行时

`src/main.swift` 创建包含 `WKWebView` 的 AppKit 窗口。启动时，它先通过内置 Node.js 24.19.0 检查 Web profile 的最终组合，再执行内置的 Harness 生产运行时。没有市场的 profile 会加载 `macos/market.patch.yml`；已经包含 `dsh-market` 行的 profile 会进入下文所述的市场来源选择。

Host 选择可用的回环端口，并报告 `http://127.0.0.1:<port>` 就绪 URL。外壳只在内嵌视图中加载该来源、`about:` URL 和 `blob:` URL。其他 HTTP 与 HTTPS 导航会在默认浏览器中打开。

子进程以用户主目录作为工作目录，因此正常启动应用时会使用常规的 `~/.dsh` 设置、会话和凭据引用。应用包不会复制凭据。退出应用时，外壳先向子进程发送 `SIGTERM`；如果六秒后仍未退出，则发送 `SIGKILL`。

## 内置插件市场

macOS 分发通过应用自有的 `--patch` 层预装 [`dshmarket@1.2.3`](https://github.com/dsh-market/dsh-market)。该配置只影响桌面应用；普通 CLI 和 Web 启动继续使用原有 profile 组合。市场位于“设置 → 插件市场”，读取精选目录并带有离线快照。被目录收录不代表获得安全背书：安装插件会在用户电脑上加载第三方代码，用户必须自行检查并信任其来源。

添加该层前，外壳会执行 `dsh web --dump-config`，并检查最终组合的顶层行中是否存在 `dsh-market`。本地已有市场时，提示框提供“使用本地插件市场”“使用安装包内置市场”和“退出”。选择本地时不加载桌面市场补丁；选择安装包时，只在本次进程组合中禁用本地行，并通过分发专用别名 `dshmarket-bundled` 插入内置包。每次发生冲突都会重新询问；选择不会更改 profile manifest、补丁文件、已安装插件、会话或凭据。

插件管理使用内置的 `pnpm@11.7.0`，双击启动不依赖用户 shell 中的包管理器。对于 `dsh-web-ui` 合集仓库，分发版会将仓库根 URL 和当前目录中的 `packages/dsh-web-ui-all` URL 都精确映射到作者发布的预构建 npm 全家桶 `@linxin666/dsh-web-ui-all`，而不会安装 monorepo 根包。只有更新 `dshmarket` 自身时，安装包内置市场才会跳过通常的一天发布等待，使旧市场第一次点击更新即可完成修复；普通插件仍保留等待，除非用户明确选择上游提供的“立即更新”。安装这一个全家桶前，市场会把 `cloudflared`、`cpu-features` 和 `ssh2` 的构建脚本选择明确记录为 `false`，但保留用户已经作出的选择；因此不会自动下载 Cloudflared 二进制或编译原生扩展，同时仍可使用这些包不依赖安装脚本的路径。其他目录条目与既有构建权限不受影响。市场和包管理器的 npm tarball 都固定版本，并且只有 SHA-256 摘要匹配才会被接受。市场与 pnpm 的许可证声明记录在 `Contents/Resources/THIRD-PARTY-NOTICES.md`。

## 构建要求

构建要求 macOS 15.0 或更高版本、Xcode Command Line Tools、Node.js `^22.19 || >=24`、通过 Corepack 使用的 pnpm，以及首次构建时可访问固定版本 Node.js、pnpm 与 dshmarket 压缩包的网络。产物仅支持 Apple Silicon。

更新代码后先安装工作区依赖：

```sh
pnpm install --frozen-lockfile
```

## 版本归属

[`version.json`](version.json) 是 macOS 发布版本与 Apple 构建号的唯一来源，且有意独立于根工作区包版本。

```json
{
  "version": "0.1.0-rc.8",
  "build": 8
}
```

`version` 接受 `X.Y.Z` 与 `X.Y.Z-rc.N`，用于命名 DMG 并记录分发版本。由于 Apple 应用营销版本不接受候选版本后缀，`CFBundleShortVersionString` 使用稳定的 `X.Y.Z` 部分。`CFBundleVersion` 使用 `build`；它是正整数，每次成功切换版本时递增。例如，发布版本 `0.1.0-rc.8` 对应应用版本 `0.1.0` 和构建号 `8`。

发布版本时不要编辑 `Info.plist`。每次构建都会用 `version.json` 替换其中的占位值。

## 本地重建

调试当前代码但不消耗新版本号时运行：

```sh
pnpm run build:macos
pnpm run verify:macos
```

`build:macos` 会构建 Harness 工作区，组装生产依赖闭包，内置固定版本的市场与包管理器，编译 Swift 外壳与图标，确认应用包不存在损坏的符号链接，并确认每个 arm64 Mach-O 都支持声明的最低 macOS 15.0，应用 ad-hoc 签名，然后创建当前版本的 DMG。`verify:macos` 会以只读方式挂载该 DMG，并检查版本与签名；随后通过隔离的全新与冲突 `DSH_HOME` 固件，证明全新、本地市场和安装包市场三条路径都只激活一个市场客户端、保持冲突 profile manifest 不变、只监听回环地址并正常退出。在 `PATH` 仅包含内置 pnpm 时，全新路径会通过市场安装 `dsh-web-ui`，检查 npm 全家桶与三项明确的构建脚本拒绝策略，重启后验证七个客户端实际加载，再卸载全家桶。这些固件避免验证过程读取或修改用户的设置、会话和凭据。

## 正式打包

代码更新并通过相关测试后，使用以下命令生成下一个候选版本：

```sh
pnpm run package:macos
```

默认切换会提升 `rc.N`，再构建并验证新产物。命令成功后保留新的 `version.json`；如果构建或验证失败，则逐字节恢复旧文件，并删除本次尝试产生的不完整产物。此前成功生成的其他版本 DMG 会保留。

默认规则不适用时，可明确指定版本切换方式：

```sh
pnpm run package:macos -- --bump rc
pnpm run package:macos -- --bump release
pnpm run package:macos -- --bump patch
pnpm run package:macos -- --bump minor
pnpm run package:macos -- --bump major
pnpm run package:macos -- --version 1.2.0-rc.1
pnpm run package:macos -- --version 1.2.0
```

默认 `rc` 切换会把 `0.1.0-rc.8` 提升为 `0.1.0-rc.9`。当前版本为稳定版时，它会进入下一个补丁版本，例如从 `0.1.0` 变为 `0.1.1-rc.1`。`release` 会移除 RC 后缀，`patch`、`minor` 和 `major` 会生成下一个稳定语义化版本。明确指定的版本必须高于当前发布版本。每次成功切换都会让 `build` 恰好加一。

产物路径为：

```text
.artifacts/macos/DSH with Plugin Market.app
.artifacts/macos/DSH-with-Plugin-Market-<version>-macos-arm64.dmg
```

打包命令会输出最终版本、路径和 SHA-256 摘要。交付前应保留这些输出；也可挂载 DMG 并启动应用进行视觉冒烟测试，再在 Finder 或 `Info.plist` 中确认版本。应将更新后的 `version.json` 与本次发布源码改动一同提交；除非另有二进制分发规则，否则不要把 `.artifacts/` 提交到 Git。

## 分发限制

当前产物使用适合本地安装的 ad-hoc 签名，没有 Developer ID 签名，也未经过公证，因此 Gatekeeper 可能拒绝或警告从网络下载的副本。公开分发还需要 Developer ID Application 签名、按需使用 Developer ID Installer 或签名 DMG、Apple 公证以及装订验证；这些凭据有意不纳入仓库构建流程。
