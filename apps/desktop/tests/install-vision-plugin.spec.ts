import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..')
const source = join(root, 'vision-image-model')
const installer = join(root, 'apps/desktop/scripts/install-vision-plugin.py')
const temporaryRoots: string[] = []

function fixture(): { runtime: string; plugin: string } {
  const temporary = mkdtempSync(join(tmpdir(), 'dsh-desktop-vision-'))
  temporaryRoots.push(temporary)
  const runtime = join(temporary, 'runtime')
  const plugin = join(temporary, 'vision-image-model')
  mkdirSync(join(runtime, 'node_modules'), { recursive: true })
  writeFileSync(join(runtime, 'package.json'), '{"name":"runtime","dependencies":{}}\n')
  cpSync(source, plugin, { recursive: true })
  return { runtime, plugin }
}

function install(runtime: string, plugin: string) {
  return spawnSync('python3', [installer, runtime, plugin, 'test'], { encoding: 'utf8' })
}

afterEach(() => {
  for (const temporary of temporaryRoots.splice(0)) rmSync(temporary, { recursive: true, force: true })
})

describe('desktop vision plugin installer', () => {
  it('copies the runtime files under a fixed package alias', () => {
    const { runtime, plugin } = fixture()

    execFileSync('python3', [installer, runtime, plugin, 'test'])

    const target = join(runtime, 'node_modules/dsh-vision-image-model-bundled')
    const bundledManifest = JSON.parse(readFileSync(join(target, 'package.json'), 'utf8')) as { name?: unknown }
    expect(bundledManifest.name).toBe('dsh-vision-image-model-bundled')
    expect(existsSync(join(target, 'dsh/local-image.js'))).toBe(true)
    expect(existsSync(join(target, 'test'))).toBe(false)
    expect(existsSync(join(target, 'stage-profile.sh'))).toBe(false)
    const runtimeManifest = JSON.parse(readFileSync(join(runtime, 'package.json'), 'utf8')) as {
      dependencies: Record<string, unknown>
    }
    expect(runtimeManifest.dependencies['dsh-vision-image-model-bundled'])
      .toBe('file:node_modules/dsh-vision-image-model-bundled')
  })

  it('rejects an existing alias instead of overwriting it', () => {
    const { runtime, plugin } = fixture()
    mkdirSync(join(runtime, 'node_modules/dsh-vision-image-model-bundled'))

    const result = install(runtime, plugin)

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('test build: refusing to overwrite bundled vision plugin')
  })

  it('rejects a conflicting dependency declaration', () => {
    const { runtime, plugin } = fixture()
    writeFileSync(join(runtime, 'package.json'), JSON.stringify({
      name: 'runtime',
      dependencies: { 'dsh-vision-image-model-bundled': '9.9.9' },
    }))

    const result = install(runtime, plugin)

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('test build: runtime declares unexpected bundled vision alias 9.9.9')
  })

  it('rejects source symlinks', () => {
    const { runtime, plugin } = fixture()
    writeFileSync(join(plugin, 'target.js'), 'export {}\n')
    symlinkSync('target.js', join(plugin, 'linked.js'))

    const result = install(runtime, plugin)

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('test build: vision-image-model source contains symlinks: linked.js')
  })
})
