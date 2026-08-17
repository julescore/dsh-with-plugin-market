# Agent Note: 内置视觉图片模型

Status: implemented

[English](2026-08-17-bundled-vision-image-model.md) | 中文

## Problem

桌面仓库中已有图片模型插件，但两个平台都没有将其打包或加载。初版还会直接读取宿主路径并抓取任意 URL，绕过 Harness 文件系统策略，而且 SSRF 防护并不完整。模型选择与图片来源也没有持久化到会话记录中。

## Decision

macOS 与 Windows 发行版会把仓库自带插件复制到封闭运行时，并使用固定别名 `dsh-vision-image-model-bundled`。安装脚本会同时把别名应用到包清单与预打包浏览器客户端模块的 handoff，再写入运行时依赖清单，使 profile 的模块 fallback 修复可以向 Loader 暴露一致的身份。两个原生外壳始终单独应用 `vision.patch.yml`；插件市场冲突选择不会启用、禁用或替换图片识别能力。

插件只接受本地路径。它通过 `ctx.fs` 按会话工作区解析路径，要求目标是普通文件，执行有大小上限的字节读取，并发出 `fs/observed`。远程图片必须先通过经过批准的网络工具下载。图片字节先持久化到附件存储，再调用用户精确选择的 provider/model，不做故障转移。

设置卡片允许选择已激活 provider 目录中的所有模型。图片输入元数据仅作为警告，因为适配器目录可能遗漏模型能力或更新滞后。保存时会拒绝未激活的 provider 或当前目录中不存在的模型；如果最终图片请求失败，插件仍以用户所选 provider 为准。

浏览器上传的 prompt 图片也由同一个已选图片模型处理，并且与对话模型相互独立。宿主先持久化并验证原图，再调用 `session/prompt-images/available` 返回的准备完毕的转换器；转换器会固定一次所选路由，并在用户消息进入模型历史前把每个图片块替换为结构化文本识别结果。原始有序 prompt 保存在 `MessageSource.displayContent` 中，用于用户气泡、附件授权和会话导出。这样当前及重放后的对话模型历史都只包含文本，同时识别结果仍作为同一条用户消息中的模型可见持久内容。插件未配置时会委托给原生多模态准入，包括对话模型原有的能力前置检查。

渲染后的工具结果包含附件 id、解析后路径、媒体类型、字节数、选定 provider/model 与提示词。附件持久化后的错误也包含同样证据，因此重放不依赖会话日志不会保留的成功 canonical value。

安装包验证器要求复制后的包和 patch 存在，真实执行浏览器客户端并验证准确的 Loader handoff，组合对应配置行，启动 Host，读取设置接口并检查 Web 启动图。聚焦测试覆盖有界文件读取与桌面安装器；ToolRuntime smoke 证明全局工具对 Agent scope 可见。

## Alternatives considered

**由工具直接抓取 HTTP 与 HTTPS URL。** 不采用：DNS 预检查后再单独 fetch 无法固定解析地址，不能阻止 DNS rebinding SSRF。产品已有带批准能力的网络工具。

**把插件安装进每个可变用户 profile。** 不采用：应用升级会修改用户状态、与本地版本冲突，并让功能受插件市场冲突选择影响。

**在每个 Agent preset 中分别添加工具。** 不采用：ToolRuntime 的全局注册会由 Agent scope 继承。重复配置会增加 preset 漂移并产生同名冲突。

## Consequences

新的 macOS 与 Windows 桌面安装包都会包含同一套可选模型图片识别能力，同时应用名保持 DeepSeek Harness。用户可以在适配器元数据更新之前选择实际已支持图片的新模型。配置图片模型后，上传图片可以配合独立的纯文本对话模型使用；识别失败会拒绝该 prompt，不会悄悄把原图发送给该对话模型。未选择图片模型时，原生多模态准入及其能力错误仍然有效。远程工具输入必须先下载。仅支持本地路径会减少直接 URL 的便利性，但让网络授权留在本插件之外，并使文件观察和持久证据符合 Harness 策略。
