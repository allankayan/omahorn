import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlJs } from "./load.mjs"

const H = loadQmlJs("lib/Hotkeys.js")

const KEY_1 = 0x31
const KEY_M = 0x4d
const KEY_F5 = 0x01000034
const KEY_F13 = 0x0100003c
const KEY_EXCLAM = 0x21
const KEY_CONTROL = 0x01000021

test("modifier-only presses are partial", () => {
  assert.equal(H.fromKeyEvent(KEY_CONTROL, H.QT_CTRL, 37).state, "partial")
})

test("binds by keycode with a readable label", () => {
  const hk = H.fromKeyEvent(KEY_1, H.QT_META | H.QT_ALT, 10)
  assert.equal(hk.state, "ok")
  assert.equal(hk.keys, "SUPER + ALT + code:10")
  assert.equal(hk.label, "Super+Alt+1")
  assert.equal(hk.keysym, "1")
})

test("shifted characters fall back to the keycode's label", () => {
  const hk = H.fromKeyEvent(KEY_EXCLAM, H.QT_CTRL | H.QT_SHIFT, 10)
  assert.equal(hk.keys, "CTRL + SHIFT + code:10")
  assert.equal(hk.label, "Ctrl+Shift+1")
})

test("printable keys need Super, Ctrl or Alt", () => {
  assert.equal(H.fromKeyEvent(KEY_M, 0, 58).state, "invalid")
  assert.equal(H.fromKeyEvent(KEY_M, H.QT_SHIFT, 58).state, "invalid")
  assert.equal(H.fromKeyEvent(KEY_M, H.QT_CTRL, 58).state, "ok")
})

test("function keys need a modifier, F13 and up do not", () => {
  assert.equal(H.fromKeyEvent(KEY_F5, 0, 71).state, "invalid")
  assert.equal(H.fromKeyEvent(KEY_F5, H.QT_SHIFT, 71).state, "ok")
  const f13 = H.fromKeyEvent(KEY_F13, 0, 191)
  assert.equal(f13.state, "ok")
  assert.equal(f13.keys, "code:191")
  assert.equal(f13.label, "F13")
})

test("keypad keys are labelled as such", () => {
  const hk = H.fromKeyEvent(0x31, H.QT_KEYPAD | H.QT_CTRL, 87)
  assert.equal(hk.label, "Ctrl+Num 1")
  assert.equal(H.fromKeyEvent(0x31, H.QT_KEYPAD, 87).state, "invalid")
})

test("validates keys strictly", () => {
  assert.equal(H.isValidKeys("SUPER + CTRL + M"), true)
  assert.equal(H.isValidKeys("code:191"), true)
  assert.equal(H.isValidKeys("SUPER + F13"), true)
  assert.equal(H.isValidKeys("CTRL + KP_5"), true)
  assert.equal(H.isValidKeys("ALT + Return"), true)
  assert.equal(H.isValidKeys("SUPER + CTRL + M\") os.execute(\"x"), false)
  assert.equal(H.isValidKeys("HYPER + M"), false)
  assert.equal(H.isValidKeys("SUPER + SUPER + M"), false)
  // Labels from the UI are not key names Hyprland knows.
  assert.equal(H.isValidKeys("SUPER + Esc"), false)
  assert.equal(H.isValidKeys("SUPER + PgUp"), false)
  assert.equal(H.isValidKeys("code:999"), false)
  assert.equal(H.isValidKeys("code:3"), false)
  assert.equal(H.isValidKeys("m"), false)
  assert.equal(H.isValidKeys(""), false)
})

test("config and binds agree on which keys are valid", async () => {
  const { loadQmlJs } = await import("./load.mjs")
  const Config = loadQmlJs("lib/Config.js")
  const cases = ["SUPER + CTRL + M", "code:191", "SUPER + F35", "SUPER + F36", "CTRL + KP_0", "SHIFT + grave",
    "SUPER + Esc", "code:999", "code:8", "code:7", "ALT + ALT + A", "SUPER + a", "CTRL + ALT + code:56", "x"]
  for (const keys of cases) assert.equal(Config.validKeys(keys), H.isValidKeys(keys), keys)
})

