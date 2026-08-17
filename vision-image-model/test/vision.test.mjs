import test from 'node:test'
import assert from 'node:assert/strict'
import {
  normalizeVisionResult,
  parseVisionJson,
  sniffImageMediaType,
  visionSystemPrompt,
} from '../dsh/vision.js'

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0])
const GIF = Buffer.from('GIF89a', 'ascii')
const WEBP = Buffer.concat([Buffer.from('RIFF', 'ascii'), Buffer.alloc(4), Buffer.from('WEBP', 'ascii')])

test('sniffImageMediaType recognizes accepted image headers only', () => {
  assert.equal(sniffImageMediaType(PNG), 'image/png')
  assert.equal(sniffImageMediaType(JPEG), 'image/jpeg')
  assert.equal(sniffImageMediaType(GIF), 'image/gif')
  assert.equal(sniffImageMediaType(WEBP), 'image/webp')
  assert.equal(sniffImageMediaType(Buffer.from('not an image')), undefined)
})

test('visionSystemPrompt carries the JSON contract and optional focus', () => {
  const prompt = visionSystemPrompt('read the axis labels')
  assert.match(prompt, /JSON object/)
  assert.match(prompt, /axis labels/)
  assert.doesNotMatch(visionSystemPrompt(), /Extra focus/)
})

test('parseVisionJson tolerates fences and surrounding prose', () => {
  const parsed = parseVisionJson('Here it is:\n```json\n{"summary":"s","ocrText":"t","layout":[],"uncertain":[]}\n```\ndone')
  assert.equal(parsed.summary, 's')
  assert.equal(parsed.ocrText, 't')
})

test('parseVisionJson rejects empty, non-object, and invalid output', () => {
  assert.throws(() => parseVisionJson(''), /empty/)
  assert.throws(() => parseVisionJson('no braces here'), /no JSON/)
  assert.throws(() => parseVisionJson('{"broken": }'), /invalid JSON/)
  assert.throws(() => parseVisionJson('[1,2]'), /no JSON|not an object/)
})

test('normalizeVisionResult fills missing fields and filters layout entries', () => {
  const result = normalizeVisionResult({
    summary: 'a chart',
    layout: [{ label: 'title', text: 'Sales' }, null, { label: '', text: '' }],
    uncertain: ['axis unit', 42],
  })
  assert.deepEqual(result, {
    summary: 'a chart',
    ocrText: '',
    layout: [{ label: 'title', text: 'Sales' }],
    uncertain: ['axis unit'],
  })
})
