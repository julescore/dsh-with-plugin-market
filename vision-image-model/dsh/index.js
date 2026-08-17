// DeepSeek Harness host plugin for the standalone vision-image-model bundle.
//
// It adds one settings namespace (`vision-image-model`) holding the exact
// image-model reference { provider, model }, one web route that enumerates
// the image models already configured in the harness (`GET/POST
// /vision-image-model/config`), and one `vision_read_image` tool that calls
// the selected provider/model through `ctx.llm` with no failover.
//
// Runtime dependencies (@deepseek-ai/schemastery, @deepseek-ai/dsh-settings)
// are intentionally NOT declared in package.json: the plugin is installed
// into a dsh profile with `file:`, and Node resolves them through the
// installation-owned flat module fallback, exactly like an out-of-tree dsh
// plugin is supposed to.

import { basename } from 'node:path'
import z from '@deepseek-ai/schemastery'
import { settingsNamespace } from '@deepseek-ai/dsh-settings'
import { describeImageModelCandidates } from './candidates.js'
import { readLocalImage } from './local-image.js'
import {
  ACCEPTED_MEDIA_TYPES,
  MAX_IMAGE_BYTES,
  normalizeVisionResult,
  parseVisionJson,
  sniffImageMediaType,
  visionSystemPrompt,
} from './vision.js'

export const name = 'vision-image-model'
export const inject = ['tools', 'attachments', 'llm', 'fs']

const NS = settingsNamespace('vision-image-model')
const SETTINGS_SCHEMA = z.object({
  provider: z.string().default(''),
  model: z.string().default(''),
})

const ROUTE_PATH = '/vision-image-model/config'
const DEFAULT_TOOL_NAME = 'vision_read_image'
const MAX_BODY_BYTES = 64 * 1024

const OUTPUT_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    ocrText: { type: 'string' },
    layout: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          label: { type: 'string' },
          text: { type: 'string' },
        },
        required: ['label', 'text'],
        additionalProperties: false,
      },
    },
    uncertain: { type: 'array', items: { type: 'string' } },
    evidence: {
      type: 'object',
      properties: {
        attachmentId: { type: 'string' },
        mediaType: { type: 'string' },
        bytes: { type: 'number' },
        path: { type: 'string' },
        provider: { type: 'string' },
        model: { type: 'string' },
        prompt: { type: 'string' },
      },
      required: ['attachmentId', 'mediaType', 'bytes', 'path', 'provider', 'model', 'prompt'],
      additionalProperties: false,
    },
  },
  required: ['summary', 'ocrText', 'layout', 'uncertain', 'evidence'],
  additionalProperties: false,
}

/** Read the plugin's composition entry as the no-settings fallback. */
function fallbackSelection(config) {
  return {
    provider: typeof config?.provider === 'string' ? config.provider : '',
    model: typeof config?.model === 'string' ? config.model : '',
  }
}

/** Whether one selection is usable: both fields present. */
function selectionComplete(selection) {
  return typeof selection?.provider === 'string' && selection.provider !== ''
    && typeof selection?.model === 'string' && selection.model !== ''
}

function sameSelection(a, b) {
  return a?.provider === b?.provider && a?.model === b?.model
}

/**
 * Attach the settings section and keep the live source thunk current. Runs
 * only where a settings provider is mounted; without one the composition
 * entry stays authoritative.
 */
function installSettings(ctx, fallback) {
  let scope
  const source = () => (scope === undefined ? fallback : scope.get())
  if (typeof ctx.inject === 'function') {
    ctx.inject(['settings'], (sctx) => {
      const settings = sctx.get?.('settings') ?? sctx.settings
      if (!settings || typeof settings.register !== 'function') return
      scope = settings.register(NS, SETTINGS_SCHEMA, {
        base: fallback,
        applies: 'live',
      })
      // When the settings provider detaches, fall back to the composition
      // entry instead of holding a stale scope.
      sctx.effect?.(() => () => {
        scope = undefined
      })
    })
  }
  return { source, getScope: () => scope }
}

