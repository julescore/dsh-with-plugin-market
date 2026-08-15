# Agent Note：跨平台桌面发行标识

Status: implemented

[English](2026-08-15-cross-platform-desktop-distribution.md) | 中文

## 问题

首个社区桌面安装包把仓库发行标签用作 macOS 应用名，而且只实现了 AppKit 外壳。仓库命名不应取代上游产品标识；作为桌面发行版，还需要提供具备等价运行时与插件市场行为的原生 Windows 安装路径。

## 决策

**仓库标识和产品标识相互独立。** 仓库继续叫 `dsh-with-plugin-market`，安装后的应用、窗口、快捷方式、磁盘映像、安装器和 Release 标题统一使用 **DeepSeek Harness**。平台 bundle identifier 可以保留仓库所有者信息，因为它标识发行方，而不是用户可见的产品品牌。

**各平台保留原生外壳并共享已组装产品。** macOS 继续使用 AppKit 与 `WKWebView`；Windows 使用 .NET 8 WinForms 外壳和系统 Microsoft Edge WebView2 Runtime。两个外壳都不重写 Harness 服务或 Web 客户端，而是在随机回环端口启动同一套内置生产运行时，把内嵌导航限制在该来源，并将外部链接交给系统浏览器。

**两个平台共用一套发行策略与版本。** `apps/desktop` 负责发布清单、插件市场 patch、精选来源映射和市场修补器。macOS 与 Windows 打包相同的固定版本 Node.js、pnpm、`dshmarket`、Harness 运行时、冲突选择和 `dsh-web-ui` 安装策略。只有两个产物报告同一共享版本时，发行标签才有效。

**Windows 提供自包含原生外壳和常规安装器。** x64 构建将 .NET 运行时随 WinForms 外壳一起发布，内置 Node 与 Harness，并使用 Inno Setup 创建支持当前用户安装的安装程序。WebView2 Runtime 保持为系统前置条件，因为受支持 Windows 通常已提供；缺失时应用会直接显示错误。

**发行必须在两个原生操作系统上完成验证。** macOS 验证挂载 DMG 并实测运行时和市场。Windows 验证会静默安装到隔离目录，执行外壳资源与品牌检查，启动安装后的运行时，调用市场目录，安装和卸载精选合集，并检查两种冲突组合。Release job 同时依赖两个平台，不能发布缺少一个平台的产物集合。

## 曾考虑的替代方案

**只修改 macOS bundle 名称。** 不采用：Release 文件、窗口标题、快捷方式、文档和未来平台仍会在仓库标识与产品标识之间漂移。

**在 Windows 使用 macOS Swift 外壳。** 不采用：AppKit 与 `WKWebView` 仅支持 macOS。原生 Windows 外壳无需增加完整 Chromium 运行时，也能保留生命周期和界面归属。

**两个平台都改用 Electron。** 本次不采用：这会替换已经验证的原生 macOS 外壳，并增加另一套浏览器运行时。使用系统原生 Web view 可以缩小发行范围，并继续让产品行为归属既有 Web 客户端。

**未在 Windows 运行就发布 Windows 版。** 不采用：在 macOS 上交叉编译或检查源码无法证明安装器行为、进程树关闭、路径转义、WebView2 加载和 Windows 插件安装。

## 后果

无论从哪里下载社区构建，用户看到的都是上游 DeepSeek Harness 产品名。GitHub Release 可以基于同一版本源提供 macOS arm64 与 Windows x64 安装包。Windows 用户无需单独安装 Node.js、pnpm 或 .NET，但需要 WebView2 Runtime。两个原生外壳需要分别维护，而共享发行资源会防止插件市场和版本行为发生分歧。
