#!/usr/bin/env node
/**
 * Map a Harness startup failure to the Web-profile plugin dependencies that
 * can explain it. The desktop shells run this script with the failure text on
 * stdin and read one JSON object from stdout. Only structured diagnostics are
 * matched — Cordis load/activation entries, module-resolution errors, and
 * `node_modules`/`.pnpm` paths — never a bare substring, so an unrelated word
 * in a stack trace cannot nominate a plugin for uninstall.
 */

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

function dshHome() {
  return resolve(process.env.DSH_HOME ?? join(homedir(), '.dsh'))
}

/** The directory `dsh web` boots, mirroring @deepseek-ai/dsh-app-boot. */
function webProfileDir(home) {
  return join(home, 'profiles', 'web')
}

/** The pnpm virtual-store segment for a package name. */
function pnpmPathName(name) {
  return name.replaceAll('/', '+')
}

/** Extract the real package name from an `npm:` alias spec, when present. */
function aliasedPackageName(spec) {
  if (typeof spec !== 'string' || !spec.trim().startsWith('npm:')) return undefined
  const stripped = spec.trim().slice(4)
  const match = /^(?<name>@[^/@]+\/[^/@]+|[^/@]+)/.exec(stripped)
  return match?.groups?.name
}

/** Read the installed package's real name, which pnpm aliases can hide. */
function installedPackageName(profileDir, dependencyName) {
  try {
    const manifest = JSON.parse(readFileSync(join(profileDir, 'node_modules', dependencyName, 'package.json'), 'utf8'))
    return typeof manifest.name === 'string' ? manifest.name : undefined
  } catch {
    return undefined
  }
}

/**
 * Match one dependency against a startup failure using structured signals.
 * @param {string} profileDir - the Web profile directory.
 * @param {string} dependencyName - the package.json dependency key.
 * @param {string} dependencySpec - the dependency's declared spec.
 * @param {string} failure - normalized failure text (forward slashes).
 * @returns {string[]} the signals that nominate this dependency.
 */
function matchDependency(profileDir, dependencyName, dependencySpec, failure) {
  const failureLower = failure.toLowerCase()
  const names = [dependencyName, aliasedPackageName(dependencySpec), installedPackageName(profileDir, dependencyName)]
    .filter(name => typeof name === 'string')
    .map(name => name.toLowerCase())
  const mentioned = (value) => names.some(name => value.includes(name))
  const modulePaths = names.flatMap(name => [
    `/node_modules/${name}/`,
    `.pnpm/${pnpmPathName(name)}@`,
  ])
  const signals = []
  if (modulePaths.some(path => failureLower.includes(path))) {
    signals.push('module path')
  }
  const failedLoad = /plugin\(s\) failed to load:\s*([^\n;]+)/i.exec(failure)
  if (failedLoad !== null) {
    const entries = failedLoad[1].split(',').map(entry => entry.trim().replace(/^['"]|['"]$/g, ''))
    if (entries.some(entry => names.includes(entry.toLowerCase()))) signals.push('failed load entry')
  }
  for (const line of failure.split(/\r?\n/)) {
    const prefix = /^([^:\n]+):(?:\s|$)/.exec(line)
    if (prefix !== null && names.includes(prefix[1].trim().toLowerCase())) {
      signals.push('activation entry')
      break
    }
  }
  for (const match of failure.matchAll(/Cannot find (?:package|module) ['"]([^'"]+)['"]/gi)) {
    if (names.includes(match[1].toLowerCase())) {
      signals.push('unresolved module')
      break
    }
  }
  for (const match of failure.matchAll(/(?:cannot resolve profile bundle|profile bundle) "([^"]+)"/gi)) {
    if (names.includes(match[1].toLowerCase())) {
      signals.push('profile bundle')
      break
    }
  }
  for (const line of failure.split(/\r?\n/)) {
    const subject = /^dsh: \[([^\]]+)\]/.exec(line)
    if (subject !== null && names.includes(subject[1].toLowerCase())) {
      signals.push('patch diagnostic')
      break
    }
  }
  return signals
}

/**
 * Diagnose which installed Web-profile plugins a startup failure implicates.
 * @param {string} [home] - the Harness home directory.
 * @param {string} [failureText] - the startup diagnostic text.
 * @returns {{profileExists: boolean, manifestValid: boolean, candidates: {name: string, spec: string, signals: string[]}[]}}
 *   candidates sorted by their strongest signal, strongest first.
 */
export function diagnoseWebPlugins(home = dshHome(), failureText = '') {
  const profileDir = webProfileDir(home)
  const manifestPath = join(profileDir, 'package.json')
  if (!existsSync(manifestPath)) return { profileExists: false, manifestValid: true, candidates: [] }
  let dependencies
  try {
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    dependencies = manifest !== null && typeof manifest === 'object' && manifest.dependencies !== null
      && typeof manifest.dependencies === 'object' ? manifest.dependencies : {}
  } catch {
    return { profileExists: true, manifestValid: false, candidates: [] }
  }
  const ranks = new Map([
    ['module path', 0],
    ['failed load entry', 1],
    ['profile bundle', 2],
    ['activation entry', 3],
    ['unresolved module', 4],
    ['patch diagnostic', 5],
  ])
  const failure = failureText.replaceAll('\\', '/')
  const candidates = Object.entries(dependencies).flatMap(([name, spec]) => {
    const signals = matchDependency(profileDir, name, spec, failure)
    if (signals.length === 0) return []
    return [{ name, spec, signals }]
  })
  candidates.sort((left, right) => {
    const leftRank = Math.min(...left.signals.map(signal => ranks.get(signal) ?? ranks.size))
    const rightRank = Math.min(...right.signals.map(signal => ranks.get(signal) ?? ranks.size))
    return leftRank - rightRank || left.name.localeCompare(right.name)
  })
  return { profileExists: true, manifestValid: true, candidates }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let failure = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', (chunk) => {
    failure = (failure + chunk).slice(-2 * 1024 * 1024)
  })
  process.stdin.on('end', () => {
    try {
      process.stdout.write(`${JSON.stringify(diagnoseWebPlugins(dshHome(), failure))}\n`)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      process.stderr.write(`Unable to diagnose the Web profile: ${message}\n`)
      process.exitCode = 1
    }
  })
}
