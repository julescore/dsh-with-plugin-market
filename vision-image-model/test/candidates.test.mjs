import test from 'node:test'
import assert from 'node:assert/strict'
import { describeImageModelCandidates, getPath, validateActiveModelSelection } from '../dsh/candidates.js'

test('getPath reads nested objects and arrays', () => {
  const value = { providers: { openai: { model: 'qwen-vl' } }, list: [{ id: 1 }] }
  assert.equal(getPath(value, ['providers', 'openai', 'model']), 'qwen-vl')
  assert.equal(getPath(value, ['list', 0, 'id']), 1)
  assert.equal(getPath(value, ['missing']), undefined)
  assert.equal(getPath(null, ['a']), undefined)
})

test('active providers map their model catalog with modality states', async () => {
  const llm = {
    listProviders: () => [
      { id: 'dashscope', name: 'DashScope' },
    ],
    listModels: async (provider) => {
      assert.equal(provider, 'dashscope')
      return [
        { provider, id: 'qwen3-vl-plus', name: 'Qwen3-VL-Plus', inputModalities: ['text', 'image'] },
        { provider, id: 'qwen3-text', name: 'Qwen3-Text', inputModalities: ['text'] },
        { provider, id: 'unknown-capability', name: 'Unknown' },
      ]
    },
  }
  const [group] = await describeImageModelCandidates(llm, undefined)
  assert.equal(group.provider, 'dashscope')
  assert.equal(group.active, true)
  assert.equal(group.models.length, 3)
  assert.equal(group.models[0].imageInput, true)
  assert.equal(group.models[1].imageInput, false)
  assert.equal(group.models[2].imageInput, undefined)
})

test('a failing model catalog lands as a group error, not a throw', async () => {
  const llm = {
    listProviders: () => [{ id: 'broken', name: 'Broken' }],
    listModels: async () => { throw new Error('catalog unavailable') },
  }
  const [group] = await describeImageModelCandidates(llm, undefined)
  assert.equal(group.error, 'catalog unavailable')
  assert.deepEqual(group.models, [])
})

test('configured-but-inactive directory entries appear, unconfigured ones do not', async () => {
  const llm = {
    listProviders: () => [],
    listConfigurableProviders: () => [
      { provider: 'inactive-route', displayName: 'Inactive', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'inactive-route'] },
      { provider: 'unconfigured-route', displayName: 'Unconfigured', settingsNs: 'llm-pi-ai', settingsPath: ['providers', 'unconfigured-route'] },
    ],
  }
  const settings = {
    describe: () => [
      {
        ns: 'llm-pi-ai',
        value: { providers: { 'inactive-route': { apiKeyEnv: 'X' } } },
        user: { providers: { 'inactive-route': { apiKeyEnv: 'X' } } },
      },
    ],
  }
  const groups = await describeImageModelCandidates(llm, settings)
  assert.equal(groups.length, 1)
  assert.equal(groups[0].provider, 'inactive-route')
  assert.equal(groups[0].active, false)
  assert.match(groups[0].error, /not active/)
})


test('every model in an active catalog is selectable regardless of modality metadata', () => {
  const candidates = [
    {
      provider: 'kiro-gpt',
      active: true,
      models: [
        { id: 'vision', imageInput: true },
        { id: 'text', imageInput: false },
        { id: 'gpt-5.6-sol' },
      ],
    },
    { provider: 'inactive', active: false, models: [{ id: 'model' }] },
  ]

  assert.equal(validateActiveModelSelection(candidates, 'kiro-gpt', 'vision'), undefined)
  assert.equal(validateActiveModelSelection(candidates, 'kiro-gpt', 'text'), undefined)
  assert.equal(validateActiveModelSelection(candidates, 'kiro-gpt', 'gpt-5.6-sol'), undefined)
  assert.match(validateActiveModelSelection(candidates, 'inactive', 'model'), /not an active configured model route/)
  assert.match(validateActiveModelSelection(candidates, 'kiro-gpt', 'missing'), /not in provider/)
})
