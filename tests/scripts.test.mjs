import { test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync, spawnSync } from "node:child_process"
import { mkdtempSync, mkdirSync, writeFileSync, existsSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const hasFfprobe = spawnSync("sh", ["-c", "command -v ffprobe && command -v ffmpeg"]).status === 0

// A mono 16-bit WAV: `seconds` of a tone whose loudness follows `shape(t)`.
function wav(path, seconds, shape = () => 0.5, rate = 8000) {
  const samples = Math.round(seconds * rate)
  const data = Buffer.alloc(samples * 2)
  for (let i = 0; i < samples; i++) {
    const t = i / rate
    data.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 440 * t) * shape(t) * 32767), i * 2)
  }
  const header = Buffer.alloc(44)
  header.write("RIFF", 0)
  header.writeUInt32LE(36 + data.length, 4)
  header.write("WAVEfmt ", 8)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20)
  header.writeUInt16LE(1, 22)
  header.writeUInt32LE(rate, 24)
  header.writeUInt32LE(rate * 2, 28)
  header.writeUInt16LE(2, 32)
  header.writeUInt16LE(16, 34)
  header.write("data", 36)
  header.writeUInt32LE(data.length, 40)
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, Buffer.concat([header, data]))
}

function fixture() {
  const dir = mkdtempSync(join(tmpdir(), "omaboard-test-"))
  const lib = join(dir, "lib")
  wav(join(lib, "root sound.wav"), 1)
  wav(join(lib, "Memes", "bruh.wav"), 0.5)
  wav(join(lib, "Memes", "deeper", "deep cut.wav"), 0.25)
  wav(join(lib, ".hidden", "secret.wav"), 0.25)
  wav(join(lib, "Quotes 'n \"stuff\"", "it's.wav"), 0.25)
  writeFileSync(join(lib, "notes.txt"), "not audio")
  return { dir, lib, env: { ...process.env, XDG_CACHE_HOME: join(dir, "cache") } }
}

function scan(folders, env) {
  const out = execFileSync(join(root, "bin/omaboard-scan"), [JSON.stringify(folders)], { env, encoding: "utf8" })
  return out.trim().split("\n").filter(Boolean).map(line => JSON.parse(line))
}

test("scan: recursive folders turn first-level subfolders into categories", () => {
  const { lib, env } = fixture()
  const sounds = scan([{ path: lib, name: "Board", recursive: true }], env)
  const byFile = Object.fromEntries(sounds.map(s => [s.file, s]))
  assert.deepEqual(Object.keys(byFile).sort(), ["bruh.wav", "deep cut.wav", "it's.wav", "root sound.wav"])
  assert.equal(byFile["root sound.wav"].category, "Board")
  assert.equal(byFile["bruh.wav"].category, "Memes")
  assert.equal(byFile["deep cut.wav"].category, "Memes")
  assert.equal(byFile["it's.wav"].category, "Quotes 'n \"stuff\"")
  assert.equal(byFile["bruh.wav"].ext, "wav")
  assert.ok(byFile["bruh.wav"].size > 44)
})

test("scan: non-recursive folders list only their own files, once", () => {
  const { lib, env } = fixture()
  const sounds = scan([{ path: join(lib, "Memes") }, { path: lib, recursive: true }], env)
  const memes = sounds.filter(s => s.folder === join(lib, "Memes"))
  assert.deepEqual(memes.map(s => s.file), ["bruh.wav"])
  assert.equal(memes[0].category, "Memes")
  assert.equal(sounds.filter(s => s.file === "bruh.wav").length, 1)
})

test("scan: missing folders and ~ paths are handled", () => {
  const { env } = fixture()
  assert.deepEqual(scan([{ path: "/nonexistent/omaboard" }], env), [])
  const home = scan([{ path: "~/definitely-not-a-folder-omaboard" }], env)
  assert.deepEqual(home, [])
})

test("scan: rejects input that is not a folder list", () => {
  const result = spawnSync(join(root, "bin/omaboard-scan"), ["{}"], { encoding: "utf8" })
  assert.equal(result.status, 2)
})

test("scan: durations come from ffprobe and are cached", { skip: !hasFfprobe && "ffprobe not installed" }, () => {
  const { lib, env, dir } = fixture()
  const first = scan([{ path: lib, recursive: true }], env)
  const sound = first.find(s => s.file === "root sound.wav")
  assert.ok(Math.abs(sound.duration - 1) < 0.01)
  assert.ok(existsSync(join(dir, "cache", "omaboard", "durations.tsv")))
  const second = scan([{ path: lib, recursive: true }], env)
  assert.deepEqual(second, first)
})

test("peaks: loudness envelope follows the sound and is cached", { skip: !hasFfprobe && "ffmpeg not installed" }, () => {
  const { dir } = fixture()
  const file = join(dir, "ramp.wav")
  wav(file, 2, t => t / 2)
  const cache = join(dir, "peaks-cache")
  const items = JSON.stringify([{ id: "s1", path: file, duration: 2, key: "k1" }, { id: "gone", path: "/nope.wav", duration: 1, key: "k2" }])
  const run = () => execFileSync(join(root, "bin/omaboard-peaks"), [cache, items], { encoding: "utf8" }).trim().split("\n").map(l => JSON.parse(l))
  const out = run()
  assert.equal(out.length, 1)
  assert.equal(out[0].id, "s1")
  assert.equal(out[0].peaks.length, 40)
  assert.ok(out[0].peaks[0] < 10, "starts quiet")
  assert.equal(Math.max(...out[0].peaks), 100)
  assert.ok(out[0].peaks[39] > 90, "ends loud")
  assert.ok(existsSync(join(cache, "peaks", "k1.txt")))
  assert.deepEqual(run(), out)
})
