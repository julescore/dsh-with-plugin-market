/** Reads, validates, and advances the shared desktop application version. */

import { readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

/** Version changes supported by the desktop packaging command. */
export type DesktopVersionBump = 'rc' | 'release' | 'patch' | 'minor' | 'major'

/** Persisted desktop marketing and monotonically increasing build versions. */
export interface DesktopVersionManifest {
  readonly version: string
  readonly build: number
}

interface ParsedVersion {
  readonly major: number
  readonly minor: number
  readonly patch: number
  readonly rc?: number
}

const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc\.([1-9]\d*))?$/
const manifestPath = fileURLToPath(new URL('../version.json', import.meta.url))

function parseVersion(value: string): ParsedVersion {
  const match = VERSION_PATTERN.exec(value)
  if (match === null) {
    throw new Error(`desktop version must be X.Y.Z or X.Y.Z-rc.N, got ${JSON.stringify(value)}`)
  }
  const [, major, minor, patch, rc] = match
  return {
    major: Number(major),
    minor: Number(minor),
    patch: Number(patch),
    ...(rc === undefined ? {} : { rc: Number(rc) }),
  }
}

function formatVersion(value: ParsedVersion): string {
  const stable = `${value.major}.${value.minor}.${value.patch}`
  return value.rc === undefined ? stable : `${stable}-rc.${value.rc}`
}

function compareVersions(left: ParsedVersion, right: ParsedVersion): number {
  for (const key of ['major', 'minor', 'patch'] as const) {
    if (left[key] !== right[key]) return left[key] - right[key]
  }
  if (left.rc === undefined) return right.rc === undefined ? 0 : 1
  if (right.rc === undefined) return -1
  return left.rc - right.rc
}

/**
 * Validate a decoded desktop version manifest.
 * @param input - JSON-decoded manifest value.
 * @returns The validated version and build number.
 */
export function parseDesktopVersionManifest(input: unknown): DesktopVersionManifest {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) {
    throw new Error('desktop version manifest must be an object')
  }
  const candidate = input as Record<string, unknown>
  if (typeof candidate.version !== 'string') throw new Error('desktop version manifest.version must be a string')
  parseVersion(candidate.version)
  if (!Number.isSafeInteger(candidate.build) || (candidate.build as number) < 1) {
    throw new Error('desktop version manifest.build must be a positive safe integer')
  }
  return { version: candidate.version, build: candidate.build as number }
}

/**
 * Compute a conventional next desktop version and increment the build number.
 * @param current - Current desktop version manifest.
 * @param bump - Requested release transition.
 * @returns The next manifest.
 */
export function bumpDesktopVersion(
  current: DesktopVersionManifest,
  bump: DesktopVersionBump,
): DesktopVersionManifest {
  const parsed = parseVersion(current.version)
  let next: ParsedVersion
  switch (bump) {
    case 'rc':
      next = parsed.rc === undefined
        ? { major: parsed.major, minor: parsed.minor, patch: parsed.patch + 1, rc: 1 }
        : { ...parsed, rc: parsed.rc + 1 }
      break
    case 'release':
      if (parsed.rc === undefined) throw new Error(`desktop version ${current.version} is already stable`)
      next = { major: parsed.major, minor: parsed.minor, patch: parsed.patch }
      break
    case 'patch':
      next = { major: parsed.major, minor: parsed.minor, patch: parsed.patch + 1 }
      break
    case 'minor':
      next = { major: parsed.major, minor: parsed.minor + 1, patch: 0 }
      break
    case 'major':
      next = { major: parsed.major + 1, minor: 0, patch: 0 }
      break
    default:
      return assertNever(bump)
  }
  return { version: formatVersion(next), build: current.build + 1 }
}

/**
 * Set an explicit higher desktop version and increment the build number.
 * @param current - Current desktop version manifest.
 * @param target - Explicit target marketing version.
 * @returns The next manifest.
 */
export function setDesktopVersion(
  current: DesktopVersionManifest,
  target: string,
): DesktopVersionManifest {
  const parsedCurrent = parseVersion(current.version)
  const parsedTarget = parseVersion(target)
  if (compareVersions(parsedTarget, parsedCurrent) <= 0) {
    throw new Error(`desktop target version ${target} must be greater than ${current.version}`)
  }
  return { version: formatVersion(parsedTarget), build: current.build + 1 }
}

function assertNever(value: never): never {
  throw new Error(`unsupported desktop version bump: ${String(value)}`)
}

function readManifest(): DesktopVersionManifest {
  return parseDesktopVersionManifest(JSON.parse(readFileSync(manifestPath, 'utf8')) as unknown)
}

function writeManifest(manifest: DesktopVersionManifest): void {
  writeFileSync(manifestPath, `${JSON.stringify(manifest, undefined, 2)}\n`)
}

function usage(): never {
  throw new Error('usage: version.ts show <version|bundle-version|build> | bump [--bump rc|release|patch|minor|major | --version X.Y.Z[-rc.N]]')
}

function main(args: readonly string[]): void {
  const [command, ...rest] = args
  const current = readManifest()
  if (command === 'show') {
    const [field] = rest
    if (rest.length !== 1 || (field !== 'version' && field !== 'bundle-version' && field !== 'build')) usage()
    const parsed = parseVersion(current.version)
    const value = field === 'bundle-version'
      ? formatVersion({ major: parsed.major, minor: parsed.minor, patch: parsed.patch })
      : current[field]
    process.stdout.write(`${String(value)}\n`)
    return
  }
  if (command !== 'bump') usage()

  let next: DesktopVersionManifest
  if (rest.length === 0) {
    next = bumpDesktopVersion(current, 'rc')
  } else if (rest.length === 2 && rest[0] === '--bump'
    && ['rc', 'release', 'patch', 'minor', 'major'].includes(rest[1] ?? '')) {
    next = bumpDesktopVersion(current, rest[1] as DesktopVersionBump)
  } else if (rest.length === 2 && rest[0] === '--version' && rest[1] !== undefined) {
    next = setDesktopVersion(current, rest[1])
  } else {
    usage()
  }
  writeManifest(next)
  process.stdout.write(`desktop version: ${current.version} (${current.build}) -> ${next.version} (${next.build})\n`)
}

const invoked = process.argv[1]
if (invoked !== undefined && realpathSync(invoked) === realpathSync(fileURLToPath(import.meta.url))) {
  main(process.argv.slice(2))
}
