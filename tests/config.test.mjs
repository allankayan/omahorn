import { test } from "node:test"
import assert from "node:assert/strict"
import { loadQmlJs } from "./load.mjs"

const Config = loadQmlJs("lib/Config.js")

test("normalize fills defaults for an empty or broken config", () => {
  for (const raw of [undefined, null, "nope", [], {}]) {
    const c = Config.normalize(raw)
    assert.equal(c.version, 1)
    assert.deepEqual(c.folders, [{ path: "~/Music/Soundboard", name: "", recursive: true }])
    assert.equal(c.mic, "auto")
    assert.equal(c.defaultMic, true)
    assert.equal(c.hotkeys.toggle.keys, "SUPER + CTRL + M")
  }
})

test("normalize clamps numbers and rejects bad values", () => {
  const c = Config.normalize({ micVolume: 999, monitorVolume: -4, overlap: "yes", mic: "  ", folders: [{ path: "" }, "/a", "/a", { path: "/b", recursive: true }] })
  assert.equal(c.micVolume, 150)
  assert.equal(c.monitorVolume, 0)
  assert.equal(c.overlap, false)
  assert.equal(c.mic, "auto")
  assert.deepEqual(c.folders, [{ path: "/a", name: "", recursive: false }, { path: "/b", name: "", recursive: true }])
})

test("a cleared hotkey stays cleared; an invalid one is dropped", () => {
  const c = Config.normalize({ hotkeys: { toggle: null, stop: { keys: "rm -rf /" } } })
  assert.equal(c.hotkeys.toggle, null)
  assert.equal(c.hotkeys.stop, null)
})

test("sound entries keep only what differs from defaults", () => {
  let c = Config.normalize({})
  c = Config.withSound(c, "/m/a.ogg", { favorite: true })
  assert.deepEqual(c.sounds["/m/a.ogg"], { favorite: true })
  c = Config.withSound(c, "/m/a.ogg", { volume: 140, hotkey: { keys: "ALT + code:10", label: "Alt+1" } })
  assert.deepEqual(c.sounds["/m/a.ogg"], { favorite: true, volume: 140, hotkey: { keys: "ALT + code:10", label: "Alt+1" } })
  c = Config.withSound(c, "/m/a.ogg", { favorite: false, volume: 100, hotkey: null })
  assert.equal(c.sounds["/m/a.ogg"], undefined)
  c = Config.withSound(c, "relative.ogg", { favorite: true })
  assert.equal(c.sounds["relative.ogg"], undefined)
})

test("updates never mutate their input", () => {
  const c = Config.normalize({})
  const before = JSON.stringify(c)
  Config.withSetting(c, "micVolume", 10)
  Config.withSound(c, "/m/a.ogg", { favorite: true })
  Config.withHotkey(c, "toggle", null)
  assert.equal(JSON.stringify(c), before)
})

test("usedKeys lists actions and sounds", () => {
  const c = Config.withSound(Config.normalize({}), "/m/a.ogg", { hotkey: { keys: "ALT + code:10", label: "Alt+1" } })
  const used = Config.usedKeys(c)
  assert.deepEqual(used["SUPER + CTRL + M"], { kind: "action", name: "toggle" })
  assert.deepEqual(used["ALT + code:10"], { kind: "sound", path: "/m/a.ogg" })
})

const SOUNDUX = JSON.stringify({
  data: {
    tabs: [
      { name: "Downloads", path: "/home/u/Downloads", sounds: [{ path: "/home/u/Downloads/a.mp3", isFavorite: false }] },
      { name: "audios", path: "/home/u/Downloads/audios", sounds: [{ path: "/home/u/Downloads/audios/b.mp3", isFavorite: true }] },
      { name: "bad", path: "relative" }
    ]
  },
  settings: { allowOverlapping: true, remoteVolume: 100, localVolume: 70 }
})

test("imports Soundux tabs as non-recursive folders with favorites", () => {
  const imported = Config.fromSoundux(SOUNDUX)
  assert.deepEqual(imported.folders, [
    { path: "/home/u/Downloads", name: "Downloads", recursive: false },
    { path: "/home/u/Downloads/audios", name: "audios", recursive: false }
  ])
  assert.deepEqual(imported.sounds, { "/home/u/Downloads/audios/b.mp3": { favorite: true } })
  assert.equal(Config.fromSoundux("{broken"), null)
  assert.equal(Config.fromSoundux(JSON.stringify({ data: { tabs: [] } })), null)
})

test("first run keeps the default folder first and applies Soundux settings", () => {
  const { config, imported } = Config.firstRun(SOUNDUX)
  assert.equal(imported, true)
  assert.deepEqual(config.folders.map(f => f.path), ["~/Music/Soundboard", "/home/u/Downloads", "/home/u/Downloads/audios"])
  assert.equal(config.overlap, true)
  assert.equal(config.micVolume, 100)
  assert.equal(config.monitorVolume, 70)
  assert.equal(Config.firstRun("").imported, false)
})
