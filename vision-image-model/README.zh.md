# vision-image-model

[English](README.md) | 中文

这是一个独立的 DeepSeek Harness 插件，用于选择与对话模型相互独立的图片识别模型。它会预处理浏览器上传的图片，并提供全局 `vision_read_image` 工具；两条路径都严格调用已配置的 `{ provider, model }`，不会故障转移。

## 上传到对话的图片

当 provider 和 model 都已配置时，插件会在对话模型运行前处理 `session.prompt` 中的每张图片。原图仍可显示和导出，而模型历史只接收用户文本与持久的文本识别结果，其中包含摘要、OCR、布局、不确定项和图片模型路由。因此纯文本对话模型也可以回答带图片的用户 prompt，而无需直接接收图片块。

识别失败会拒绝该 prompt。图片模型选择为空时，会保留原生多模态行为，包括对话模型的能力检查。对话模型选择器与本插件设置始终相互独立。

## 图片访问与证据

工具只接受本地路径。路径从当前会话工作区解析，字节通过 `ctx.fs` 读取，因此会遵守文件系统策略、取消信号和大小限制，并发出 `fs/observed`。远程图片必须先通过经过批准的网络工具下载；本插件明确不支持直接抓取 URL。

插件通过文件头识别 PNG、JPEG、GIF 或 WebP。编码后的图片必须同时符合插件和附件存储所适用的最小大小上限。成功结果会把附件 id、解析后路径、媒体类型、字节数、所选 provider/model 和提示词写入模型可见且持久的工具结果。附件持久化后发生的失败也会在错误中保留同样的引用字段。

## 模型选择与凭据

`GET /vision-image-model/config` 会列举已配置 provider 及其模型目录。已激活 provider 目录中的所有模型都可以选择。声明为仅文本或能力未知的模型会显示警告但不会被禁用，因为适配器目录可能尚未标记实际已支持图片的模型。选择保存在 `vision-image-model` 设置命名空间中并即时生效。凭据仍由所选 provider 管理，本插件不会保存凭据。

保存新选择时，provider 必须处于激活状态，且模型必须存在于当前目录中。选择为空、调用路由不可用、图片请求被拒绝或模型返回无效 JSON 时，工具会报错。即使当前目录不再列出手工写入的设置值，运行时仍会尝试调用它。如果所选模型实际上不能接收图片，请求会在所选 provider 处失败；插件不会改用其他模型。

## 桌面发行版

macOS 与 Windows 构建器会把本目录复制到应用运行时，固定别名为 `dsh-vision-image-model-bundled`，同时把包清单和预打包浏览器客户端 handoff 改成该别名，再将它加入运行时依赖闭包，并始终挂载 [`apps/desktop/resources/vision.patch.yml`](../apps/desktop/resources/vision.patch.yml)。应用名称仍为 **DeepSeek Harness**。

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
