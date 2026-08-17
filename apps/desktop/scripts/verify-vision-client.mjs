#!/usr/bin/env node
/** Execute one prebundled vision client and verify its module-loader handoff. */

import { readFile } from 'node:fs/promises'
import vm from 'node:vm'

const [clientPath, expectedId] = process.argv.slice(2)
if (!clientPath || !expectedId) {
  throw new Error('usage: verify-vision-client.mjs CLIENT_PATH EXPECTED_ID')
}

const handoffs = []
const context = vm.createContext({
  window: {
    __ModuleLoader__: {
      load(handoff) {
        handoffs.push(handoff)
      },
    },
  },
})
const source = await readFile(clientPath, 'utf8')
new vm.Script(source, { filename: clientPath }).runInContext(context)
if (handoffs.length !== 1) {
  throw new Error(`vision client registered ${handoffs.length} module handoffs; expected exactly one`)
}
const [handoff] = handoffs
if (handoff?.id !== expectedId) {
  throw new Error(`vision client registered ${JSON.stringify(handoff?.id)}; expected ${JSON.stringify(expectedId)}`)
}
if (typeof handoff.factory !== 'function') {
  throw new Error('vision client handoff has no factory')
}
process.stdout.write(`vision client handoff verified: ${expectedId}\n`)
