import { mkdirSync, writeFileSync } from 'node:fs'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { diagnoseWebPlugins } from '../scripts/diagnose-web-plugins.mjs'

const roots: string[] = []
let home = ''
let profile = ''

beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), 'dsh-plugin-diagnosis-'))
  roots.push(home)
  profile = join(home, 'profiles', 'web')
  mkdirSync(profile, { recursive: true })
  writeFileSync(join(profile, 'package.json'), JSON.stringify({
    name: 'dsh-profile-web',
    dependencies: {
      '@scope/broken': 'npm:real-broken@1.0.0',
      'plain-broken': '^2.0.0',
      healthy: '^1.0.0',
    },
  }, null, 2))
})

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('Web plugin startup diagnosis', () => {
  it('names the entry Cordis reports in a failed load', () => {
    const result = diagnoseWebPlugins(
      home,
      'dsh: plugin(s) failed to load: @scope/broken; Cordis startup failed because these plugin(s) could not be resolved',
    )

    expect(result).toEqual({
      profileExists: true,
      manifestValid: true,
      candidates: [{ name: '@scope/broken', spec: 'npm:real-broken@1.0.0', signals: ['failed load entry'] }],
    })
  })

  it('names the entry whose activation failed', () => {
    const result = diagnoseWebPlugins(
      home,
      'dsh: 1 entry did not activate\nplain-broken: TypeError: boom\n    at activate',
    )

    expect(result).toEqual({
      profileExists: true,
      manifestValid: true,
      candidates: [{ name: 'plain-broken', spec: '^2.0.0', signals: ['activation entry'] }],
    })
  })

  it('resolves an npm alias from a Cannot-find-package diagnostic', () => {
    const result = diagnoseWebPlugins(
      home,
      "Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'real-broken' imported from /tmp/x",
    )

    expect(result.candidates).toEqual([
      { name: '@scope/broken', spec: 'npm:real-broken@1.0.0', signals: ['unresolved module'] },
    ])
  })

  it('uses the installed package name for an aliased dependency', () => {
    mkdirSync(join(profile, 'node_modules', '@scope', 'broken'), { recursive: true })
    writeFileSync(join(profile, 'node_modules', '@scope', 'broken', 'package.json'), JSON.stringify({
      name: 'actual-broken',
    }))

    const result = diagnoseWebPlugins(
      home,
      "Error [ERR_MODULE_NOT_FOUND]: Cannot find module 'actual-broken' imported from /tmp/x",
    )

    expect(result.candidates).toEqual([
      { name: '@scope/broken', spec: 'npm:real-broken@1.0.0', signals: ['unresolved module'] },
    ])
  })

  it('matches node_modules and pnpm virtual-store paths on Windows-normalized diagnostics', () => {
    const fromHoisted = diagnoseWebPlugins(
      home,
      'file:///C:/Users/u/.dsh/profiles/web/node_modules/plain-broken/dist/index.js:12',
    )
    const fromStore = diagnoseWebPlugins(
      home,
      'file:///C:/Users/u/.dsh/profiles/web/node_modules/.pnpm/@scope+broken@1.0.0/node_modules/@scope/broken/index.js',
    )

    expect(fromHoisted.candidates.map(candidate => candidate.name)).toEqual(['plain-broken'])
    expect(fromStore.candidates.map(candidate => candidate.name)).toEqual(['@scope/broken'])
  })

  it('names the dependency in a profile-bundle diagnostic', () => {
    const result = diagnoseWebPlugins(
      home,
      'dsh: profile bundle "plain-broken" declares no dsh.bundle in its package.json',
    )

    expect(result.candidates).toEqual([
      { name: 'plain-broken', spec: '^2.0.0', signals: ['profile bundle'] },
    ])
  })

  it('sorts the strongest signal first and ignores unrelated dependencies', () => {
    const result = diagnoseWebPlugins(
      home,
      'dsh: 2 entries did not activate\nplain-broken: Error: boom\n' +
        'file:///tmp/profiles/web/node_modules/healthy/dist/index.js',
    )

    expect(result.candidates.map(candidate => candidate.name)).toEqual(['healthy', 'plain-broken'])
  })

  it('returns no candidates when no structured diagnostic names a dependency', () => {
    const result = diagnoseWebPlugins(home, 'dsh: plugin tree failed to load: include: some unrelated row')

    expect(result.candidates).toEqual([])
  })

  it('reports a missing or unparsable profile manifest without throwing', () => {
    expect(diagnoseWebPlugins(join(home, 'empty'), 'anything')).toEqual({
      profileExists: false,
      manifestValid: true,
      candidates: [],
    })
    writeFileSync(join(profile, 'package.json'), '{"broken":')
    expect(diagnoseWebPlugins(home, 'anything')).toEqual({
      profileExists: true,
      manifestValid: false,
      candidates: [],
    })
  })
})