/** Read the settings descriptor revision and writability, when available. */
function settingsView(ctx) {
  const settings = ctx.get?.('settings') ?? ctx.settings
  if (!settings || typeof settings.describe !== 'function') {
    return { available: false, writable: false, revision: undefined }
  }
  const descriptors = settings.describe() ?? []
  const descriptor = descriptors.find((entry) => String(entry.ns) === String(NS))
  return {
    available: true,
    writable: settings.writable === true,
    revision: descriptor?.revision,
  }
}

/** JSON response with CORS-strict local usage in mind. */
function sendJson(res, status, body) {
  if (!res.headersSent) {
    res.writeHead(status, { 'content-type': 'application/json' })
  }
  res.end(JSON.stringify(body))
}

/** Same-origin guard for the write route; absent Origin (curl, tests) passes. */
function sameOrigin(req) {
  const origin = req.headers.origin
  if (origin === undefined) return true
  const host = req.headers.host
  if (typeof host !== 'string' || host === '') return false
  try {
    return new URL(origin).host === host
  } catch {
    return false
  }
}

async function readRequestBody(req, signal) {
  const chunks = []
  let total = 0
  for await (const chunk of req) {
    total += chunk.length
    if (total > MAX_BODY_BYTES) {
      throw new Error(`request body over the ${MAX_BODY_BYTES}-byte limit`)
    }
    chunks.push(chunk)
  }
  if (signal?.aborted) throw new Error('request aborted')
  return Buffer.concat(chunks).toString('utf8')
}

/** Tool-returned evidence rendered for the transcript. */
function renderEvidence(_args, value) {
  const lines = []
  if (value?.evidence) {
    lines.push(
      `Image evidence: attachment=${value.evidence.attachmentId}; type=${value.evidence.mediaType}; bytes=${value.evidence.bytes}; path=${value.evidence.path}; model=${value.evidence.provider}/${value.evidence.model}; prompt=${JSON.stringify(value.evidence.prompt)}`,
    )
  }
  if (value?.summary) lines.push('', value.summary)
  if (value?.ocrText) lines.push('', 'Text:', value.ocrText)
  if (Array.isArray(value?.layout) && value.layout.length > 0) {
    lines.push('', 'Layout:')
    for (const entry of value.layout) lines.push(`- ${entry.label}: ${entry.text}`)
  }
  if (Array.isArray(value?.uncertain) && value.uncertain.length > 0) {
    lines.push('', 'Uncertain:', ...value.uncertain.map((entry) => `- ${entry}`))
  }
  return [{ type: 'text', text: lines.join('\n') }]
}

/** Collect one model answer into text, refusing non-stop finishes. */
async function collectAnswer(stream) {
  let text = ''
  let sawDelta = false
  let sawBlock = false
  let lastBlockText = ''
  for await (const chunk of stream) {
    if (chunk?.type === 'text-delta') {
      sawDelta = true
      text += chunk.text ?? ''
    } else if (chunk?.type === 'block-end' && chunk.block?.type === 'text') {
      sawBlock = true
      lastBlockText = String(chunk.block.text ?? '')
    } else if (chunk?.type === 'finish') {
      if (chunk.reason?.kind !== 'stop') {
        const failure = chunk.reason?.failure
        const detail = failure?.message ? `: ${failure.message}` : `: ${String(chunk.reason?.kind ?? 'unknown')}`
        throw new Error(`image model call did not finish cleanly${detail}`)
      }
    }
  }
  if (!sawDelta && sawBlock) return lastBlockText
  return text
}

