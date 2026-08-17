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

import { lookup } from 'node:dns/promises'
import { isIP } from 'node:net'
import { basename } from 'node:path'
import { readFile } from 'node:fs/promises'
import z from '@deepseek-ai/schemastery'
import { settingsNamespace } from '@deepseek-ai/dsh-settings'
import { describeImageModelCandidates } from './candidates.js'
import {
  ACCEPTED_MEDIA_TYPES,
  MAX_IMAGE_BYTES,
  normalizeVisionResult,
  parseVisionJson,
  sniffImageMediaType,
  visionSystemPrompt,
} from './vision.js'

export const name = 'vision-image-model'
export const inject = ['tools', 'attachments', 'llm']

const NS = settingsNamespace('vision-image-model')
const SETTINGS_SCHEMA = z.object({
  provider: z.string().default(''),
  model: z.string().default(''),
})

const ROUTE_PATH = '/vision-image-model/config'
const DEFAULT_TOOL_NAME = 'vision_read_image'
const MAX_REMOTE_REDIRECTS = 5
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
      },
    },
    uncertain: { type: 'array', items: { type: 'string' } },
  },
  required: ['summary', 'ocrText', 'layout', 'uncertain'],
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
      try {
        scope = settings.register(NS, SETTINGS_SCHEMA, {
          base: fallback,
          applies: 'live',
        })
      } catch (error) {
        console.error(`[vision-image-model] settings registration failed: ${error}`)
        return
      }
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

/** Validate one address against loopback, private, link-local, and reserved ranges. */
function unsafeAddress(address) {
  if (isIP(address) === 0) return true
  if (isIP(address) === 4) {
    const [a, b] = address.split('.').map(Number)
    if (a === 0 || a === 10 || a === 127) return true
    if (a === 169 && b === 254) return true
    if (a === 172 && b >= 16 && b <= 31) return true
    if (a === 192 && b === 168) return true
    if (a === 100 && b >= 64 && b <= 127) return true
    if (a >= 224) return true
    return false
  }
  const lowered = address.toLowerCase()
  if (lowered === '::' || lowered === '::1' || lowered.startsWith('fc') || lowered.startsWith('fd')) return true
  if (lowered.startsWith('fe8') || lowered.startsWith('fe9') || lowered.startsWith('fea') || lowered.startsWith('feb')) return true
  if (lowered.startsWith('ff')) return true
  return false
}

/**
 * Fetch a remote image with per-hop private/reserved address rejection and a
 * size cap. This is a best-effort SSRF guard, not DNS pinning: a hostile
 * rebinding race is out of scope for this isolated plugin.
 */
async function fetchRemoteImage(url, signal) {
  let current = new URL(url)
  for (let hop = 0; hop <= MAX_REMOTE_REDIRECTS; hop += 1) {
    if (current.protocol !== 'https:' && current.protocol !== 'http:') {
      throw new Error('only http(s) image URLs are supported')
    }
    const addresses = await lookup(current.hostname, { all: true, signal })
    for (const record of addresses) {
      if (unsafeAddress(record.address)) {
        throw new Error(`refusing to fetch ${current.hostname}: it resolves to a private or reserved address`)
      }
    }
    const response = await fetch(current, { redirect: 'manual', signal })
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get('location')
      await response.body?.cancel().catch(() => {})
      if (!location) throw new Error(`redirect (${response.status}) without a location header`)
      if (hop === MAX_REMOTE_REDIRECTS) throw new Error(`too many redirects (max ${MAX_REMOTE_REDIRECTS})`)
      current = new URL(location, current)
      continue
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {})
      throw new Error(`image download failed (${response.status})`)
    }
    const declared = Number(response.headers.get('content-length'))
    if (Number.isFinite(declared) && declared > MAX_IMAGE_BYTES) {
      await response.body?.cancel().catch(() => {})
      throw new Error(`remote image is ${declared} bytes, over the ${MAX_IMAGE_BYTES}-byte limit`)
    }
    const buffer = Buffer.from(await response.arrayBuffer())
    if (buffer.length > MAX_IMAGE_BYTES) {
      throw new Error(`remote image exceeds the ${MAX_IMAGE_BYTES}-byte limit`)
    }
    return buffer
  }
  throw new Error('too many redirects')
}

async function loadImageBytes(source, signal) {
  if (/^https?:\/\//i.test(source)) {
    return fetchRemoteImage(source, signal)
  }
  const buffer = await readFile(source)
  if (buffer.length > MAX_IMAGE_BYTES) {
    throw new Error(`image is ${buffer.length} bytes, over the ${MAX_IMAGE_BYTES}-byte limit`)
  }
  return buffer
}

/** Tool-returned evidence rendered for the transcript. */
function renderEvidence(_args, value) {
  const lines = []
  if (value?.summary) lines.push(value.summary)
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
      'Read an image using the image model configured in Settings (vision-image-model). Use whenever the conversation references an image the current chat model cannot see: pass a local file path or an http(s) URL. Returns structured evidence: summary, verbatim OCR text, layout regions in reading order, and uncertainty notes. The exact selected model is used; failures are reported and never fail over to another model.',
    parameters: {
      type: 'object',
      properties: {
        path: {
          type: 'string',
          description: 'Absolute local file path or http(s) URL of the image',
        },
        prompt: {
          type: 'string',
          description: 'Optional extra focus for the reading (e.g. "focus on the axis labels")',
        },
      },
      required: ['path'],
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

      const bytes = await loadImageBytes(sourcePath, exec.signal)
      const mediaType = sniffImageMediaType(bytes)
      if (mediaType === undefined) {
        throw new Error(`content of ${sourcePath} is not a recognized image (${ACCEPTED_MEDIA_TYPES.join(', ')})`)
      }

      const attachment = await ctx.attachments.saveImage({
        data: bytes,
        mediaType,
        name: basename(sourcePath.split('?')[0] ?? 'image'),
      })

      const text = await collectAnswer(ctx.llm.stream({
        provider: selection.provider,
        model: selection.model,
        system: visionSystemPrompt(args.prompt),
        messages: [imageMessage(args.prompt, attachment)],
        signal: exec.signal,
      }))

      return normalizeVisionResult(parseVisionJson(text))
    },
  }

  try {
    ctx.tools.register(tool)
  } catch (error) {
    // A duplicate of the chosen name is a composition issue, not a reason to
    // take the settings feature down.
    console.error(`[vision-image-model] ${toolName} registration skipped: ${error}`)
  }
}

/**
 * Host route behind the settings card. GET returns the current selection and
 * the candidate groups; POST validates the pick against the live llm catalog
 * and writes the settings namespace through the revision-fenced seam.
 */
function registerConfigRoute(webCtx, rootCtx, source, getScope) {
  webCtx.webServer.register({
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
  })
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
      try {
        registerConfigRoute(wctx, ctx, source, getScope)
      } catch (error) {
        console.error(`[vision-image-model] settings card route skipped: ${error}`)
      }
    })
  }
}
