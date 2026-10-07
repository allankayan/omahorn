// Hotkeys: turning a captured Qt key event into a Hyprland bind, generating
// the Lua that registers it, and reading `hyprctl binds` to find conflicts.
//
// Binds use `code:<keycode>` so they follow the physical key on any layout.
// On Wayland, Qt's nativeScanCode is the XKB keycode Hyprland matches.

var QT_SHIFT = 0x02000000
var QT_CTRL = 0x04000000
var QT_ALT = 0x08000000
var QT_META = 0x10000000
var QT_KEYPAD = 0x20000000

// Hyprland modmask bits, as `hyprctl binds` reports them.
var MASK = { SHIFT: 1, CTRL: 4, ALT: 8, SUPER: 64 }
var MOD_ORDER = ["SUPER", "CTRL", "ALT", "SHIFT"]
var MOD_LABEL = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" }

// Qt key codes of keys that only ever modify another key.
var MODIFIER_KEYS = [
  0x01000020, 0x01000021, 0x01000022, 0x01000023, // Shift Control Meta Alt
  0x01000024, 0x01000025,                         // CapsLock NumLock
  0x01000053, 0x01000054, 0x01000056, 0x01000057, // Super_L/R Hyper_L/R
  0x01001103                                      // AltGr
]

// Qt key -> [keysym name, label] for keys whose name is not their character.
var NAMED = {}
NAMED[0x01000000] = ["Escape", "Esc"]
NAMED[0x01000001] = ["Tab", "Tab"]
NAMED[0x01000003] = ["BackSpace", "Backspace"]
NAMED[0x01000004] = ["Return", "Enter"]
NAMED[0x01000005] = ["KP_Enter", "Num Enter"]
NAMED[0x01000006] = ["Insert", "Insert"]
NAMED[0x01000007] = ["Delete", "Delete"]
NAMED[0x01000008] = ["Pause", "Pause"]
NAMED[0x01000009] = ["Print", "Print"]
NAMED[0x01000010] = ["Home", "Home"]
NAMED[0x01000011] = ["End", "End"]
NAMED[0x01000012] = ["Left", "Left"]
NAMED[0x01000013] = ["Up", "Up"]
NAMED[0x01000014] = ["Right", "Right"]
NAMED[0x01000015] = ["Down", "Down"]
NAMED[0x01000016] = ["Prior", "PgUp"]
NAMED[0x01000017] = ["Next", "PgDn"]
NAMED[0x01000026] = ["Scroll_Lock", "ScrollLock"]
NAMED[0x01000055] = ["Menu", "Menu"]
NAMED[0x20] = ["space", "Space"]
NAMED[0x27] = ["apostrophe", "'"]
NAMED[0x2c] = ["comma", ","]
NAMED[0x2d] = ["minus", "-"]
NAMED[0x2e] = ["period", "."]
NAMED[0x2f] = ["slash", "/"]
NAMED[0x3b] = ["semicolon", ";"]
NAMED[0x3d] = ["equal", "="]
NAMED[0x5b] = ["bracketleft", "["]
NAMED[0x5c] = ["backslash", "\\"]
NAMED[0x5d] = ["bracketright", "]"]
NAMED[0x60] = ["grave", "`"]

// Labels for keys by XKB keycode on a US layout, used when Qt reports a
// shifted character (Shift+1 arrives as "!").
var CODE_LABEL = {}
;(function() {
  var digits = "1234567890"
  for (var d = 0; d < digits.length; d++) CODE_LABEL[10 + d] = digits.charAt(d)
  var rows = [[24, "QWERTYUIOP"], [38, "ASDFGHJKL"], [52, "ZXCVBNM"]]
  for (var r = 0; r < rows.length; r++)
    for (var c = 0; c < rows[r][1].length; c++) CODE_LABEL[rows[r][0] + c] = rows[r][1].charAt(c)
  var punct = { 20: "-", 21: "=", 34: "[", 35: "]", 47: ";", 48: "'", 49: "`", 51: "\\", 59: ",", 60: ".", 61: "/", 65: "Space" }
  for (var p in punct) CODE_LABEL[p] = punct[p]
  for (var f = 0; f < 10; f++) CODE_LABEL[67 + f] = "F" + (f + 1)
  CODE_LABEL[95] = "F11"
  CODE_LABEL[96] = "F12"
  var pad = { 79: "Num 7", 80: "Num 8", 81: "Num 9", 82: "Num -", 83: "Num 4", 84: "Num 5", 85: "Num 6",
              86: "Num +", 87: "Num 1", 88: "Num 2", 89: "Num 3", 90: "Num 0", 91: "Num .", 104: "Num Enter",
              106: "Num /", 63: "Num *" }
  for (var k in pad) CODE_LABEL[k] = pad[k]
})()

