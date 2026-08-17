import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'

const desktopDir = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const installer = join(desktopDir, 'scripts/install-agent-presets.py')
const temporaryRoots: string[] = []

function fixture(): { desktop: string; runtime: string } {
  const root = mkdtempSync(join(tmpdir(), 'dsh-desktop-presets-'))
  temporaryRoots.push(root)
  const desktop = join(root, 'desktop')
  const runtime = join(root, 'runtime')
  cpSync(join(desktopDir, 'resources'), join(desktop, 'resources'), { recursive: true })
  mkdirSync(join(runtime, 'config/agent-presets/standard'), { recursive: true })
  writeFileSync(join(runtime, 'config/agent-presets/standard/agent.cordis.yml'), '- id: standard\n')
  return { desktop, runtime }
}

function install(runtime: string, desktop: string) {
  return spawnSync('python3', [installer, runtime, desktop, 'test'], { encoding: 'utf8' })
}

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('desktop community preset installer', () => {
  it('copies every checksum-pinned preset into the system preset root', () => {
    const { desktop, runtime } = fixture()

    execFileSync('python3', [installer, runtime, desktop, 'test'])

    expect(readFileSync(join(runtime, 'config/agent-presets/anchored-standard/preset.yml'), 'utf8'))
      .toContain('name: Anchored Standard (experimental)')
    expect(readFileSync(join(runtime, 'config/agent-presets/zero-anchored-standard/preset.yml'), 'utf8'))
      .toContain('name: Zero-Anchored Standard (experimental)')
  })

  it('rejects source checksum drift', () => {
    const { desktop, runtime } = fixture()
    const source = join(desktop, 'resources/agent-presets/anchored-standard/preset.yml')
    writeFileSync(source, `${readFileSync(source, 'utf8')}# modified\n`)

    const result = install(runtime, desktop)

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('test build: anchored-standard checksum mismatch for preset.yml')
  })

  it('refuses to overwrite a shipped preset id', () => {
    const { desktop, runtime } = fixture()
    mkdirSync(join(runtime, 'config/agent-presets/anchored-standard'))

    const result = install(runtime, desktop)

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('test build: refusing to overwrite shipped preset anchored-standard')
  })
})
