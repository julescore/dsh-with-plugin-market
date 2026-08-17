// Pure prompt-image admission helpers. No @deepseek-ai imports.

/** Render one normalized image reading as durable model-facing text. */
export function recognitionText(result, selection, index) {
  return [
    `[Image ${index} read by ${selection.provider}/${selection.model}]`,
    `Summary: ${result.summary}`,
    `OCR text: ${result.ocrText}`,
    `Layout: ${JSON.stringify(result.layout)}`,
    `Uncertain: ${JSON.stringify(result.uncertain)}`,
  ].join('\n')
}

/**
 * Replace ordered image blocks with text returned by one image-reader call.
 * @param admission - Durable prompt blocks and optional cancellation.
 * @param selection - Exact image-model route.
 * @param recognize - One-image async reader.
 * @returns transformed admission decision with no image blocks.
 */
export async function transformPromptImages(admission, selection, recognize) {
  const focus = admission.content
    .filter((block) => block?.type === 'text')
    .map((block) => String(block.text ?? ''))
    .join('\n')
    .trim()
  let imageIndex = 0
  const transformed = []
  for (const block of admission.content) {
    if (block?.type !== 'image') {
      transformed.push(block)
      continue
    }
    imageIndex += 1
    const result = await recognize(block.attachment, focus, admission.signal, imageIndex)
    transformed.push({ type: 'text', text: recognitionText(result, selection, imageIndex) })
  }
  return { kind: 'transformed', content: transformed }
}
