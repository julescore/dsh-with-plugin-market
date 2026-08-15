# macOS 应用

[English](README.md) | 中文

本目录维护原生 macOS arm64 发行版。安装后的应用和磁盘映像都叫 **DeepSeek Harness**；`dsh-with-plugin-market` 只是 Git 仓库名。

## 运行时与插件市场

`src/main.swift` 创建包含 `WKWebView` 的 AppKit 窗口，在随机回环端口启动内置 Node.js 24.19.0 与 Harness 生产运行时，并将内嵌导航限制在该来源；其他 HTTP 和 HTTPS 链接由默认浏览器打开。子进程使用用户主目录、标准 `~/.dsh` 状态和内置 pnpm 11.7.0，应用不会复制凭据。

应用挂载共享的 `apps/desktop/resources/market.patch.yml`，预载 `dshmarket@1.2.3`。如果 `dsh web --dump-config` 检测到已有 `dsh-market` 条目，用户可选择本次启动使用本地市场或安装包市场。安装包选项只在本次进程组合中禁用本地条目，不会修改插件、会话、凭据或 profile 文件。

共享发行策略会把 `dsh-web-ui` 仓库及目录地址映射到 `@linxin666/dsh-web-ui-all`，只为市场自身更新跳过发布等待期，并在用户没有既有选择时明确拒绝 `cloudflared`、`cpu-features` 和 `ssh2` 构建脚本；同时把经过校验和锁定的 **Anchored Standard (experimental)** 与 **Zero-Anchored Standard (experimental)** 社区 preset 安装成非默认系统 preset。社区插件和 preset 仍是需要用户自行信任的第三方代码。

## 构建与验证

要求：macOS 15+、Apple Silicon、Xcode Command Line Tools、Node.js `^22.19 || >=24`、Corepack，以及首次构建时可访问网络。

```sh
pnpm install --frozen-lockfile
pnpm run build:macos
pnpm run verify:macos
```

构建会内置运行时、锁定版本的 Node 与 pnpm、修补后的市场、AppKit 可执行文件、图标和声明；检查所有 arm64 Mach-O 的最低系统版本，应用 ad-hoc 签名并生成：

```text
.artifacts/macos/DeepSeek Harness.app
.artifacts/macos/DeepSeek-Harness-<version>-macos-arm64.dmg
```

`verify:macos` 会把 DMG 挂载到干净位置，检查应用标识、签名、运行时闭包、两个社区 preset 的行为、通过 Host API 发现 preset 并完成组合、插件市场目录、`dsh-web-ui` 安装/重启/卸载、两种冲突选择，以及从 `dshmarket@1.1.0` 首次点击更新到 `1.2.3` 的真实路径。

## 共享版本与发行

[`../desktop/version.json`](../desktop/version.json) 是 macOS 与 Windows 唯一共用的桌面版本和构建号来源。使用上述命令可重建当前版本。要提升共享版本并以事务方式打包 macOS：

```sh
pnpm run package:macos
pnpm run package:macos -- --bump release
pnpm run package:macos -- --version 1.2.0-rc.1
```

默认提升 `rc.N`。构建失败时会恢复此前共享版本，并删除本次未完成产物。发布改动必须和更新后的共享清单一起提交。

## 分发限制

当前 DMG 使用 ad-hoc 签名，尚未经过 Apple 公证。若要公开分发且不触发 Gatekeeper 警告，还需要 Developer ID 签名、公证与装订；签名凭据有意不放入本仓库。
