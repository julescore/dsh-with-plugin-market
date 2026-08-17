import { cp, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

const roots: string[] = []

type InstallResult = {
  exitCode: number | null
  timedOut: boolean
  stdout: string
  stderr: string
}

type ProfileSnapshot = {
  profile: string
  files: Record<'package.json' | 'pnpm-lock.yaml' | 'pnpm-workspace.yaml', string | null>
}

type RollbackResult = {
  ok: boolean
  install: InstallResult
  validation: InstallResult
}

type ProfileMutationResult = {
  ok: boolean
  error: string | null
  validation: InstallResult | null
  rollback: RollbackResult | null
}

type TransactionModule = {
  captureProfile(profile: string): ProfileSnapshot
  rollbackProfile(
    run: (profile: string, args: string[]) => Promise<InstallResult>,
    snapshot: ProfileSnapshot,
    validate?: (profile: string) => Promise<InstallResult>,
  ): Promise<RollbackResult>
  validateProfileMutation(
    run: (profile: string, args: string[]) => Promise<InstallResult>,
    snapshot: ProfileSnapshot,
    kind: 'install' | 'update',
    mutationSucceeded: boolean,
    validate?: (profile: string) => Promise<InstallResult>,
  ): Promise<ProfileMutationResult>
}
afterEach(async () => {
  vi.unstubAllEnvs()
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

async function loadTransaction(home: string) {
  const modules = await mkdtemp(join(tmpdir(), 'dsh-profile-transaction-modules-'))
  roots.push(modules)
  await cp(join(process.cwd(), 'apps/desktop/resources/profile-transaction.js'), join(modules, 'profile-transaction.js'))
  await writeFile(join(modules, 'package.json'), '{"type":"module"}\n')
  await writeFile(join(modules, 'dsh-cli.js'), [
    'export function dshArgv() { throw new Error("not used by rollback test") }',
    'export function killChild() {}',
    '',
  ].join('\n'))
  await writeFile(join(modules, 'profile.js'), [
    "import { join } from 'node:path';",
    `export function profileDir(profile) { return join(${JSON.stringify(home)}, 'profiles', profile) }`,
    '',
  ].join('\n'))
  const loaded: unknown = await import(`${pathToFileURL(join(modules, 'profile-transaction.js')).href}?test=${Date.now()}`)
  return loaded as TransactionModule
}

function result(exitCode = 0, stderr = '') {
  return { exitCode, timedOut: false, stdout: '', stderr }
}

describe('bundled market profile transaction', () => {
  it('restores manifest, lockfile, and build policy before offline materialization', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-transaction-home-'))
    roots.push(home)
    const profile = join(home, 'profiles', 'web')
    await mkdir(profile, { recursive: true })
    const original = {
      'package.json': '{"dependencies":{"good":"1.0.0"}}\n',
      'pnpm-lock.yaml': 'lockfileVersion: 9\n',
      'pnpm-workspace.yaml': 'allowBuilds:\n  good: false\n',
    }
    for (const [name, content] of Object.entries(original)) await writeFile(join(profile, name), content)
    const transaction = await loadTransaction(home)
    const snapshot = transaction.captureProfile('web')
    for (const name of Object.keys(original)) await writeFile(join(profile, name), `broken ${name}\n`)
    const run = vi.fn(async () => result())
    const validate = vi.fn(async () => result())

    const rolledBack = await transaction.rollbackProfile(run, snapshot, validate)

    expect(rolledBack.ok).toBe(true)
    expect(run).toHaveBeenCalledWith('web', ['install', '--offline', '--frozen-lockfile'])
    expect(validate).toHaveBeenCalledWith('web')
    for (const [name, content] of Object.entries(original)) {
      expect(await readFile(join(profile, name), 'utf8')).toBe(content)
    }
  })

  it('rolls back a duplicate agent-presets entry and preserves its diagnostic', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-transaction-duplicate-id-'))
    roots.push(home)
    const profile = join(home, 'profiles', 'web')
    await mkdir(profile, { recursive: true })
    const manifest = '{"dependencies":{"good":"1.0.0"}}\n'
    await writeFile(join(profile, 'package.json'), manifest)
    await writeFile(join(profile, 'pnpm-lock.yaml'), 'lockfileVersion: 9\n')
    const transaction = await loadTransaction(home)
    const snapshot = transaction.captureProfile('web')
    await writeFile(join(profile, 'package.json'), '{"dependencies":{"conflicting":"0.6.1"}}\n')
    const conflict = 'TypeError: duplicate loader entry id: agent-presets'
    const validate = vi.fn()
      .mockResolvedValueOnce(result(1, conflict))
      .mockResolvedValueOnce(result())
    const run = vi.fn(async () => result())

    const outcome = await transaction.validateProfileMutation(run, snapshot, 'install', true, validate)

    expect(outcome.ok).toBe(false)
    expect(outcome.error).toContain('duplicate loader entry id: agent-presets')
    expect(outcome.error).toContain('installation was rolled back')
    expect(outcome.rollback?.ok).toBe(true)
    expect(await readFile(join(profile, 'package.json'), 'utf8')).toBe(manifest)
    expect(run).toHaveBeenCalledWith('web', ['install', '--offline', '--frozen-lockfile'])
    expect(validate).toHaveBeenCalledTimes(2)
    expect(validate).toHaveBeenLastCalledWith('web')
  })

  it('rolls back without composing the mutated profile after an install exception', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-transaction-exception-'))
    roots.push(home)
    const profile = join(home, 'profiles', 'web')
    await mkdir(profile, { recursive: true })
    await writeFile(join(profile, 'package.json'), '{}\n')
    const transaction = await loadTransaction(home)
    const snapshot = transaction.captureProfile('web')
    await writeFile(join(profile, 'package.json'), '{"partial":true}\n')
    const run = vi.fn(async () => result())
    const validate = vi.fn(async () => result())

    const outcome = await transaction.validateProfileMutation(run, snapshot, 'install', false, validate)

    expect(outcome.ok).toBe(false)
    expect(outcome.rollback?.ok).toBe(true)
    expect(outcome.validation).toBeNull()
    expect(await readFile(join(profile, 'package.json'), 'utf8')).toBe('{}\n')
    expect(validate).toHaveBeenCalledOnce()
  })

  it('reports an incomplete rollback when restored composition still fails', async () => {
    const home = await mkdtemp(join(tmpdir(), 'dsh-profile-transaction-failure-'))
    roots.push(home)
    const profile = join(home, 'profiles', 'web')
    await mkdir(profile, { recursive: true })
    await writeFile(join(profile, 'package.json'), '{}\n')
    const transaction = await loadTransaction(home)
    const snapshot = transaction.captureProfile('web')
    const run = vi.fn(async () => result())
    const validate = vi.fn(async () => result(1))

    const rolledBack = await transaction.rollbackProfile(run, snapshot, validate)

    expect(rolledBack.ok).toBe(false)
    expect(run).not.toHaveBeenCalled()
  })
})
