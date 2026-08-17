// Pure vision helpers for the vision-image-model plugin: image-byte sniffing,
// the vision prompt, and the JSON answer contract. No @deepseek-ai imports.

/** Image media types the dsh attachment store accepts. */
export const ACCEPTED_MEDIA_TYPES = ['image/png', 'image/jpeg', 'image/webp', 'image/gif']

/** Hard cap for one image read, matching the size class modlens uses. */
export const MAX_IMAGE_BYTES = 25 * 1024 * 1024

const SNIFFERS = [
  {
    mediaType: 'image/png',
    test: (b) => b.length >= 8
      && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47
      && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a,
  },
  {
    mediaType: 'image/jpeg',
    test: (b) => b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  },
  {
    mediaType: 'image/gif',
    test: (b) => b.length >= 6 && (b.toString('ascii', 0, 6) === 'GIF87a' || b.toString('ascii', 0, 6) === 'GIF89a'),
  },
  {
    mediaType: 'image/webp',
    test: (b) => b.length >= 12
      && b.toString('ascii', 0, 4) === 'RIFF'
      && b.toString('ascii', 8, 12) === 'WEBP',
  },
]

/**
 * Decide the media type from bytes alone. Only the four types the dsh
 * attachment store accepts are recognized; anything else is refused before a
 * byte reaches the model.
 * @param buffer - encoded image bytes.
 * @returns an ACCEPTED_MEDIA_TYPES member, or undefined.
 */
export function sniffImageMediaType(buffer) {
  for (const sniffer of SNIFFERS) {
    if (sniffer.test(buffer)) return sniffer.mediaType
  }
  return undefined
}

/** The system prompt carrying the JSON answer contract. */
export function visionSystemPrompt(focus) {
  const focusLine = typeof focus === 'string' && focus.trim() !== ''
    ? `\nExtra focus requested by the caller: ${focus.trim()}`
    : ''
  return [
    'You are a vision evidence engine. Read the attached image and return ONLY one JSON object, no prose, no markdown fences.',
    'The JSON object must have exactly these fields:',
    '  "summary": one short factual sentence about the image as a whole.',
    '  "ocrText": every readable text in the image, verbatim, preserving reading order; use empty string when there is none.',
    '  "layout": an array of { "label": string, "text": string } describing regions in reading order (table, header, chart axis, caption, ...).',
    '  "uncertain": an array of strings, one per detail you could not read confidently.',
    'Do not invent text. Quote the image only.',
    focusLine,
  ].filter((line) => line !== '').join('\n')
}

/**
 * Extract a JSON object from raw model output (fences and surrounding prose
 * tolerated), or throw with the reason.
 * @param text - accumulated model text.
 * @returns the parsed object.
 */
export function parseVisionJson(text) {
  const cleaned = String(text ?? '').trim()
  if (cleaned === '') throw new Error('the image model returned empty text')
  const fenced = cleaned.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '')
  const start = fenced.indexOf('{')
  const end = fenced.lastIndexOf('}')
  if (start < 0 || end <= start) {
    throw new Error('the image model returned no JSON object')
  }
  let parsed
  try {
    parsed = JSON.parse(fenced.slice(start, end + 1))
  } catch (error) {
    throw new Error(`the image model returned invalid JSON: ${error instanceof Error ? error.message : String(error)}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('the image model returned JSON that is not an object')
  }
  return parsed
}

/**
 * Normalize a parsed answer to the tool's output contract. Missing fields
 * become empty values so the model always receives a complete object.
 * @param value - the parsed JSON object.
 * @returns the contract-shaped result.
 */
export function normalizeVisionResult(value) {
  const layout = Array.isArray(value.layout)
    ? value.layout
      .filter((entry) => entry !== null && typeof entry === 'object')
      .map((entry) => ({
        label: typeof entry.label === 'string' ? entry.label : '',
        text: typeof entry.text === 'string' ? entry.text : '',
      }))
      .filter((entry) => entry.label !== '' || entry.text !== '')
    : []
  const uncertain = Array.isArray(value.uncertain)
    ? value.uncertain.filter((entry) => typeof entry === 'string').slice(0, 20)
    : []
  return {
    summary: typeof value.summary === 'string' ? value.summary : '',
    ocrText: typeof value.ocrText === 'string' ? value.ocrText : '',
    layout,
    uncertain,
  }
}
