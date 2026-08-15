# Windows 桌面发行版

[English](README.md) | 中文

本目录将既有 DeepSeek Harness Web 应用打包成名为 **DeepSeek Harness** 的原生 Windows 10/11 x64 桌面应用。Git 仓库继续叫 `dsh-with-plugin-market`；仓库名不是应用品牌。

应用使用 .NET 8 WinForms 与 Microsoft Edge WebView2 外壳，内置 Node.js 24.19.0、pnpm 11.7.0、Harness 生产运行时、`dshmarket@1.2.3`，以及经过校验和锁定的 **Anchored Standard (experimental)** 与 **Zero-Anchored Standard (experimental)** 社区 preset，并生成 Inno Setup 安装程序。新建会话时可以选择这些 preset，但 Standard 仍是默认模式。Windows 通常已内置 WebView2 Runtime；如果缺失，应用会明确提示安装要求。

在 Windows 上构建和验证：

```powershell
pnpm run build:windows
pnpm run verify:windows
```

产物路径：

```text
.artifacts/windows/DeepSeek-Harness-<version>-windows-x64-setup.exe
```

`verify:windows` 会静默安装到隔离目录，运行外壳自检，检查内置 Node 和 pnpm，验证两个社区 preset 的行为，启动 Harness，通过 Host API 证明两个 preset 可发现且可挂载，读取市场目录、安装和卸载精选 `dsh-web-ui` 合集，并检查插件市场冲突的两种组合。
