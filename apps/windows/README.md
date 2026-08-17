# Windows desktop distribution

English | [中文](README.zh.md)

This directory packages the existing DeepSeek Harness Web application as a native Windows 10/11 x64 desktop application named **DeepSeek Harness**. The repository remains `dsh-with-plugin-market`; the repository name is not the application brand.

The application uses a .NET 8 WinForms shell with Microsoft Edge WebView2, bundles Node.js 24.19.0, pnpm 11.7.0, the production Harness runtime, `dshmarket@1.2.3`, the repository-owned `vision-image-model` plugin, and the checksum-pinned **Anchored Standard (experimental)** and **Zero-Anchored Standard (experimental)** community presets, and generates an Inno Setup installer. The vision plugin provides a settings card and the local-path-only `vision_read_image` tool. The presets are selectable for new sessions but Standard remains the default. Windows normally includes WebView2 Runtime; when it is absent the application presents an explicit installation requirement.

A notification-area (system tray) icon is installed at launch. Closing the window only hides it; the Harness process keeps running, and clicking the tray icon reopens the window. Exiting through the tray menu stops the background process.

Market installs and updates are accepted only after the complete Web profile composes successfully; otherwise the previous manifest, lockfile, build policy, and installed resolution are restored. A startup failure page can move only the invalid Web profile into `$DSH_HOME/profile-backups/` and restart, while preserving sessions, settings, credentials, personal presets, and other profiles. When the startup diagnostic names specific installed plugins, the page lists them and offers one-click uninstall and restart before the full-profile reset fallback.

Build and verify on Windows:

```powershell
pnpm run build:windows
pnpm run verify:windows
```

The artifact is written to:

```text
.artifacts/windows/DeepSeek-Harness-<version>-windows-x64-setup.exe
```

`verify:windows` silently installs into an isolated directory, runs the shell self-test, checks embedded Node, pnpm, packaged recovery behavior, and the bundled vision package/configuration/settings client/tool declaration, verifies both community preset behaviors, starts the bundled Harness, proves both presets are discoverable and mountable through the Host API, reads the market registry, installs and removes the curated `dsh-web-ui` aggregate, and checks both plugin-market conflict compositions.
