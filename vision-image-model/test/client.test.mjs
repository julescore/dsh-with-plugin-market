import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'

async function clientModule() {
  const handoffs = []
  const context = vm.createContext({
    window: {
      __ModuleLoader__: {
        load(handoff) {
          handoffs.push(handoff)
        },
      },
    },
  })
  const source = await readFile(new URL('../dsh/client.js', import.meta.url), 'utf8')
  new vm.Script(source, { filename: 'vision-image-model/dsh/client.js' }).runInContext(context)
  assert.equal(handoffs.length, 1)
  return handoffs[0].factory(() => { throw new Error('unexpected require') })
}

const labels = {
  notImage: 'declares text-only; image calls may fail',
  unknownModality: 'image capability unknown; image calls may fail',
}

test('client options keep every capability state selectable with advisory labels', async () => {
  const module = await clientModule()
  const image = module.modelOptionPresentation('route', {
    id: 'vision',
    name: 'Vision',
    imageInput: true,
  }, labels)
  const text = module.modelOptionPresentation('route', {
    id: 'text',
    name: 'Text',
    imageInput: false,
  }, labels)
  const unknown = module.modelOptionPresentation('route', {
    id: 'unknown',
    name: 'Unknown',
  }, labels)

  assert.deepEqual(Object.keys(image.props).sort(), ['key', 'value'])
  assert.deepEqual(Object.keys(text.props).sort(), ['key', 'value'])
  assert.deepEqual(Object.keys(unknown.props).sort(), ['key', 'value'])
  assert.equal(image.label, 'Vision (vision)')
  assert.match(text.label, /text-only; image calls may fail/)
  assert.match(unknown.label, /capability unknown; image calls may fail/)
})
