import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlJs } from "./load.mjs"

const Library = loadQmlJs("lib/Library.js")

const sound = (name, category, extra = {}) => ({
  id: Library.soundId("/s/" + name),
  path: "/s/" + name,
  name,
  category,
  favorite: false,
  ...extra
})

test("ids are stable and path-specific", () => {
  assert.equal(Library.soundId("/a/b.mp3"), Library.soundId("/a/b.mp3"))
  assert.notEqual(Library.soundId("/a/b.mp3"), Library.soundId("/a/c.mp3"))
  assert.match(Library.soundId("/a/b.mp3"), /^s[0-9a-f]{8}$/)
})

test("prettyName strips extensions, underscores and downloader tags", () => {
  assert.equal(Library.prettyName("lava_bunda_direito.mp3"), "lava bunda direito")
  assert.equal(Library.prettyName("AIII meme - DK (youtube).mp3"), "AIII meme - DK")
  assert.equal(Library.prettyName("te dou 70.mp3"), "te dou 70")
  assert.equal(Library.prettyName(".mp3"), ".mp3")
})

test("search ignores case and accents", () => {
  const list = [sound("Áudio grande", "memes"), sound("leila", "memes")]
  assert.deepEqual(Library.filterSounds(list, "audio", "all").map(s => s.name), ["Áudio grande"])
  assert.deepEqual(Library.filterSounds(list, "LEI", "all").map(s => s.name), ["leila"])
})

test("prefix matches rank above substrings; loose letters do not match", () => {
  const list = [sound("xtedou", "a"), sound("tamedeixandolouca", "a"), sound("tedou70", "a")]
  assert.deepEqual(Library.filterSounds(list, "tedou", "all").map(s => s.name), ["tedou70", "xtedou"])
})

test("short words match initials; categories match too, ranked last", () => {
  const list = [sound("ta me deixando louca", "audios"), sound("airhorn", "sfx"), sound("sfx test", "x")]
  assert.deepEqual(Library.filterSounds(list, "tmdl", "all").map(s => s.name), ["ta me deixando louca"])
  assert.deepEqual(Library.filterSounds(list, "sfx", "all").map(s => s.name), ["sfx test", "airhorn"])
})

test("multi-word queries match words in any order", () => {
  const list = [sound("te dou 70", "a"), sound("dou", "a")]
  assert.deepEqual(Library.filterSounds(list, "70 te", "all").map(s => s.name), ["te dou 70"])
})

test("tabs filter by category and favorites; favorites lead without a query", () => {
  const list = [sound("b", "Memes"), sound("a", "SFX"), sound("c", "Memes", { favorite: true })]
  assert.deepEqual(Library.filterSounds(list, "", "all").map(s => s.name), ["c", "a", "b"])
  assert.deepEqual(Library.filterSounds(list, "", "Memes").map(s => s.name), ["c", "b"])
  assert.deepEqual(Library.filterSounds(list, "", "favorites").map(s => s.name), ["c"])
})

test("categories keep folder order and count sounds", () => {
  const list = [sound("a", "Memes"), sound("b", "SFX"), sound("c", "Memes")]
  assert.deepEqual(Library.categories(list), [{ name: "Memes", count: 2 }, { name: "SFX", count: 1 }])
})

test("formatDuration", () => {
  assert.equal(Library.formatDuration(3.4), "0:03")
  assert.equal(Library.formatDuration(0.2), "0:01")
  assert.equal(Library.formatDuration(65), "1:05")
  assert.equal(Library.formatDuration(3723), "1:02:03")
  assert.equal(Library.formatDuration(null), "")
  assert.equal(Library.formatDuration("x"), "")
})

test("parseScan joins saved settings and skips bad lines", () => {
  const text = [
    JSON.stringify({ path: "/m/airhorn.ogg", file: "airhorn.ogg", category: "SFX", ext: "OGG", duration: 2.5 }),
    "not json",
    JSON.stringify({ path: "relative.ogg", file: "relative.ogg" }),
    JSON.stringify({ path: "/m/airhorn.ogg", file: "dupe.ogg" }),
    JSON.stringify({ path: "/m/bruh.mp3", file: "bruh.mp3", category: "Memes", duration: null })
  ].join("\n")
  const saved = { "/m/airhorn.ogg": { favorite: true, volume: 250, hotkey: { keys: "SUPER + code:10", label: "Super+1" } } }
  const out = Library.parseScan(text, saved)
  assert.equal(out.length, 2)
  assert.equal(out[0].name, "airhorn")
  assert.equal(out[0].ext, "ogg")
  assert.equal(out[0].favorite, true)
  assert.equal(out[0].volume, 200)
  assert.deepEqual(out[0].hotkey, { keys: "SUPER + code:10", label: "Super+1" })
  assert.equal(out[1].duration, null)
  assert.equal(out[1].hotkey, null)
  assert.equal(out[1].volume, 100)
})

test("resolve finds by id, path, then best search hit", () => {
  const list = [sound("airhorn", "SFX"), sound("bruh", "Memes")]
  assert.equal(Library.resolve(list, list[1].id).name, "bruh")
  assert.equal(Library.resolve(list, "/s/airhorn").name, "airhorn")
  assert.equal(Library.resolve(list, "air").name, "airhorn")
  assert.equal(Library.resolve(list, "zzz"), null)
  assert.equal(Library.resolve(list, ""), null)
})

test("amplitude follows the cubic volume curve", () => {
  assert.equal(Library.amplitude(100), 1)
  assert.equal(Library.amplitude(50), 0.125)
  assert.equal(Library.amplitude(0), 0)
  assert.equal(Library.amplitude(-5), 0)
})

test("native formats are the ones libsndfile reads", () => {
  assert.equal(Library.isNative("MP3"), true)
  assert.equal(Library.isNative("opus"), true)
  assert.equal(Library.isNative("m4a"), false)
})

test("decodedPath changes when the file does", () => {
  const a = { path: "/m/a.m4a", size: 10, mtime: 1 }
  const b = { path: "/m/a.m4a", size: 11, mtime: 1 }
  assert.match(Library.decodedPath("/c", a), /^\/c\/decoded\/[0-9a-f]{8}\.opus$/)
  assert.notEqual(Library.decodedPath("/c", a), Library.decodedPath("/c", b))
})

test("appLabel names WebRTC apps by their binary", () => {
  assert.equal(Library.appLabel("WEBRTC VoiceEngine", "Discord"), "Discord")
  assert.equal(Library.appLabel("Chromium input", "chromium"), "Chromium")
  assert.equal(Library.appLabel("Zen", "zen-bin"), "Zen")
  assert.equal(Library.appLabel("WEBRTC VoiceEngine", "/opt/vesktop/vesktop"), "Vesktop")
  assert.equal(Library.appLabel("OBS Studio", "obs"), "OBS Studio")
  assert.equal(Library.appLabel("", "mumble"), "Mumble")
  assert.equal(Library.appLabel("mygame", ""), "Mygame")
  assert.equal(Library.appLabel("", ""), "Unknown app")
})
