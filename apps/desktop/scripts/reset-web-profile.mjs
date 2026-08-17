#!/usr/bin/env node
/**
 * Back up the mutable Web profile so the next Harness launch initializes a clean one.
 * Session storage, settings, credentials, and user agent presets live outside this directory.
 */

import { existsSync, mkdirSync, renameSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

function dshHome() {
  return resolve(process.env.DSH_HOME ?? join(homedir(), '.dsh'))
}

function backupName(date) {
  return date.toISOString().replace(/[:.]/g, '-').replace('T', '_').replace('Z', '')
}

export function resetWebProfile(home = dshHome(), now = new Date()) {
  const profile = join(home, 'profiles', 'web')
  if (!existsSync(profile)) return { changed: false, profile, backup: null }
  const backups = join(home, 'profile-backups')
  mkdirSync(backups, { recursive: true })
  const stem = `web-${backupName(now)}`
  let backup = join(backups, stem)
  for (let suffix = 2; existsSync(backup); suffix++) backup = join(backups, `${stem}-${suffix}`)
  renameSync(profile, backup)
  return { changed: true, profile, backup }
}

if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.stdout.write(`${JSON.stringify(resetWebProfile())}\n`)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    process.stderr.write(`Unable to back up the Web profile: ${message}\n`)
    process.exitCode = 1
  }
}
