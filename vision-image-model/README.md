# vision-image-model

A standalone DeepSeek Harness plugin, isolated in this one folder. It adds:

1. an **image model setting** in the Web settings surface (Plugins tab) that
   lets the user pick one already-configured, image-capable model;
2. a **`vision_read_image`** tool that calls exactly that `{ provider, model }`
   through `ctx.llm` — no failover, failures surface as tool errors.

The folder touches nothing outside itself: no root `package.json`,
`pnpm-workspace.yaml`, lockfile, or tsconfig changes. Pulling upstream
DeepSeek Harness updates cannot conflict with it; carry the folder along (or
ignore it) as one unit.

## How it works

- **Persistence** — host half registers the settings namespace
  `vision-image-model` (`{ provider, model }`) through the dsh settings seam.
  The user's choice lives in the profile's `settings.yaml`, hot-applied live.
  Headless deployments fall back to the cordis.yml composition entry.
- **Candidates** — `GET /vision-image-model/config` enumerates
  `ctx.llm.listProviders()` + `ctx.llm.listModels()`. Only models whose
  `inputModalities` positively includes `image` are selectable; text-only and
  undeclared models render disabled. Configured-but-inactive providers
  (missing credential) render as an explanatory note.
- **Exact lock** — the tool resolves the live selection and calls only that
  provider/model. An empty, drifted, or failing selection is a tool error,
  never a silent fallback.
- **Credentials** — reused from the provider's existing Models-page
  configuration; this plugin stores no API keys.

## Install into a profile

From the repository root:

```sh
pnpm dsh plugin --profile web add file:./vision-image-model
```

`file:` is important: the plugin is copied into the profile, and its runtime
imports (`@deepseek-ai/schemastery`, `@deepseek-ai/dsh-settings`, React, the
client primitives) resolve through the dsh installation's flat module
fallback, exactly like an out-of-tree plugin. `link:` would resolve those
imports from this repository checkout instead.

Then start the web profile as usual:

```sh
pnpm dsh --profile web
```

Open **Settings → Plugins → Vision image model** and pick a model.

Update after editing this folder (pnpm treats an unchanged `file:` spec as
already up to date, so re-adding alone does not re-copy):

```sh
pnpm dsh plugin --profile web remove dsh-vision-image-model
pnpm dsh plugin --profile web add file:./vision-image-model
```

Then restart `dsh web` so the new bundle is loaded.

## Built in at package time (GitHub Actions)

For a deployment that builds this repository in Actions and then runs it
directly, stage a portable `DSH_HOME` during the build so the deployed
artifact already carries the plugin in its profile:

```sh
bash vision-image-model/stage-profile.sh "$RUNNER_TEMP/dsh-home" web
```

The script initializes the profile, installs this plugin into it, removes the
absolute `file:` spec so the staged home is copyable to another machine, and
verifies the plugin row appears in `--dump-config`. Set `VISION_IMAGE_PROVIDER`
and `VISION_IMAGE_MODEL` to bundle a default selection.

Example workflow step (add it before the step that starts `dsh web`):

```yaml
- name: Stage built-in vision plugin profile
  run: bash vision-image-model/stage-profile.sh "$RUNNER_TEMP/dsh-home" web
- name: Start harness
  env:
    DSH_HOME: ${{ runner.temp }}/dsh-home
  run: pnpm dsh --profile web
```

If the staged home travels to another machine, ship the whole `dsh-home`
directory alongside the repository checkout; `dsh` repairs the installation
fallback links for the target machine on first boot.

This staging path touches no upstream-shared files: no workflow edits, no
workspace changes, no npm release changes.

## cordis.yml knobs

The bundle row is inserted by `cordis.patch.yml`; per-deployment overrides go
in the profile patch layer:

```yaml
- update:
    id: vision-image-model
    config:
      provider: dashscope        # composition fallback (used headless)
      model: qwen3-vl-plus
      toolName: vision_read_image
      timeoutMs: 180000
      settingsCard: true         # false removes the web settings route/card
      tool: true                 # false removes the read tool
```

## Layout

```text
vision-image-model/
  package.json         dsh bundle + client manifest
  cordis.patch.yml     inserts the plugin row
  dsh/index.js         host: settings namespace, /vision-image-model/config, tool
  dsh/client.js        web: settings.plugin.item card (prebuilt CJS handoff)
  dsh/candidates.js    pure candidate enumeration (unit-tested)
  dsh/vision.js        pure image/JSON helpers (unit-tested)
  stage-profile.sh     build-time portable DSH_HOME staging for Actions
  test/                node:test unit tests, run with `pnpm --dir . test`
```

## Scope notes

- Remote image URLs are fetched with per-redirect private/reserved address
  rejection and a 25 MB cap. This is a best-effort SSRF guard, not DNS
  pinning.
- Only `png`, `jpeg`, `gif`, and `webp` bytes are accepted (the dsh
  attachment store's media types), verified from magic bytes.
- The model catalog is advisory in dsh; this plugin uses it to constrain the
  settings picker, but a hand-written settings.yaml reference is still
  attempted at runtime and fails only when the adapter itself rejects it.
