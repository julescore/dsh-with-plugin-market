# vision-image-model

English | [中文](README.zh.md)

A standalone DeepSeek Harness plugin that adds a Web settings card for selecting one configured image-capable model and a global `vision_read_image` tool that calls exactly that `{ provider, model }`. Calls never fail over to another model.

## Image access and evidence

The tool accepts local paths only. Paths resolve from the current session workspace and bytes are read through `ctx.fs`, so filesystem policy, cancellation, size limits, and `fs/observed` apply. Download a remote image with an approved network tool before calling this tool; URL fetching is deliberately unsupported.

Accepted bytes are PNG, JPEG, GIF, or WebP, detected from their headers. The encoded image must fit the smallest applicable plugin and attachment-store limit. A successful result records the attachment id, resolved path, media type, byte count, selected provider/model, and prompt in model-visible durable tool-result content. A failure after attachment persistence includes the same reference fields in its error.

## Selection and credentials

`GET /vision-image-model/config` enumerates configured providers and their model catalogs. Only models that positively declare image input are selectable. The choice is stored in the `vision-image-model` settings namespace and applies live. Credentials continue to belong to the selected provider; this plugin stores none.

An empty selection, unavailable route, rejected model request, or invalid model JSON is a tool error. A hand-written settings value is attempted at runtime even when the current catalog no longer lists it.

## Desktop distribution

The macOS and Windows builders copy this folder into the application runtime as `dsh-vision-image-model-bundled`, rewrite both the package manifest and prebundled browser client handoff to that alias, add it to the runtime dependency closure, and always mount [`apps/desktop/resources/vision.patch.yml`](../apps/desktop/resources/vision.patch.yml). The application remains named **DeepSeek Harness**.

Run the focused tests with Node 24:

```sh
node --test vision-image-model/test/*.test.mjs
```

For a development profile, install the source copy and restart the profile:

```sh
pnpm dsh plugin --profile web add file:./vision-image-model
pnpm dsh --profile web
```

## Configuration

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

`settingsCard: false` omits the Web route/card. `tool: false` omits the tool. The default timeout is 180 seconds.