test("luaString escapes quotes, backslashes and control characters", () => {
  assert.equal(H.luaString('a"b\\c\nd'), '"a\\"b\\\\c d"')
})

test("bindsFile drops invalid entries and duplicate keys", () => {
  const lua = H.bindsFile("omaboard", [
    { keys: "SUPER + CTRL + M", name: "toggle", description: 'Open "board"' },
    { keys: "SUPER + CTRL + M", name: "stop", description: "dupe" },
    { keys: "SUPER + X\"); os.exit()", name: "evil", description: "x" },
    { keys: "CTRL + code:10", name: "../bad", description: "x" },
    { keys: "ALT + code:11", name: "play-s1234abcd", description: "Play airhorn" }
  ])
  const binds = lua.split("\n").filter(l => l.startsWith("pcall(hl.bind"))
  assert.equal(binds.length, 2)
  assert.equal(binds[0], 'pcall(hl.bind, "SUPER + CTRL + M", hl.dsp.global("omaboard:toggle"), { description = "Open \\"board\\"" })')
  assert.ok(binds[1].includes('"omaboard:play-s1234abcd"'))
  assert.ok(!lua.includes("os.exit"))
})

test("evalCode unbinds only keys Omaboard bound before", () => {
  const code = H.evalCode("omaboard", [{ keys: "ALT + code:11", name: "stop", description: "Stop" }], ["SUPER + CTRL + M", "bogus\"key"])
  const lines = code.split("\n")
  assert.deepEqual(lines, [
    'pcall(hl.unbind, "SUPER + CTRL + M")',
    'pcall(hl.bind, "ALT + code:11", hl.dsp.global("omaboard:stop"), { description = "Stop" })'
  ])
})

const BINDS_TEXT = `bindd
	modmask: 68
	submap:
	key: E
	keycode: 0
	catchall: false
	description: Emoji picker
	dispatcher: __lua
	arg: 120

bindd
	modmask: 72
	submap:
	key: SUPER + ALT + code:10
	keycode: 0
	catchall: false
	description: Move window to workspace 1
	dispatcher: __lua
	arg: 140

bindd
	modmask: 68
	submap:
	key: M
	keycode: 0
	catchall: false
	description: Omaboard: open soundboard
	dispatcher: __lua
	arg: 300
`

test("parses hyprctl binds text, keeping keycodes", () => {
  const binds = H.parseHyprBinds(BINDS_TEXT)
  assert.equal(binds.length, 3)
  assert.deepEqual(binds[0], { mask: 68, key: "e", combo: "SUPER + CTRL + E", description: "Emoji picker", arg: "120" })
  assert.equal(binds[1].key, "code:10")
  assert.equal(binds[1].combo, "SUPER + ALT + code:10")
  assert.equal(binds[2].combo, "SUPER + CTRL + M")
})

test("reads the keys of both generated file formats", () => {
  const oldFormat = 'hl.bind("SUPER + CTRL + M", hl.dsp.global("omaboard:toggle"), { description = "x" })'
  const newFormat = 'pcall(hl.bind, "CTRL + ALT + code:56", hl.dsp.global("omaboard:play-s1"), { description = "y" })'
  assert.deepEqual(H.keysInBindsFile(oldFormat + "\n" + newFormat + "\n" + newFormat), ["SUPER + CTRL + M", "CTRL + ALT + code:56"])
  assert.deepEqual(H.keysInBindsFile(H.bindsFile("omaboard", [{ keys: "SUPER + F13", name: "stop", description: "z" }])), ["SUPER + F13"])
  assert.deepEqual(H.keysInBindsFile('hl.bind("rm -rf", x)'), [])
})

test("finds conflicts by keycode or by key name, ignoring our own", () => {
  const binds = H.parseHyprBinds(BINDS_TEXT)
  assert.equal(H.findConflict(binds, "SUPER + ALT + code:10", "1", "Omaboard").description, "Move window to workspace 1")
  assert.equal(H.findConflict(binds, "SUPER + CTRL + code:26", "E", "Omaboard").description, "Emoji picker")
  assert.equal(H.findConflict(binds, "SUPER + CTRL + code:58", "M", "Omaboard"), null)
  assert.equal(H.findConflict(binds, "SUPER + code:10", "1", "Omaboard"), null)
})