function isModifierKey(key) {
  return MODIFIER_KEYS.indexOf(Number(key)) !== -1
}

function modsFromQt(modifiers) {
  var m = Number(modifiers) || 0
  var out = []
  if (m & QT_META) out.push("SUPER")
  if (m & QT_CTRL) out.push("CTRL")
  if (m & QT_ALT) out.push("ALT")
  if (m & QT_SHIFT) out.push("SHIFT")
  return out
}

function keyInfo(key, modifiers, scanCode) {
  var k = Number(key) || 0
  var keypad = (Number(modifiers) & QT_KEYPAD) !== 0
  var code = Number(scanCode) || 0
  if (keypad && code && CODE_LABEL[code] && CODE_LABEL[code].indexOf("Num") === 0)
    return { keysym: "", label: CODE_LABEL[code], kind: "keypad" }
  if (k >= 0x41 && k <= 0x5a) return { keysym: String.fromCharCode(k), label: String.fromCharCode(k), kind: "printable" }
  if (k >= 0x30 && k <= 0x39) return { keysym: String.fromCharCode(k), label: String.fromCharCode(k), kind: "printable" }
  if (k >= 0x01000030 && k <= 0x01000052) {
    var n = k - 0x01000030 + 1
    return { keysym: "F" + n, label: "F" + n, kind: n >= 13 ? "free" : "function" }
  }
  var named = NAMED[k]
  if (named) {
    var kind = "navigation"
    if (k < 0x01000000) kind = "printable"
    if (k === 0x01000008 || k === 0x01000026 || k === 0x01000055) kind = "free"
    return { keysym: named[0], label: named[1], kind: kind }
  }
  if (code && CODE_LABEL[code]) {
    var label = CODE_LABEL[code]
    var kindFromCode = /^F\d+$/.test(label) ? "function" : "printable"
    return { keysym: "", label: label, kind: kindFromCode }
  }
  return { keysym: "", label: code ? "Key " + code : "Key", kind: "printable" }
}

// Turns a key press into a hotkey. Returns:
//   { state: "partial" }                    only modifiers so far
//   { state: "invalid", reason }            would steal ordinary typing
//   { state: "ok", keys, label, keysym }
function fromKeyEvent(key, modifiers, scanCode) {
  if (isModifierKey(key)) return { state: "partial", mods: modsFromQt(modifiers) }
  var code = Number(scanCode) || 0
  if (!code || code > 767) return { state: "invalid", reason: "That key cannot be bound" }
  var mods = modsFromQt(modifiers)
  var info = keyInfo(key, modifiers, code)
  var strong = mods.indexOf("SUPER") !== -1 || mods.indexOf("CTRL") !== -1 || mods.indexOf("ALT") !== -1
  if (info.kind === "printable" || info.kind === "keypad") {
    if (!strong) return { state: "invalid", reason: "Add Super, Ctrl or Alt so typing still works" }
  } else if (info.kind === "function" || info.kind === "navigation") {
    if (mods.length === 0) return { state: "invalid", reason: "Add a modifier to " + info.label }
  }
  var parts = mods.concat(["code:" + code])
  var labelParts = mods.map(function(m) { return MOD_LABEL[m] }).concat([info.label])
  return { state: "ok", keys: parts.join(" + "), label: labelParts.join("+"), keysym: info.keysym }
}

