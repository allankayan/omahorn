// Omaboard's settings file (~/.config/omaboard/config.json): defaults,
// validation, and the first-run import from Soundux. Pure functions; every
// update returns a new object so QML bindings see the change.

var VERSION = 1
var DEFAULT_FOLDER = "~/Music/Soundboard"
var KEYS_RE = /^((SUPER|CTRL|ALT|SHIFT) \+ )*([A-Za-z0-9_]{1,32}|code:\d{1,3})$/

function defaults() {
  return {
    version: VERSION,
    folders: [{ path: DEFAULT_FOLDER, name: "", recursive: true }],
    // Physical microphone mixed into the virtual one; "auto" follows the
    // default input whenever that is a real microphone.
    mic: "auto",
    // Make "Omaboard Microphone" the system default input, so apps that use
    // the default device hear sounds without any per-app setup.
    defaultMic: true,
    // Also play sounds on your own output.
    monitor: true,
    micVolume: 80,
    monitorVolume: 60,
    overlap: false,
    closeOnPlay: true,
    hotkeys: {
      toggle: { keys: "SUPER + CTRL + M", label: "Super+Ctrl+M" },
      stop: { keys: "SUPER + CTRL + SHIFT + M", label: "Super+Ctrl+Shift+M" }
    },
    sounds: {}
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value))
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function clamp(value, min, max, fallback) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || !isFinite(n)) return fallback
  return Math.max(min, Math.min(max, Math.round(n)))
}

function bool(value, fallback) {
  return typeof value === "boolean" ? value : fallback
}

function hotkey(value) {
  if (!isObject(value) || typeof value.keys !== "string" || !KEYS_RE.test(value.keys)) return null
  var label = typeof value.label === "string" && value.label.trim() ? value.label.trim().slice(0, 48) : value.keys
  return { keys: value.keys, label: label }
}

function folders(value) {
  if (!Array.isArray(value)) return clone(defaults().folders)
  var out = []
  var seen = {}
  for (var i = 0; i < value.length; i++) {
    var f = value[i]
    var path = typeof f === "string" ? f : (isObject(f) ? f.path : "")
    path = String(path || "").trim()
    if (!path || seen[path]) continue
    seen[path] = true
    out.push({
      path: path,
      name: isObject(f) && typeof f.name === "string" ? f.name.trim().slice(0, 48) : "",
      recursive: isObject(f) ? f.recursive === true : false
    })
  }
  return out
}

function soundEntry(value) {
  if (!isObject(value)) return null
  var entry = {}
  if (value.favorite === true) entry.favorite = true
  var volume = clamp(value.volume, 1, 200, 100)
  if (volume !== 100) entry.volume = volume
  var key = hotkey(value.hotkey)
  if (key) entry.hotkey = key
  return Object.keys(entry).length > 0 ? entry : null
}

// Fills gaps with defaults and drops anything malformed. Returns a fresh
// object; the input is never modified.
function normalize(raw) {
  var base = defaults()
  var src = isObject(raw) ? raw : {}
  var out = {
    version: VERSION,
    folders: src.folders === undefined ? base.folders : folders(src.folders),
    mic: typeof src.mic === "string" && src.mic.trim() ? src.mic.trim() : "auto",
    defaultMic: bool(src.defaultMic, base.defaultMic),
    monitor: bool(src.monitor, base.monitor),
    micVolume: clamp(src.micVolume, 0, 150, base.micVolume),
    monitorVolume: clamp(src.monitorVolume, 0, 150, base.monitorVolume),
    overlap: bool(src.overlap, base.overlap),
    closeOnPlay: bool(src.closeOnPlay, base.closeOnPlay),
    hotkeys: {},
    sounds: {}
  }
  var hotkeys = isObject(src.hotkeys) ? src.hotkeys : {}
  var names = ["toggle", "stop"]
  for (var i = 0; i < names.length; i++) {
    var name = names[i]
    // An explicit null means the user cleared it; missing means default.
    out.hotkeys[name] = hotkeys[name] === undefined ? base.hotkeys[name] : hotkey(hotkeys[name])
  }
  var sounds = isObject(src.sounds) ? src.sounds : {}
  for (var path in sounds) {
    if (typeof path !== "string" || path.charAt(0) !== "/") continue
    var entry = soundEntry(sounds[path])
    if (entry) out.sounds[path] = entry
  }
  return out
}

