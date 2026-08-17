import test from 'node:test'
import assert from 'node:assert/strict'
import { readLocalImage } from '../dsh/local-image.js'

function fixture(options = {}) {
  const info = Object.hasOwn(options, 'info') ? options.info : { type: 'file', version: 'v1' }
  const data = options.data ?? Buffer.from('image')
  const calls = []
  const target = { displayPath: '/workspace/image.png', targetKey: 'image' }
  const ctx = {
    fs: {
      resolve: async (path, options) => { calls.push(['resolve', path, options]); return target },
      stat: async (resolved, signal) => { calls.push(['stat', resolved, signal]); return info },
      readBytes: async (resolved, signal, maxBytes) => { calls.push(['readBytes', resolved, signal, maxBytes]); return data },
    },
    emit: (...args) => calls.push(['emit', ...args]),
  }
  const signal = new AbortController().signal
  const exec = { signal, agent: { session: { header: { cwd: '/workspace' } } } }
  return { ctx, exec, calls, target, signal }
}

test('reads through the session-scoped filesystem and records the present version', async () => {
  const { ctx, exec, calls, target, signal } = fixture()
  const result = await readLocalImage(ctx, 'image.png', exec, 25)
  assert.equal(result.target, target)
  assert.deepEqual(Buffer.from(result.data), Buffer.from('image'))
  assert.deepEqual(calls, [
    ['resolve', 'image.png', { cwd: '/workspace', signal }],
    ['stat', target, signal],
    ['readBytes', target, signal, 25],
    ['emit', 'fs/observed', target, { kind: 'present', version: 'v1' }, exec],
  ])
})

test('records an absent target without attempting a read', async () => {
  const f = fixture({ info: undefined })
  await assert.rejects(readLocalImage(f.ctx, 'missing.png', f.exec, 25), /not found/)
  assert.deepEqual(f.calls.map(call => call[0]), ['resolve', 'stat', 'emit'])
  assert.deepEqual(f.calls.at(-1), ['emit', 'fs/observed', f.target, { kind: 'absent' }, f.exec])
})

test('rejects directories and remote URLs before bytes are read', async () => {
  const directory = fixture({ info: { type: 'directory', version: 'v1' } })
  await assert.rejects(readLocalImage(directory.ctx, '.', directory.exec, 25), /not a regular file/)
  assert.deepEqual(directory.calls.map(call => call[0]), ['resolve', 'stat'])

  const remote = fixture()
  await assert.rejects(readLocalImage(remote.ctx, 'https://example.com/image.png', remote.exec, 25), /local image paths only/)
  assert.deepEqual(remote.calls, [])
})