// Key names Hyprland is sure to parse. Anything else could make `hl.bind`
// raise while Omarchy loads the binds file, and with it the rest of the
// user's Hyprland config, so it never reaches the file.
var NAMED_KEYSYMS = [
  "Return", "Escape", "Tab", "BackSpace", "Insert", "Delete", "Home", "End", "Prior", "Next",
  "Up", "Down", "Left", "Right", "space", "Pause", "Print", "Scroll_Lock", "Menu",
  "comma", "period", "slash", "semicolon", "apostrophe", "minus", "equal",
  "bracketleft", "bracketright", "backslash", "grave"
]
var MODIFIERS = ["SUPER", "CTRL", "ALT", "SHIFT"]

function isValidKey(key) {
  var code = /^code:(\d{1,3})$/.exec(key)
  if (code) return Number(code[1]) >= 8 && Number(code[1]) <= 767
  if (/^[A-Z0-9]$/.test(key)) return true
  if (/^F([1-9]|[12][0-9]|3[0-5])$/.test(key)) return true
  if (/^KP_[0-9]$/.test(key)) return true
  return NAMED_KEYSYMS.indexOf(key) !== -1
}

function isValidKeys(keys) {
  if (typeof keys !== "string" || keys.length > 64) return false
  var parts = keys.split(" + ")
  var key = parts.pop()
  var seen = {}
  for (var i = 0; i < parts.length; i++) {
    if (MODIFIERS.indexOf(parts[i]) === -1 || seen[parts[i]]) return false
    seen[parts[i]] = true
  }
  return isValidKey(key)
}

function isValidHotkey(hotkey) {
  return !!hotkey && typeof hotkey === "object" && isValidKeys(hotkey.keys)
}

function parseKeys(keys) {
  var parts = String(keys || "").split(" + ")
  var key = parts.pop() || ""
  var mask = 0
  for (var i = 0; i < parts.length; i++) mask |= MASK[parts[i]] || 0
  return { mask: mask, key: key }
}

// Keys of binds a generated file declares, in either form Omahorn has
// written (`hl.bind("KEYS"` and `pcall(hl.bind, "KEYS"`).
function keysInBindsFile(text) {
  var re = /hl\.bind[(,]\s*"([^"]+)"/g
  var out = []
  var match
  while ((match = re.exec(String(text || ""))) !== null) {
    if (isValidKeys(match[1]) && out.indexOf(match[1]) === -1) out.push(match[1])
  }
  return out
}

// Lua string literal for arbitrary text: printable characters only.
function luaString(text) {
  var s = String(text === undefined || text === null ? "" : text)
  var out = ""
  for (var i = 0; i < s.length; i++) {
    var ch = s.charAt(i)
    var code = s.charCodeAt(i)
    if (ch === "\\") out += "\\\\"
    else if (ch === "\"") out += "\\\""
    else if (code < 32 || code === 127) out += " "
    else out += ch
  }
  return "\"" + out + "\""
}

var NAME_RE = /^[a-z0-9][a-z0-9-]{0,63}$/

// bindings: [{ keys, name, description }]. Invalid entries are dropped, so
// nothing that reaches Hyprland can carry anything but a key and a name.
function sanitize(bindings) {
  var out = []
  var seenKeys = {}
  var list = Array.isArray(bindings) ? bindings : []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b || !isValidKeys(b.keys) || !NAME_RE.test(String(b.name || ""))) continue
    if (seenKeys[b.keys]) continue
    seenKeys[b.keys] = true
    out.push({ keys: b.keys, name: b.name, description: String(b.description || b.name) })
  }
  return out
}

// Each bind is protected on its own: one Hyprland refuses costs only itself,
// never the binds after it or the config files loaded after this one.
function bindLine(appid, b) {
  return "pcall(hl.bind, " + luaString(b.keys) + ", hl.dsp.global(" + luaString(appid + ":" + b.name) + "), { description = "
    + luaString(b.description) + " })"
}

