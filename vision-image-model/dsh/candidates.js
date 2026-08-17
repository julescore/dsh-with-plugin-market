// Pure candidate-enumeration logic for the vision-image-model plugin.
// No @deepseek-ai imports: this module is unit-testable with plain Node and
// duck-types the two services it reads (`llm`, optional `settings`).
//
// The rule for "already configured models" is:
//   - every ACTIVE provider route is configured by construction (an adapter
//     mounted it), so it appears with its model catalog;
//   - a configurable-provider directory entry that resolves a profile in the
//     settings document but is not active (missing credential, disabled
//     route) still appears, with no models, so the settings card can say why
//     it cannot be picked.
// Directory entries that resolve no profile are omitted entirely.

/** Read one path from a nested plain object/array; undefined when absent. */
export function getPath(value, path) {
  let current = value
  for (const segment of path) {
    if (typeof current !== 'object' || current === null) return undefined
    current = current[segment]
  }
  return current
}

/** One model row the settings card renders. */
function modelView(model) {
  const modalities = Array.isArray(model.inputModalities) ? model.inputModalities : undefined
  return {
    id: String(model.id),
    name: String(model.name ?? model.id),
    ...(typeof model.description === 'string' && model.description.length > 0
      ? { description: model.description }
      : {}),
    // true = positively declares image input; false = positively text-only;
    // undefined = the adapter says nothing, which is never selectable.
    ...(modalities === undefined ? {} : { imageInput: modalities.includes('image') }),
  }
}

/** One provider group the settings card renders. */
function groupView(provider, name, active, models, error, configured) {
  return {
    provider,
    name,
    active,
    configured: configured === true,
    models,
    ...(error === undefined ? {} : { error }),
  }
}

/**
 * Enumerate candidate image models.
 * @param llm - duck-typed `ctx.llm` (listProviders/listModels/listConfigurableProviders).
 * @param settings - optional duck-typed `ctx.settings` (describe).
 * @returns provider groups in active-first, declaration-order; each model row
 *   carries `imageInput` true/false/absent.
 */
export async function describeImageModelCandidates(llm, settings) {
  const groups = new Map()
  const seen = new Set()

  // Pass 1: active routes — these are the selectable ones.
  if (llm && typeof llm.listProviders === 'function') {
    for (const info of llm.listProviders()) {
      const provider = info && typeof info.id === 'string' ? info.id : ''
      if (provider === '' || seen.has(provider)) continue
      seen.add(provider)
      const base = { provider, name: String(info?.name ?? provider), active: true, configured: true, models: [] }
      groups.set(provider, base)
      if (typeof llm.listModels !== 'function') {
        base.error = 'the llm service cannot list models'
        continue
      }
      try {
        base.models = (await llm.listModels(provider)).map(modelView)
      } catch (error) {
        base.error = error instanceof Error ? error.message : String(error)
      }
    }
  }

  // Pass 2: configured but inactive directory entries, so the card explains
  // why a provider configured on the Models page offers no models here.
  const directory = llm && typeof llm.listConfigurableProviders === 'function'
    ? llm.listConfigurableProviders()
    : []
  let descriptors = []
  if (settings && typeof settings.describe === 'function') {
    try {
      // Redact so this enumeration never holds secret field values in memory
      // beyond the settings service itself.
      descriptors = settings.describe({ redactSecrets: true }) ?? []
    } catch {
      descriptors = []
    }
  }
  const namespaces = new Map(descriptors.map((descriptor) => [descriptor.ns, descriptor]))
  for (const entry of directory) {
    if (!entry || typeof entry.provider !== 'string' || entry.provider === '') continue
    if (seen.has(entry.provider)) continue
    const namespace = namespaces.get(entry.settingsNs)
    const path = Array.isArray(entry.settingsPath) ? entry.settingsPath : []
    const configured = namespace !== undefined
      && (path.length === 0 || getPath(namespace.value, path) !== undefined)
    if (!configured) continue
    seen.add(entry.provider)
    groups.set(entry.provider, groupView(
      entry.provider,
      entry.displayName ?? entry.provider,
      false,
      [],
      'configured on the Models page but not active (missing credential or disabled route)',
      true,
    ))
  }

  return [...groups.values()]
}