function withSetting(config, key, value) {
  var next = clone(config)
  next[key] = value
  return normalize(next)
}

// Merges `patch` into one sound's settings; entries back at their defaults
// are removed so the file only records what the user changed.
function withSound(config, path, patch) {
  var next = clone(config)
  if (!isObject(next.sounds)) next.sounds = {}
  var current = isObject(next.sounds[path]) ? next.sounds[path] : {}
  for (var key in patch) current[key] = patch[key]
  next.sounds[path] = current
  return normalize(next)
}

function withHotkey(config, name, value) {
  var next = clone(config)
  if (!isObject(next.hotkeys)) next.hotkeys = {}
  next.hotkeys[name] = value
  return normalize(next)
}

// Keys used anywhere in the config, with what uses them.
function usedKeys(config) {
  var out = {}
  var c = normalize(config)
  for (var name in c.hotkeys) if (c.hotkeys[name]) out[c.hotkeys[name].keys] = { kind: "action", name: name }
  for (var path in c.sounds) if (c.sounds[path].hotkey) out[c.sounds[path].hotkey.keys] = { kind: "sound", path: path }
  return out
}

// First run: reuse a Soundux library. Its tabs become folders (Soundux does
// not descend into subfolders, so neither do these) and favorites carry over.
function fromSoundux(raw) {
  var data
  try { data = typeof raw === "string" ? JSON.parse(raw) : raw } catch (e) { return null }
  var tabs = data && data.data && Array.isArray(data.data.tabs) ? data.data.tabs : []
  if (tabs.length === 0) return null
  var result = { folders: [], sounds: {}, settings: {} }
  for (var i = 0; i < tabs.length; i++) {
    var tab = tabs[i]
    if (!tab || typeof tab.path !== "string" || tab.path.charAt(0) !== "/") continue
    result.folders.push({ path: tab.path, name: typeof tab.name === "string" ? tab.name : "", recursive: false })
    var sounds = Array.isArray(tab.sounds) ? tab.sounds : []
    for (var j = 0; j < sounds.length; j++) {
      var s = sounds[j]
      if (s && typeof s.path === "string" && s.isFavorite === true) result.sounds[s.path] = { favorite: true }
    }
  }
  var settings = data.settings || {}
  if (typeof settings.allowOverlapping === "boolean") result.settings.overlap = settings.allowOverlapping
  if (isFinite(Number(settings.remoteVolume))) result.settings.micVolume = Number(settings.remoteVolume)
  if (isFinite(Number(settings.localVolume))) result.settings.monitorVolume = Number(settings.localVolume)
  return result.folders.length > 0 ? result : null
}

// The config a first run starts from: defaults, plus a Soundux library when
// one exists. The default folder stays first so new sounds have a home.
function firstRun(sounduxRaw) {
  var config = defaults()
  var imported = sounduxRaw ? fromSoundux(sounduxRaw) : null
  if (imported) {
    config.folders = config.folders.concat(imported.folders)
    config.sounds = imported.sounds
    for (var key in imported.settings) config[key] = imported.settings[key]
  }
  return { config: normalize(config), imported: !!imported }
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION,
    DEFAULT_FOLDER: DEFAULT_FOLDER,
    defaults: defaults,
    normalize: normalize,
    withSetting: withSetting,
    withSound: withSound,
    withHotkey: withHotkey,
    usedKeys: usedKeys,
    fromSoundux: fromSoundux,
    firstRun: firstRun
  }
}