/** Build the model-facing image message around the saved attachment ref. */
function imageMessage(focus, attachment) {
  return {
    id: `vision-image-model-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    role: 'user',
    content: [
      {
        type: 'text',
        text: typeof focus === 'string' && focus.trim() !== ''
          ? `Read this image. ${focus.trim()}`
          : 'Read this image.',
      },
      { type: 'image', attachment },
    ],
    source: { kind: 'user' },
  }
}

/**
 * Register the exact-locked vision tool. Unconfigured or failed reads surface
 * as tool errors; there is deliberately no failover to another model.
 */
function registerTool(ctx, source, config = {}) {
  const toolName = typeof config.toolName === 'string' && config.toolName.trim() !== ''
    ? config.toolName.trim()
    : DEFAULT_TOOL_NAME

  const tool = {
    name: toolName,
    description:
      'Read a local image using the image model configured in Settings (vision-image-model). Use whenever the conversation references a local image the current chat model cannot see. Returns structured evidence: summary, verbatim OCR text, layout regions in reading order, and uncertainty notes. The exact selected model is used; failures are reported and never fail over to another model.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Local image path, resolved from the current session workspace',
        },
        prompt: {
          type: 'string',
          description: 'Optional extra focus for the reading (e.g. "focus on the axis labels")',
        },
      },
      required: ['path'],
      additionalProperties: false,
    },
    output: {
      schema: OUTPUT_SCHEMA,
      render: renderEvidence,
    },
    timeoutMs: typeof config.timeoutMs === 'number' ? config.timeoutMs : 180_000,
    isConcurrencySafe: () => true,
    presentCall: (args) => ({
      card: 'generic',
      title: toolName,
      kind: 'read',
      rawInput: args,
      ...(typeof args?.path === 'string' && !/^https?:\/\//i.test(args.path)
        ? { locations: [{ path: args.path }] }
        : {}),
    }),
    async execute(args, exec) {
      const selection = source()
      if (!selectionComplete(selection)) {
        throw new Error(
          'no image model is configured. Open Settings -> Plugins -> Vision image model, pick one of the configured image-capable models, and retry.',
        )
      }
      const sourcePath = typeof args?.path === 'string' ? args.path.trim() : ''
      if (sourcePath === '') {
        throw new Error(`${toolName} needs a non-empty string "path".`)
      }

      const byteCap = Math.min(
        MAX_IMAGE_BYTES,
        ctx.attachments.imageLimits.maxImageBytes,
        ctx.attachments.imageLimits.maxMessageImageBytes,
      )
      const { target, data } = await readLocalImage(ctx, sourcePath, exec, byteCap)
      const bytes = Buffer.from(data)
      const mediaType = sniffImageMediaType(bytes)
      if (mediaType === undefined) {
        throw new Error(`content of ${target.displayPath} is not a recognized image (${ACCEPTED_MEDIA_TYPES.join(', ')})`)
      }

      const attachment = await ctx.attachments.saveImage({
        data: bytes,
        mediaType,
        name: basename(target.displayPath),
      })

      const evidence = {
        attachmentId: attachment.attachmentId,
        mediaType: attachment.mediaType,
        bytes: attachment.bytes,
        path: target.displayPath,
        provider: selection.provider,
        model: selection.model,
        prompt: typeof args.prompt === 'string' ? args.prompt.trim() : '',
      }
      try {
        const text = await collectAnswer(ctx.llm.stream({
          provider: selection.provider,
          model: selection.model,
          system: visionSystemPrompt(args.prompt),
          messages: [imageMessage(args.prompt, attachment)],
          signal: exec.signal,
        }))
        return {
          ...normalizeVisionResult(parseVisionJson(text)),
          evidence,
        }
      } catch (error) {
        throw new Error(
          `image recognition failed after persisting attachment ${evidence.attachmentId} (${evidence.mediaType}, ${evidence.bytes} bytes) from ${evidence.path} for ${evidence.provider}/${evidence.model} with prompt ${JSON.stringify(evidence.prompt)}: ${error instanceof Error ? error.message : String(error)}`,
          { cause: error },
        )
      }
    },
  }

  ctx.tools.register(tool)
}

/**
 * Host route behind the settings card. GET returns the current selection and
 * the candidate groups; POST validates the pick against the live llm catalog
 * and writes the settings namespace through the revision-fenced seam.
 */
function registerConfigRoute(webCtx, rootCtx, source, getScope) {
  webCtx.effect(() => webCtx.webServer.register({
    name: 'vision-image-model-config',
    kind: 'exact',
    path: ROUTE_PATH,
    handler: async (req, res) => {
      if (!sameOrigin(req)) {
        sendJson(res, 403, { ok: false, error: 'cross-origin requests are refused' })
        return
      }
      if (req.method === 'GET') {
        try {
          const view = settingsView(rootCtx)
          const candidates = await describeImageModelCandidates(rootCtx.llm, rootCtx.get?.('settings') ?? rootCtx.settings)
          sendJson(res, 200, {
            ok: true,
            ns: String(NS),
            current: source(),
            writable: view.writable,
            ...(view.revision === undefined ? {} : { revision: view.revision }),
            candidates,
          })
        } catch (error) {
          sendJson(res, 500, { ok: false, error: error instanceof Error ? error.message : String(error) })
        }
        return
      }
      if (req.method === 'POST') {
        try {
          const body = JSON.parse(await readRequestBody(req))
          const provider = typeof body?.provider === 'string' ? body.provider.trim() : ''
          const model = typeof body?.model === 'string' ? body.model.trim() : ''
          if (provider === '' || model === '') {
            sendJson(res, 400, { ok: false, error: 'provider and model are both required' })
            return
          }
          const view = settingsView(rootCtx)
          const scope = getScope()
          if (!view.available || scope === undefined) {
            sendJson(res, 400, { ok: false, error: 'settings storage is not available in this deployment' })
            return
          }
          if (!view.writable) {
            sendJson(res, 400, { ok: false, error: 'the settings document is read-only' })
            return
          }
          if (body.expectedRevision !== undefined && body.expectedRevision !== view.revision) {
            sendJson(res, 409, {
              ok: false,
              code: 'SETTINGS_CONFLICT',
              error: `settings changed since the card loaded (expected revision ${body.expectedRevision}, now ${view.revision})`,
            })
            return
          }
          // Saving the current value is a no-op and must survive a catalog
          // outage; anything new is validated against the live catalog.
          if (!sameSelection(source(), { provider, model })) {
            const candidates = await describeImageModelCandidates(rootCtx.llm, rootCtx.get?.('settings') ?? rootCtx.settings)
            const group = candidates.find((entry) => entry.provider === provider)
            const modelView = group?.models.find((entry) => entry.id === model)
            if (!group || !group.active) {
              sendJson(res, 400, { ok: false, error: `provider "${provider}" is not an active configured model route` })
              return
            }
            if (modelView === undefined) {
              sendJson(res, 400, { ok: false, error: `model "${model}" is not in provider "${provider}"'s current catalog` })
              return
            }
            if (modelView.imageInput !== true) {
              sendJson(res, 400, {
                ok: false,
                error: `model "${model}" does not declare image input; pick a vision-capable model`,
              })
              return
            }
          }
          await scope.update({ provider, model })
          const after = settingsView(rootCtx)
          sendJson(res, 200, { ok: true, ...(after.revision === undefined ? {} : { revision: after.revision }) })
        } catch (error) {
          sendJson(res, 400, { ok: false, error: error instanceof Error ? error.message : String(error) })
        }
        return
      }
      sendJson(res, 405, { ok: false, error: 'method not allowed' })
    },
  }), 'vision-image-model: settings route')
}

/** Cordis entry point. */
export function apply(ctx, config = {}) {
  const fallback = fallbackSelection(config)
  const { source, getScope } = installSettings(ctx, fallback)

  if (config.tool !== false) {
    registerTool(ctx, source, config)
  }

  // webServer exists only under the web profile; headless stays untouched.
  if (config.settingsCard !== false && typeof ctx.inject === 'function') {
    ctx.inject(['webServer'], (wctx) => {
      registerConfigRoute(wctx, ctx, source, getScope)
    })
  }
}
