import assert from 'node:assert/strict'
import test from 'node:test'
import { transformPromptImages } from '../dsh/prompt-admission.js'

test('transforms uploaded images independently while preserving user text order', async () => {
  const selection = { provider: 'vision-provider', model: 'vision-model' }
  const attachment = {
    attachmentId: 'att-1', mediaType: 'image/png', bytes: 1, width: 1, height: 1,
  }
  let received
  const decision = await transformPromptImages({
    sessionId: 'session-1',
    content: [
      { type: 'text', text: 'What is shown?' },
      { type: 'image', attachment },
    ],
    images: [attachment],
  }, selection, async (...args) => {
    received = args
    return {
      summary: 'A settings dialog.',
      ocrText: 'Image model',
      layout: [{ label: 'dialog', text: 'Image model' }],
      uncertain: [],
    }
  })

  assert.equal(decision.kind, 'transformed')
  assert.deepEqual(decision.content[0], { type: 'text', text: 'What is shown?' })
  assert.match(decision.content[1].text, /A settings dialog/)
  assert.match(decision.content[1].text, /vision-provider\/vision-model/)
  assert.equal(decision.content.some((block) => block.type === 'image'), false)
  assert.equal(received[0], attachment)
  assert.equal(received[1], 'What is shown?')
})
