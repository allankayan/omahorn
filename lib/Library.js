// Pure helpers for the sound library: ids, display names, search and
// grouping. No Qt objects in here, so the same file runs under node for tests.

// Formats pw-play decodes itself (libsndfile). Anything else goes through
// ffmpeg first.
var NATIVE_EXTENSIONS = ["wav", "flac", "ogg", "oga", "opus", "mp3", "aiff", "aif", "caf"]

// 32-bit FNV-1a, hex. Stable across sessions, so a path keeps its id (and the
// global shortcut named after it) for as long as the file does not move.
function hash(text) {
  var h = 0x811c9dc5
  var s = String(text || "")
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return ("0000000" + h.toString(16)).slice(-8)
}

function soundId(path) {
  return "s" + hash(path)
}

function isNative(ext) {
  return NATIVE_EXTENSIONS.indexOf(String(ext || "").toLowerCase()) !== -1
}

// "lava_bunda-direito (youtube).mp3" -> "lava bunda-direito"
function prettyName(file) {
  var name = String(file || "")
  var dot = name.lastIndexOf(".")
  if (dot > 0) name = name.slice(0, dot)
  name = name.replace(/\s*[\[(](youtube|online-audio-converter\.com|soundboard|myinstants)[\])]\s*$/i, "")
  name = name.replace(/[_]+/g, " ").replace(/\s+/g, " ").trim()
  return name || String(file || "")
}

// Lowercase without diacritics, so "audio" finds "Áudio".
function fold(text) {
  var s = String(text || "").toLowerCase()
  if (typeof s.normalize === "function") s = s.normalize("NFD")
  return s.replace(/[̀-ͯ]/g, "")
}

function wordStarts(text) {
  var starts = [0]
  for (var i = 1; i < text.length; i++) {
    if (/[\s\-_.()[\]]/.test(text.charAt(i - 1)) && !/[\s\-_.()[\]]/.test(text.charAt(i))) starts.push(i)
  }
  return starts
}

function words(text) {
  return fold(text).split(/[^a-z0-9]+/).filter(function(w) { return w.length > 0 })
}

function acronym(text) {
  return words(text).map(function(w) { return w.charAt(0) }).join("")
}

// Higher is better; -1 means no match. Like the Omarchy launcher, every
// query word has to appear in the name or category (or, for short words,
// in the name's initials); the score orders exact, prefix, word-start and
// substring matches.
function matchScore(query, name, category) {
  var q = fold(query).trim()
  if (!q) return 0
  var n = fold(name)
  var c = fold(category)

  if (n === q) return 1000
  if (n.indexOf(q) === 0) return 900 - Math.min(n.length, 100)
  var at = n.indexOf(q)
  if (at !== -1) {
    if (wordStarts(n).indexOf(at) !== -1) return 800 - Math.min(at, 100)
    return 600 - Math.min(at, 100)
  }

  var terms = q.split(/\s+/)
  var initials = acronym(name)
  var inName = 0
  for (var i = 0; i < terms.length; i++) {
    var t = terms[i]
    if (n.indexOf(t) !== -1) inName++
    else if (c.indexOf(t) !== -1) continue
    else if (t.length <= 5 && initials.indexOf(t) !== -1) continue
    else return -1
  }
  if (inName === terms.length) return 500
  if (inName > 0) return 400
  if (terms.length === 1 && c.indexOf(terms[0]) !== -1) return 300
  return 200
}

function compareNames(a, b) {
  var an = fold(a.name)
  var bn = fold(b.name)
  if (an < bn) return -1
  if (an > bn) return 1
  return a.path < b.path ? -1 : (a.path > b.path ? 1 : 0)
}

// Sounds visible in a tab. `tab` is "all", "favorites" or a category name.
// Without a query, favorites come first and the rest is alphabetical; with
// one, the best match wins.
function filterSounds(sounds, query, tab) {
  var list = Array.isArray(sounds) ? sounds : []
  var out = []
  var q = String(query || "")
  for (var i = 0; i < list.length; i++) {
    var s = list[i]
    if (!s) continue
    if (tab === "favorites" && !s.favorite) continue
    if (tab && tab !== "all" && tab !== "favorites" && s.category !== tab) continue
    var score = matchScore(q, s.name, s.category)
    if (score < 0) continue
    out.push({ sound: s, score: score })
  }
  out.sort(function(a, b) {
    if (q.trim() && a.score !== b.score) return b.score - a.score
    if (!q.trim() && a.sound.favorite !== b.sound.favorite) return a.sound.favorite ? -1 : 1
    return compareNames(a.sound, b.sound)
  })
  return out.map(function(entry) { return entry.sound })
}

// Categories in the order their folders appear in the config.
function categories(sounds) {
  var order = []
  var counts = {}
  var list = Array.isArray(sounds) ? sounds : []
  for (var i = 0; i < list.length; i++) {
    var c = list[i] && list[i].category
    if (!c) continue
    if (counts[c] === undefined) { counts[c] = 0; order.push(c) }
    counts[c]++
  }
  return order.map(function(name) { return { name: name, count: counts[name] } })
}

