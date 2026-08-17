export interface WebPluginCandidate {
  name: string
  spec: string
  signals: string[]
}

export interface WebPluginDiagnosis {
  profileExists: boolean
  manifestValid: boolean
  candidates: WebPluginCandidate[]
}

/**
 * Diagnose which installed Web-profile plugins a startup failure implicates.
 * Candidates carry structured match signals, never a bare substring match.
 */
export function diagnoseWebPlugins(home?: string, failureText?: string): WebPluginDiagnosis
