# 桌面发行共享资源

[English](README.md) | 中文

本目录维护原生 macOS 与 Windows 发行版共用的版本清单和插件市场策略。各平台外壳与安装器仍分别位于 `apps/macos/` 和 `apps/windows/`。

生成发行版前只提升一次共享应用版本：

```sh
node --import tsx/esm apps/desktop/scripts/version.ts bump
```

两个平台的产物必须都使用 `apps/desktop/version.json` 中的同一个版本号。
