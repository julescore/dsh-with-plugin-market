# 桌面发行共享资源

[English](README.md) | 中文

本目录维护原生 macOS 与 Windows 发行版共用的版本清单、插件市场策略、内置图片识别插件层和经过校验和锁定的社区 Agent preset。各平台外壳与安装器仍分别位于 `apps/macos/` 和 `apps/windows/`。

`resources/agent-presets/` 保存从 `xiaobright/dsh-anchored-standard` 复制的两个实验 preset；`resources/anchored-standard-source.json` 固定上游提交和每个源文件的校验和。两个平台构建器都会运行 `scripts/install-agent-presets.py`，在校验和漂移或 preset id 冲突时拒绝打包，然后执行无密钥行为验证。新建会话时可以选择这些 preset，但它们不会取代上游的 `standard` 默认值。

生成发行版前只提升一次共享应用版本：

```sh
node --import tsx/esm apps/desktop/scripts/version.ts bump
```

两个平台的产物必须都使用 `apps/desktop/version.json` 中的同一个版本号。

内置市场会把每次安装和更新作为一次 profile 事务处理：先保存 `package.json`、`pnpm-lock.yaml` 和 `pnpm-workspace.yaml`，再通过 `dsh --profile web --dump-config` 组合完整 Web profile；如果新插件树无效，就恢复这些文件并按旧 lockfile 离线恢复依赖。因此，包括 loader entry id 重复在内的不兼容插件不会破坏下次启动。

如果旧版应用已经留下无效 Web profile，两个桌面外壳都会在启动错误页提供“备份并重置 Web profile”。恢复操作只把 `$DSH_HOME/profiles/web` 移到 `$DSH_HOME/profile-backups/`；会话、设置、凭据、个人 Agent preset 和其他 profile 都保留原位。

在整体重置之前，共享诊断脚本会把结构化启动诊断（Cordis 加载/激活失败条目、无法解析的模块、`node_modules`/`.pnpm` 路径）与 Web profile 的 `package.json` 依赖做匹配。当启动失败能定位到一个或多个已安装插件时，桌面外壳会列出插件名，并提供“卸载并自动重启”的一键入口。
