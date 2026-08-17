# Agent Note：跨平台桌面发行标识

Status: implemented

[English](2026-08-15-cross-platform-desktop-distribution.md) | 中文

## 问题

首个社区桌面安装包把仓库发行标签用作 macOS 应用名，而且只实现了 AppKit 外壳。仓库命名不应取代上游产品标识；作为桌面发行版，还需要提供具备等价运行时与插件市场行为的原生 Windows 安装路径。

## 决策

**仓库标识和产品标识相互独立。** 仓库继续叫 `dsh-with-plugin-market`，安装后的应用、窗口、快捷方式、磁盘映像、安装器和 Release 标题统一使用 **DeepSeek Harness**。平台 bundle identifier 可以保留仓库所有者信息，因为它标识发行方，而不是用户可见的产品品牌。

**各平台保留原生外壳并共享已组装产品。** macOS 继续使用 AppKit 与 `WKWebView`；Windows 使用 .NET 8 WinForms 外壳和系统 Microsoft Edge WebView2 Runtime。两个外壳都不重写 Harness 服务或 Web 客户端，而是在随机回环端口启动同一套内置生产运行时，把内嵌导航限制在该来源，并将外部链接交给系统浏览器。

**两个平台共用一套发行策略与版本。** `apps/desktop` 负责发布清单、插件市场 patch、精选来源映射、市场修补器和经过校验和锁定的社区 preset 源文件。macOS 与 Windows 打包相同的固定版本 Node.js、pnpm、`dshmarket`、Harness 运行时、冲突选择、`dsh-web-ui` 安装策略，以及来自 `xiaobright/dsh-anchored-standard` 的两个 preset。社区 preset 保留实验名称，作为可选系统 preset 出现，并继续以 `standard` 为默认模式。只有两个产物报告同一共享版本时，发行标签才有效。

**Windows 提供自包含原生外壳和常规安装器。** x64 构建将 .NET 运行时随 WinForms 外壳一起发布，内置 Node 与 Harness，并使用 Inno Setup 创建支持当前用户安装的安装程序。WebView2 Runtime 保持为系统前置条件，因为受支持 Windows 通常已提供；缺失时应用会直接显示错误。

**插件变更不能留下无法启动的 Web profile。** 内置市场会在安装和更新前保存依赖清单、lockfile 与 pnpm 构建策略，再调用安装包内的 CLI 组合完整 profile。无效插件树会触发文件恢复、按旧 lockfile 离线恢复依赖，并再次验证恢复后的组合。这个过程能发现只做依赖安装无法识别的冲突，例如两个 bundle 同时贡献 `agent-presets`。对于事务外产生的无效状态，启动恢复只把 Web profile 移到时间戳备份；持久会话、设置、凭据、个人 preset 和其他 profile 都保持原位且不受修改。

**发行必须在两个原生操作系统上完成验证。** 两个平台的构建器都会拒绝社区 preset 校验和不匹配或 id 冲突，使用隔离用户数据实测安装包内的 Web profile 恢复工具，并无密钥验证各 preset 的启动与晋升行为。macOS 验证挂载 DMG 并实测运行时和市场；Windows 验证会静默安装到隔离目录，执行外壳资源与品牌检查。两个安装后运行时验证器都会通过 Host API 列出 preset，并分别用两个 preset 创建空白会话，以证明完整 Cordis 组合可以挂载。市场验证仍会安装和卸载精选合集，并检查两种冲突选择。Release job 同时依赖两个平台，不能发布缺少一个平台的产物集合。

## 曾考虑的替代方案

**只修改 macOS bundle 名称。** 不采用：Release 文件、窗口标题、快捷方式、文档和未来平台仍会在仓库标识与产品标识之间漂移。

**在 Windows 使用 macOS Swift 外壳。** 不采用：AppKit 与 `WKWebView` 仅支持 macOS。原生 Windows 外壳无需增加完整 Chromium 运行时，也能保留生命周期和界面归属。

**两个平台都改用 Electron。** 本次不采用：这会替换已经验证的原生 macOS 外壳，并增加另一套浏览器运行时。使用系统原生 Web view 可以缩小发行范围，并继续让产品行为归属既有 Web 客户端。

**未在 Windows 运行就发布 Windows 版。** 不采用：在 macOS 上交叉编译或检查源码无法证明安装器行为、进程树关闭、路径转义、WebView2 加载和 Windows 插件安装。

**把社区 preset 安装到每位用户的可写 preset 目录。** 不采用：应用更新会因此修改用户状态、与本地自有 preset id 冲突，而且会遗留旧副本。把它们放在只读系统 preset 根目录，可以让来源和替换跟随应用版本。

**把实验性社区 preset 设为默认。** 不采用：其上游证据只针对特定模型和工作负载。内置只代表让用户可以选择，不把局部评测结果当作普遍提升。

## 后果

无论从哪里下载社区构建，用户看到的都是上游 DeepSeek Harness 产品名。GitHub Release 可以基于同一版本源提供 macOS arm64 与 Windows x64 安装包。两个实验性社区 preset 可直接用于新会话，不会改变 Standard 默认值，也不会写入用户 preset 目录。更新其固定提交是一项需要显式源码审查的工作，因为每个 preset 都保存了上游 Standard 组合的快照。Windows 用户无需单独安装 Node.js、pnpm 或 .NET，但需要 WebView2 Runtime。两个原生外壳需要分别维护，而共享发行资源会防止插件市场、preset 和版本行为发生分歧。
