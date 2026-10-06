// Loads a QML JavaScript library (".pragma library" + plain functions) in
// node. The pragma is QML-only syntax; everything after it is ordinary JS
// that exports through `module.exports` when `module` exists.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { dirname, join } from "node:path"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")

export function loadQmlJs(relativePath) {
  const source = readFileSync(join(root, relativePath), "utf8").replace(/^\.pragma library\s*$/m, "")
  const module = { exports: {} }
  new Function("module", source)(module)
  return module.exports
}
