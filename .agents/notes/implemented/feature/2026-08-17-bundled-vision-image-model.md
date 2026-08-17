# Agent Note: Bundled vision image model

Status: implemented

English | [中文](2026-08-17-bundled-vision-image-model.zh.md)

## Problem

The desktop repository contained an image-model plugin, but neither platform packaged or loaded it. Its first implementation also read host paths directly and fetched arbitrary URLs, so it bypassed the Harness filesystem policy and exposed an incomplete SSRF defense. Model selection and image provenance were not durable in the session transcript.

## Decision

The macOS and Windows distributions copy the repository-owned plugin into the closed runtime under the fixed `dsh-vision-image-model-bundled` alias. The installer applies the alias to both the package manifest and the prebundled browser client module handoff, then records it in the runtime dependency manifest so profile module-fallback repair exposes one consistent identity to Loader. Both native shells always apply a separate `vision.patch.yml`; plugin-market conflict choices do not enable, disable, or replace vision support.

The plugin accepts local paths only. It resolves the session workspace through `ctx.fs`, requires a regular file, performs a bounded byte read, and emits `fs/observed`. Remote images must first be downloaded through an approved network tool. Image bytes are persisted in the attachment store before the exact selected provider/model is called, with no failover.

The settings card permits every model in an active provider catalog. Image-input metadata remains an advisory warning because adapter catalogs can omit or lag a model capability. Saving rejects an inactive provider or a model absent from its current catalog; the selected provider remains authoritative if the eventual image request fails.

The rendered tool result includes the attachment id, resolved path, media type, byte count, selected provider/model, and prompt. Errors after attachment persistence include the same evidence, so replay does not depend on the successful canonical value, which the session log does not retain.

The package verifiers require the copied package and patch, execute the browser client to verify its exact Loader handoff, compose the row, start the Host, query the settings route, and inspect the Web boot graph. Focused tests cover bounded filesystem admission and the desktop installer; a ToolRuntime smoke proves the global tool is visible from an agent scope.

## Alternatives considered

**Fetch HTTP and HTTPS URLs inside the tool.** Rejected because DNS preflight followed by a separate fetch does not pin the resolved address and therefore does not close DNS-rebinding SSRF. The product already has approval-aware network capabilities.

**Install the plugin into each mutable user profile.** Rejected because application upgrades would modify user state, collide with local versions, and make the feature depend on market-conflict selection.

**Add the tool separately to every agent preset.** Rejected because ToolRuntime global registrations are inherited by agent scopes. Duplicating the row would increase preset drift and create same-name collisions.

## Consequences

Every new desktop package includes the same optional-model image recognition feature on macOS and Windows while preserving the DeepSeek Harness application name. Users may select newly image-capable models before their adapter metadata is updated, while text-only and unknown-capability choices display a warning and can fail at request time. Users must download remote inputs before use. The local-only stance removes direct URL convenience but keeps network authorization outside this plugin and makes filesystem observations and durable evidence consistent with Harness policy.
