/** Verify the packaged community presets without a model or network request. */

import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { join, resolve } from 'node:path'

const [presetRootArgument] = process.argv.slice(2)
if (presetRootArgument === undefined) throw new Error('usage: verify-agent-presets.mjs PRESET_ROOT')
const presetRoot = resolve(presetRootArgument)

const metadata = new Map([
  ['anchored-standard', 'Anchored Standard (experimental)'],
  ['zero-anchored-standard', 'Zero-Anchored Standard (experimental)'],
])
for (const [id, name] of metadata) {
  const text = await readFile(join(presetRoot, id, 'preset.yml'), 'utf8')
  assert.match(text, new RegExp(`^name: ${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`, 'm'))
  assert.match(text, /^description: .+/m)
  assert.match(await readFile(join(presetRoot, id, 'agent.cordis.yml'), 'utf8'), /^- id: /m)
}

function harness() {
  const listeners = new Map()
  return {
    ctx: {
      logger: { warn(message) { throw new Error(`unexpected preset warning: ${message}`) } },
      on(event, listener) { listeners.set(event, listener) },
    },
    listeners,
  }
}

const anchored = await import(pathToFileURL(join(presetRoot, 'anchored-standard/tool-bootstrap.mjs')).href)
const anchoredHarness = harness()
anchored.apply(anchoredHarness.ctx, {
  commonTools: ['read'],
  shellTools: ['bash', 'pwsh'],
  promoteOn: 'either',
  bootstrapMaxTokens: 1024,
  suppressedContextSources: ['agent-instructions', 'skill-catalog'],
})
const tools = [{ name: 'bash' }, { name: 'read' }, { name: 'write' }]
const session = { id: 'desktop-anchored', header: {}, events: [] }
const assemble = anchoredHarness.listeners.get('system-prompt/assemble')
assert.equal(typeof assemble, 'function')
assert.deepEqual((await assemble(undefined, { agent: { session } }, async () => ({ tools }))).tools, tools.slice(0, 2))
session.events.push({ type: 'assistant/message' })
assert.deepEqual((await assemble(undefined, { agent: { session } }, async () => ({ tools }))).tools, tools)

const zero = await import(pathToFileURL(join(presetRoot, 'zero-anchored-standard/zero-tool-bootstrap.mjs')).href)
const zeroHarness = harness()
zero.apply(zeroHarness.ctx)
const zeroSession = { id: 'desktop-zero', header: {}, events: [] }
const zeroAssemble = zeroHarness.listeners.get('system-prompt/assemble')
assert.deepEqual((await zeroAssemble(undefined, { agent: { session: zeroSession } }, async () => ({ tools }))).tools, [])
zeroSession.events.push({ type: 'assistant/message' })
assert.deepEqual((await zeroAssemble(undefined, { agent: { session: zeroSession } }, async () => ({ tools }))).tools, tools)

const anchorTurn = await import(pathToFileURL(join(presetRoot, 'zero-anchored-standard/anchor-turn.mjs')).href)
const anchorHarness = harness()
anchorTurn.apply(anchorHarness.ctx, {})
let prepended
const agent = {
  session: { header: {}, events: [] },
  inbox: { prepend(mode, message) { prepended = { mode, message } } },
}
anchorHarness.listeners.get('agent/inbox/inserted')({ agent, message: { source: { kind: 'user' } } })
assert.equal(prepended.mode, 'next-turn')
assert.equal(prepended.message.content[0].text, anchorTurn.ANCHOR_TEXT)

process.stdout.write('anchored-standard preset verification passed\n')
