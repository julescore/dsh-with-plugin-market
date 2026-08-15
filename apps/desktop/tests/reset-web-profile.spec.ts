import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { resetWebProfile } from '../scripts/reset-web-profile.mjs'

const roots: string[] = []
afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('Web profile recovery', () => {
  it('moves only the Web profile into a timestamped backup', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-recovery-'))
    roots.push(home)
    const web = join(home, 'profiles', 'web')
    mkdirSync(web, { recursive: true })
    writeFileSync(join(web, 'package.json'), '{"broken":true}\n')
    writeFileSync(join(home, 'settings.yaml'), 'kept: true\n')
    mkdirSync(join(home, 'storages'), { recursive: true })
    writeFileSync(join(home, 'storages', 'sessions.json'), 'kept\n')
    mkdirSync(join(home, '.agent-presets', 'mine'), { recursive: true })
    writeFileSync(join(home, '.agent-presets', 'mine', 'agent.cordis.yml'), 'kept\n')

    const result = resetWebProfile(home, new Date('2026-08-15T01:02:03.004Z'))

    expect(result).toEqual({
      changed: true,
      profile: web,
      backup: join(home, 'profile-backups', 'web-2026-08-15_01-02-03-004'),
    })
    expect(existsSync(web)).toBe(false)
    expect(readFileSync(join(result.backup!, 'package.json'), 'utf8')).toContain('broken')
    expect(readFileSync(join(home, 'settings.yaml'), 'utf8')).toContain('kept')
    expect(readFileSync(join(home, 'storages', 'sessions.json'), 'utf8')).toBe('kept\n')
    expect(readFileSync(join(home, '.agent-presets', 'mine', 'agent.cordis.yml'), 'utf8')).toBe('kept\n')
  })

  it('is a no-op when no Web profile exists', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-recovery-empty-'))
    roots.push(home)
    expect(resetWebProfile(home, new Date('2026-08-15T01:02:03.004Z'))).toEqual({
      changed: false,
      profile: join(home, 'profiles', 'web'),
      backup: null,
    })
  })
})
