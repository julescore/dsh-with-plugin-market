export interface WebProfileRecoveryResult {
  changed: boolean
  profile: string
  backup: string | null
}

/** Move the mutable Web profile to a timestamped backup. */
export function resetWebProfile(home?: string, now?: Date): WebProfileRecoveryResult
