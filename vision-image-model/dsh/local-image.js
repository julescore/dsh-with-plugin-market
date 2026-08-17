// Local image admission for vision-image-model. The caller supplies the DSH
// filesystem context and tool execution so reads use the session workspace,
// provider size enforcement, cancellation, and the shared observation stream.

/** Return the calling session's workspace when one is available. */
function sessionCwd(exec) {
  return exec?.agent?.session?.header?.cwd
}

/**
 * Read one regular local file through the DSH filesystem service.
 * @param ctx - plugin context providing ctx.fs and fs/observed.
 * @param source - model-supplied local path.
 * @param exec - current tool execution context.
 * @param maxBytes - complete encoded-image byte limit.
 * @returns the resolved target, stat result, and bounded bytes.
 */
export async function readLocalImage(ctx, source, exec, maxBytes) {
  if (/^[a-z][a-z\d+.-]*:\/\//i.test(source)) {
    throw new Error('vision_read_image accepts local image paths only; download remote images with an approved network tool first')
  }
  const cwd = sessionCwd(exec)
  const target = await ctx.fs.resolve(source, {
    ...(cwd === undefined ? {} : { cwd }),
    signal: exec.signal,
  })
  const info = await ctx.fs.stat(target, exec.signal)
  if (info === undefined) {
    ctx.emit('fs/observed', target, { kind: 'absent' }, exec)
    throw new Error(`cannot read "${target.displayPath}": not found`)
  }
  if (info.type !== 'file') {
    throw new Error(`cannot read "${target.displayPath}": not a regular file`)
  }
  const data = await ctx.fs.readBytes(target, exec.signal, maxBytes)
  ctx.emit('fs/observed', target, { kind: 'present', version: info.version }, exec)
  return { target, info, data }
}