// The file Hyprland loads on every config reload.
function bindsFile(appid, bindings) {
  var lines = [
    "-- Generated by Omahorn. Change these from the soundboard instead of here;",
    "-- the file is rewritten whenever a hotkey changes."
  ]
  var list = sanitize(bindings)
  for (var i = 0; i < list.length; i++) lines.push(bindLine(appid, list[i]))
  return lines.join("\n") + "\n"
}

// Code for `hyprctl eval`: applies the new set to the running compositor
// without a reload. Unbinding is by key and removes every bind on it, so it
// only ever touches keys Omahorn bound before (`previousKeys`).
function evalCode(appid, bindings, previousKeys) {
  var list = sanitize(bindings)
  var unbind = []
  var seen = {}
  var prev = Array.isArray(previousKeys) ? previousKeys : []
  for (var i = 0; i < prev.length; i++) {
    if (isValidKeys(prev[i]) && !seen[prev[i]]) { seen[prev[i]] = true; unbind.push(prev[i]) }
  }
  var code = []
  for (var u = 0; u < unbind.length; u++) code.push("pcall(hl.unbind, " + luaString(unbind[u]) + ")")
  for (var b = 0; b < list.length; b++) code.push(bindLine(appid, list[b]))
  return code.join("\n")
}

function combo(mask, key) {
  var mods = []
  for (var i = 0; i < MOD_ORDER.length; i++) if (mask & MASK[MOD_ORDER[i]]) mods.push(MOD_ORDER[i])
  return mods.concat([key]).join(" + ")
}

// Parses `hyprctl binds` (text form: the JSON drops keycodes) into
// [{ mask, key, combo, description, arg }]: `key` lowercased ("code:N" kept
// as is) for comparisons, `combo` the keys as `hl.unbind` takes them.
function parseHyprBinds(text) {
  var out = []
  var blocks = String(text || "").split(/\n(?=bind)/)
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i]
    var mask = block.match(/\n\s*modmask:\s*(\d+)/)
    var key = block.match(/\n\s*key:\s*(.*)/)
    if (!mask || !key) continue
    var rawKey = key[1].trim()
    var codeMatch = rawKey.match(/code:(\d+)\s*$/)
    var lastKey = codeMatch ? "code:" + codeMatch[1] : rawKey.split(" + ").pop()
    var normalized = codeMatch ? lastKey : lastKey.toLowerCase()
    var desc = block.match(/\n\s*description:\s*(.*)/)
    var arg = block.match(/\n\s*arg:\s*(.*)/)
    out.push({
      mask: Number(mask[1]),
      key: normalized,
      combo: combo(Number(mask[1]), lastKey),
      description: desc ? desc[1].trim() : "",
      arg: arg ? arg[1].trim() : ""
    })
  }
  return out
}

// The first existing bind on the same keys, or null. `keysym` lets a
// candidate bound by keycode also match a bind written with the key name;
// binds whose description starts with `ignorePrefix` (our own) never count.
function findConflict(existing, keys, keysym, ignorePrefix) {
  var parsed = parseKeys(keys)
  var forms = [String(parsed.key).toLowerCase()]
  if (keysym) forms.push(String(keysym).toLowerCase())
  var prefix = String(ignorePrefix || "")
  var list = Array.isArray(existing) ? existing : []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (b.mask !== parsed.mask) continue
    if (forms.indexOf(b.key) === -1) continue
    if (prefix && b.description.indexOf(prefix) === 0) continue
    return b
  }
  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    QT_SHIFT: QT_SHIFT, QT_CTRL: QT_CTRL, QT_ALT: QT_ALT, QT_META: QT_META, QT_KEYPAD: QT_KEYPAD,
    isModifierKey: isModifierKey,
    fromKeyEvent: fromKeyEvent,
    isValidKey: isValidKey,
    isValidKeys: isValidKeys,
    isValidHotkey: isValidHotkey,
    parseKeys: parseKeys,
    luaString: luaString,
    sanitize: sanitize,
    bindsFile: bindsFile,
    evalCode: evalCode,
    parseHyprBinds: parseHyprBinds,
    keysInBindsFile: keysInBindsFile,
    findConflict: findConflict
  }
}
