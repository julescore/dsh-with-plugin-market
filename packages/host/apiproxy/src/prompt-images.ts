/** Host extension point for turning uploaded images into text before prompt admission. */

import type { ImageAttachmentRef } from '@deepseek-ai/dsh-attachment'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { SessionId } from '@deepseek-ai/dsh-session'

/** One durable image prompt awaiting either native admission or plugin transformation. */
export interface PromptImageAdmission {
  /** Session receiving the prompt. */
  sessionId: SessionId
  /** Original ordered prompt blocks after image validation and durable storage. */
  content: readonly ContentBlock[]
  /** Image references from {@link content}, in prompt order. */
  images: readonly ImageAttachmentRef[]
  /** Transport cancellation for auxiliary image-model work. */
  signal?: AbortSignal
}

/** Image-free model content returned by a prepared prompt-image transformer. */
export interface PromptImageAdmissionDecision {
  readonly kind: 'transformed'
  /** Pure model-facing content replacing the original image-bearing prompt. */
  readonly content: readonly ContentBlock[]
}

/** One per-prompt transformer with its image-model selection captured at preparation time. */
export type PromptImageTransformer = (
  admission: PromptImageAdmission,
) => Promise<PromptImageAdmissionDecision>

declare module '@deepseek-ai/cordis' {
  interface Events {
    /**
     * Prepare an image transformer under the listener's current configuration.
     * The returned function captures one fixed image-model route for the whole
     * prompt; no return preserves native multimodal admission and capability
     * preflight.
     * @mode bail
     */
    'session/prompt-images/available'(): PromptImageTransformer | void
  }
}
