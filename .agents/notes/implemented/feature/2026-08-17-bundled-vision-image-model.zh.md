# Agent Note: 内置视觉图片模型

Status: implemented

[English](2026-08-17-bundled-vision-image-model.md) | 中文

## Problem

桌面仓库中已有图片模型插件，但两个平台都没有将其打包或加载。初版还会直接读取宿主路径并抓取任意 URL，绕过 Harness 文件系统策略，而且 SSRF 防护并不完整。模型选择与图片来源也没有持久化到会话记录中。

## Decision

macOS 与 Windows 发行版会把仓库自带插件复制到封闭运行时，并使用固定别名 `dsh-vision-image-model-bundled`。安装脚本把该别名写入运行时依赖清单，使 profile 的模块 fallback 修复可以向 Loader 暴露它。两个原生外壳始终单独应用 `vision.patch.yml`；插件市场冲突选择不会启用、禁用或替换图片识别能力。

插件只接受本地路径。它通过 `ctx.fs` 按会话工作区解析路径，要求目标是普通文件，执行有大小上限的字节读取，并发出 `fs/observed`。远程图片必须先通过经过批准的网络工具下载。图片字节先持久化到附件存储，再调用用户精确选择的 provider/model，不做故障转移。

渲染后的工具结果包含附件 id、解析后路径、媒体类型、字节数、选定 provider/model 与提示词。附件持久化后的错误也包含同样证据，因此重放不依赖会话日志不会保留的成功 canonical value。

安装包验证器要求复制后的包和 patch 存在，组合对应配置行，启动 Host，读取设置接口并检查 Web 启动图。聚焦测试覆盖有界文件读取与桌面安装器；ToolRuntime smoke 证明全局工具对 Agent scope 可见。

## Alternatives considered

**由工具直接抓取 HTTP 与 HTTPS URL。** 不采用：DNS 预检查后再单独 fetch 无法固定解析地址，不能阻止 DNS rebinding SSRF。产品已有带批准能力的网络工具。

**把插件安装进每个可变用户 profile。** 不采用：应用升级会修改用户状态、与本地版本冲突，并让功能受插件市场冲突选择影响。

**在每个 Agent preset 中分别添加工具。** 不采用：ToolRuntime 的全局注册会由 Agent scope 继承。重复配置会增加 preset 漂移并产生同名冲突。

## Consequences

新的 macOS 与 Windows 桌面安装包都会包含同一套可选模型图片识别能力，同时应用名保持 DeepSeek Harness。用户必须配置支持图片的模型，并在使用远程输入前先下载。仅支持本地路径会减少直接 URL 的便利性，但让网络授权留在本插件之外，并使文件观察和持久证据符合 Harness 策略。
