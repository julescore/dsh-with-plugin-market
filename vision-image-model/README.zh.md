# vision-image-model

[English](README.md) | 中文

这是一个独立的 DeepSeek Harness 插件。它提供 Web 设置卡片，用于从已配置模型中选择一个明确支持图片输入的模型；它还注册全局 `vision_read_image` 工具，并严格调用所选 `{ provider, model }`，不会故障转移到其他模型。

## 图片访问与证据

工具只接受本地路径。路径从当前会话工作区解析，字节通过 `ctx.fs` 读取，因此会遵守文件系统策略、取消信号和大小限制，并发出 `fs/observed`。远程图片必须先通过经过批准的网络工具下载；本插件明确不支持直接抓取 URL。

插件通过文件头识别 PNG、JPEG、GIF 或 WebP。编码后的图片必须同时符合插件和附件存储所适用的最小大小上限。成功结果会把附件 id、解析后路径、媒体类型、字节数、所选 provider/model 和提示词写入模型可见且持久的工具结果。附件持久化后发生的失败也会在错误中保留同样的引用字段。

## 模型选择与凭据

`GET /vision-image-model/config` 会列举已配置 provider 及其模型目录。只有明确声明支持图片输入的模型可供选择。选择保存在 `vision-image-model` 设置命名空间中并即时生效。凭据仍由所选 provider 管理，本插件不会保存凭据。

选择为空、设置接口不可用、模型请求被拒绝或模型返回无效 JSON 时，工具会报错。即使当前目录不再列出手工写入的设置值，运行时仍会尝试调用它。

## 桌面发行版

macOS 与 Windows 构建器会把本目录复制到应用运行时，固定别名为 `dsh-vision-image-model-bundled`，把该别名加入运行时依赖闭包，并始终挂载 [`apps/desktop/resources/vision.patch.yml`](../apps/desktop/resources/vision.patch.yml)。应用名称仍为 **DeepSeek Harness**。

使用 Node 24 运行聚焦测试：

```sh
node --test vision-image-model/test/*.test.mjs
```

开发 profile 可以安装源码副本，然后重新启动：

```sh
pnpm dsh plugin --profile web add file:./vision-image-model
pnpm dsh --profile web
```

## 配置

```yaml
- update:
    id: vision-image-model
    config:
      provider: dashscope
      model: qwen3-vl-plus
      toolName: vision_read_image
      timeoutMs: 180000
      settingsCard: true
      tool: true
```

`settingsCard: false` 会省略 Web 接口和设置卡片；`tool: false` 会省略工具。默认超时时间为 180 秒。
