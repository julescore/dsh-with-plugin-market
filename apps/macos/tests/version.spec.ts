import { describe, expect, it } from 'vitest'
import {
  bumpMacOSVersion,
  parseMacOSVersionManifest,
  setMacOSVersion,
} from '../scripts/version.ts'

describe('macOS application versioning', () => {
  it('validates the persisted manifest', () => {
    expect(parseMacOSVersionManifest({ version: '1.2.3-rc.4', build: 9 })).toEqual({
      version: '1.2.3-rc.4',
      build: 9,
    })
    expect(() => parseMacOSVersionManifest({ version: '1.2', build: 9 })).toThrow(/X\.Y\.Z/)
    expect(() => parseMacOSVersionManifest({ version: '1.2.3-rc.0', build: 9 })).toThrow(/X\.Y\.Z/)
    expect(() => parseMacOSVersionManifest({ version: '1.2.3', build: 0 })).toThrow(/positive safe integer/)
  })

  it('advances release candidates by default', () => {
    expect(bumpMacOSVersion({ version: '0.1.0-rc.5', build: 5 }, 'rc')).toEqual({
      version: '0.1.0-rc.6',
      build: 6,
    })
    expect(bumpMacOSVersion({ version: '0.1.0', build: 6 }, 'rc')).toEqual({
      version: '0.1.1-rc.1',
      build: 7,
    })
  })

  it('supports stable and semantic release transitions', () => {
    const current = { version: '1.2.3-rc.4', build: 20 }
    expect(bumpMacOSVersion(current, 'release')).toEqual({ version: '1.2.3', build: 21 })
    expect(bumpMacOSVersion(current, 'patch')).toEqual({ version: '1.2.4', build: 21 })
    expect(bumpMacOSVersion(current, 'minor')).toEqual({ version: '1.3.0', build: 21 })
    expect(bumpMacOSVersion(current, 'major')).toEqual({ version: '2.0.0', build: 21 })
  })

  it('requires explicit versions to move forward', () => {
    const current = { version: '1.2.3-rc.4', build: 20 }
    expect(setMacOSVersion(current, '1.2.3')).toEqual({ version: '1.2.3', build: 21 })
    expect(() => setMacOSVersion(current, '1.2.3-rc.3')).toThrow(/must be greater/)
    expect(() => setMacOSVersion({ version: '1.2.3', build: 21 }, '1.2.3-rc.5')).toThrow(/must be greater/)
  })

  it('rejects releasing an already stable version', () => {
    expect(() => bumpMacOSVersion({ version: '1.2.3', build: 21 }, 'release')).toThrow(/already stable/)
  })
})