function formatDuration(seconds) {
  var n = Number(seconds)
  if (seconds === null || seconds === undefined || !isFinite(n) || n < 0) return ""
  var total = Math.round(n)
  if (n > 0 && total === 0) total = 1
  var h = Math.floor(total / 3600)
  var m = Math.floor(total / 60) % 60
  var s = total % 60
  var ss = (s < 10 ? "0" : "") + s
  if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
  return m + ":" + ss
}

// Parses omaboard-scan output (one JSON object per line) and joins each file
// with its saved settings from config.sounds.
function parseScan(text, soundSettings) {
  var lines = String(text || "").split("\n")
  var settings = soundSettings && typeof soundSettings === "object" ? soundSettings : {}
  var out = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var item
    try { item = JSON.parse(line) } catch (e) { continue }
    if (!item || typeof item.path !== "string" || item.path.charAt(0) !== "/") continue
    if (seen[item.path]) continue
    seen[item.path] = true
    var saved = settings[item.path] || {}
    var volume = Number(saved.volume)
    out.push({
      id: soundId(item.path),
      path: item.path,
      file: String(item.file || ""),
      name: prettyName(item.file || item.path.split("/").pop()),
      category: String(item.category || ""),
      folder: String(item.folder || ""),
      ext: String(item.ext || "").toLowerCase(),
      duration: typeof item.duration === "number" && isFinite(item.duration) ? item.duration : null,
      size: Number(item.size) || 0,
      mtime: Number(item.mtime) || 0,
      favorite: saved.favorite === true,
      hotkey: saved.hotkey && typeof saved.hotkey.keys === "string" ? { keys: saved.hotkey.keys, label: String(saved.hotkey.label || saved.hotkey.keys) } : null,
      volume: isFinite(volume) && volume > 0 ? Math.min(200, volume) : 100
    })
  }
  return out
}

// Where a sound pw-play cannot read is kept once converted; a changed file
// gets a new name, so a stale conversion is never played.
function decodedPath(cacheDir, sound) {
  return String(cacheDir) + "/decoded/" + hash(sound.path + "|" + sound.size + "|" + sound.mtime) + ".opus"
}

// Best sound for a free-text request (IPC `play`): exact id or path first,
// then the top search hit across the whole library.
function resolve(sounds, query) {
  var q = String(query || "").trim()
  if (!q) return null
  var list = Array.isArray(sounds) ? sounds : []
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === q || list[i].path === q) return list[i]
  }
  var hits = filterSounds(list, q, "all")
  return hits.length > 0 ? hits[0] : null
}

// A name people recognize for an app recording audio. WebRTC apps (Discord,
// Chromium-based browsers) all call their stream "WEBRTC VoiceEngine" or
// similar, so the binary says more; binaries get their usual spelling.
var KNOWN_APPS = {
  "discord": "Discord", "discordcanary": "Discord Canary", "discordptb": "Discord PTB", "vesktop": "Vesktop",
  "webcord": "WebCord", "zen": "Zen", "firefox": "Firefox", "librewolf": "LibreWolf", "chromium": "Chromium",
  "chrome": "Chrome", "google-chrome": "Chrome", "brave": "Brave", "vivaldi": "Vivaldi", "obs": "OBS",
  "teams": "Teams", "slack": "Slack", "zoom": "Zoom", "telegram-desktop": "Telegram", "signal-desktop": "Signal",
  "steam": "Steam", "mumble": "Mumble", "teamspeak": "TeamSpeak", "ts3client_linux_amd64": "TeamSpeak"
}

function appLabel(app, binary) {
  var name = String(app || "").trim()
  var bin = String(binary || "").trim().split("/").pop()
  if (bin && (!name || /^(webrtc voiceengine|chromium input|chromium|alsa plug-in.*|record ?stream|audio-src|pipewire|pulseaudio)$/i.test(name))) name = bin
  var key = name.toLowerCase().replace(/(-bin|\.bin|\.exe)$/, "")
  if (KNOWN_APPS[key]) return KNOWN_APPS[key]
  if (name === name.toLowerCase() && name) return name.charAt(0).toUpperCase() + name.slice(1)
  return name || "Unknown app"
}

// PipeWire volume curve: sliders are perceptual (cubic), streams take a
// linear amplitude.
function amplitude(percent) {
  var p = Number(percent)
  if (!isFinite(p) || p <= 0) return 0
  return Math.pow(p / 100, 3)
}

if (typeof module !== "undefined") {
  module.exports = {
    NATIVE_EXTENSIONS: NATIVE_EXTENSIONS,
    hash: hash,
    soundId: soundId,
    isNative: isNative,
    prettyName: prettyName,
    fold: fold,
    matchScore: matchScore,
    filterSounds: filterSounds,
    categories: categories,
    formatDuration: formatDuration,
    parseScan: parseScan,
    decodedPath: decodedPath,
    resolve: resolve,
    appLabel: appLabel,
    amplitude: amplitude
  }
}
