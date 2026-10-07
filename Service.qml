import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "components"
import "lib/Library.js" as Library
import "lib/Hotkeys.js" as Hotkeys
import "lib/Config.js" as Config
import "lib/Glyphs.js" as Glyphs

// Omahorn's headless half: the sound library, playback, the virtual
// microphone and global hotkeys. The board, the bar widget and IPC all drive
// this one object; none of them talk to PipeWire or Hyprland directly.
//
// Audio path, by config.routing:
//   inject  every sound is linked straight into the recording streams of the
//           apps using a microphone (bin/omahorn-inject), like Soundux; no
//           device is added and your voice path is untouched;
//   vmic    the "Omahorn Microphone" virtual source (bin/omahorn-audio)
//           passes the real microphone through and sounds are played into it.
// Either way a second copy plays on the default output so you hear it too.
// Each copy is a short-lived pw-play; nothing runs while idle.
Item {
  id: root
  visible: false

  // Host injection (see the Omarchy shell README).
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omahorn"
  // Global shortcut namespace (binds read `global omahorn:<name>`). The dev
  // host runs without hotkeys so it never competes with the installed plugin.
  property string appId: "omahorn"
  property bool hotkeysEnabled: true
  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omahorn"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omahorn"
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/omahorn"
  // Omarchy requires every Lua file in this folder on each Hyprland reload,
  // which is what keeps the hotkeys bound across reloads and logins.
  readonly property string bindsPath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/toggles/hypr/" + appId + ".lua"
  readonly property string shellJsonPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/omarchy/shell.json"
  readonly property string sounduxConfigPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/Soundux/config.json"

  readonly property string vmicName: "omahorn_mic"
  readonly property string captureName: "input.omahorn_mic"
  // Every bind Omahorn makes is described with this prefix, which is how it
  // tells its binds apart from the user's (the dev host gets its own).
  readonly property string bindPrefix: appId === "omahorn" ? "Omahorn: " : "Omahorn (" + appId + "): "

  // ------------------------------------------------------------- state

  property var config: Config.defaults()
  property bool ready: false
  property bool firstRun: false
  property bool importedSoundux: false
  property var appState: ({ defaultApplied: false })

  property var sounds: []
  readonly property var categories: Library.categories(sounds)
  property bool scanning: false
  property double scannedAt: 0
  property bool rescanQueued: false

  property var audio: ({ ok: true, error: "", present: false, mic: "", micDescription: "", isDefault: false, sources: [], listeners: [] })
  property bool audioReady: false
  readonly property bool injecting: config.routing !== "vmic"
  // Injecting needs no device, so it is always ready; the virtual mic is
  // ready once its module exists.
  readonly property bool micReady: injecting || audio.present === true
  // Apps recording a microphone right now, which is who hears an injected
  // sound: [{ node, app, binary }].
  property var injectTargets: []
  // Who hears the sounds, whichever the routing: [{ app, binary, label }].
  readonly property var listeners: (injecting ? injectTargets : (audio.listeners || [])).map(function(l) {
    return { app: l.app, binary: l.binary || "", label: Library.appLabel(l.app, l.binary) }
  })

  property var playing: []
  readonly property bool isPlaying: playing.length > 0
  property var voices: ({})
  property int voiceSerial: 0

  property var decoded: ({})
  property var decodeQueue: []
  property var hyprBinds: []
  property var appliedKeys: []
  property bool hotkeysSuspended: false
  property string lastBindsFile: ""

  property bool boardOpen: false
  // Where the board was left, so reopening it lands on the same tab and pad.
  property string boardTab: "all"
  property string boardSoundId: ""
  property string notice: ""
  property string noticeKind: "info"
  signal noticePosted(string text, string kind)

  // Global shortcuts re-register with Hyprland whenever this list changes, so
  // it only changes when a hotkey does (a string compares by value).
  readonly property string shortcutsKey: JSON.stringify(computeShortcuts(config))
  readonly property var shortcuts: JSON.parse(shortcutsKey)

  // ------------------------------------------------------------- logging

  function log(message) { console.info("omahorn: " + message) }
  function warn(message) { console.warn("omahorn: " + message) }

  // Inline in the board when it is open, a desktop notification otherwise.
  function report(text, kind) {
    var level = kind || "error"
    if (level === "error") warn(text)
    else log(text)
    notice = text
    noticeKind = level
    noticeTimer.restart()
    noticePosted(text, level)
    if (!boardOpen && level === "error") notify("Omahorn", text)
  }

  function notify(title, body) {
    Quickshell.execDetached(["sh", "-c",
      'if command -v omarchy-notification-send >/dev/null; then exec omarchy-notification-send --app-name Omahorn -g "$1" "$2" "$3"; '
      + 'else exec notify-send -a Omahorn "$2" "$3"; fi', "sh", Glyphs.app, title, body])
  }

  Timer {
    id: noticeTimer
    interval: 4500
    onTriggered: root.notice = ""
  }

  // ------------------------------------------------------------- startup

  Component.onCompleted: {
    log("starting from " + pluginDir)
    if (vmicNodePresent) vmicSeen = true
    initProc.exec(["mkdir", "-p", configDir, stateDir, cacheDir + "/decoded"])
  }

  // Runs detached once the shell is done with this object. A plugin reload or
  // a shell restart leaves Omahorn listed in shell.json, and then nothing
  // changes: apps keep the virtual microphone and the next instance takes the
  // hotkeys over. Disabling or removing the plugin takes Omahorn out of
  // shell.json, and then its hotkeys and virtual microphone go too. Inline
  // rather than a script, because `plugin remove` deletes the plugin folder.
  readonly property string cleanupScript: [
    "sleep 1",
    "shell_json=$1 binds=$2 state_dir=$3 unbind=$4 vmic=$5 id=$6",
    "if [[ -f $shell_json ]] && jq -e --arg id \"$id\" 'any(.. | objects; .id? == $id)' \"$shell_json\" >/dev/null 2>&1; then exit 0; fi",
    "rm -f \"$binds\" \"$state_dir/state.json\"",
    "[[ -n $unbind ]] && hyprctl eval \"$unbind\" >/dev/null 2>&1",
    "if [[ $(pactl get-default-source 2>/dev/null) == \"$vmic\" ]]; then",
    "  mic=$(head -n1 \"$state_dir/last-mic\" 2>/dev/null)",
    "  [[ -n $mic ]] && pactl set-default-source \"$mic\"",
    "fi",
    "pactl list short modules 2>/dev/null | awk -F '\\t' -v vmic=\"$vmic\" '$2 == \"module-remap-source\" && index(\" \" $3 \" \", \" source_name=\" vmic \" \") { print $1 }' | xargs -r -n1 pactl unload-module"
  ].join("\n")

  Component.onDestruction: {
    Quickshell.execDetached(["bash", "-c", cleanupScript, "omahorn-cleanup",
      shellJsonPath, bindsPath, stateDir,
      Hotkeys.evalCode(appId, [], appliedKeys), vmicName, pluginId])
  }

  // Directories first, then state, then the config that starts everything.
  Process {
    id: initProc
    onExited: stateFile.path = root.stateDir + "/state.json"
  }

  FileView {
    id: stateFile
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (parsed && typeof parsed === "object") root.appState = parsed
      } catch (e) {
        root.warn("ignoring unreadable state.json: " + e)
      }
      root.loadConfig()
    }
    onLoadFailed: root.loadConfig()
  }

  function loadConfig() {
    if (configFile.path === "") configFile.path = configDir + "/config.json"
  }

  function saveState(patch) {
    var next = JSON.parse(JSON.stringify(appState || {}))
    for (var key in patch) next[key] = patch[key]
    appState = next
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: configFile
    printErrors: false
    watchChanges: true
    atomicWrites: true
    onLoaded: root.loadConfigText(text())
    onLoadFailed: function(error) {
      if (root.ready) return
      if (error === FileViewError.FileNotFound) {
        // No config yet: first run. Look for a Soundux library to start from.
        sounduxFile.path = root.sounduxConfigPath
        return
      }
      // Unreadable but present: run on defaults and leave the file alone.
      root.configBroken = true
      root.report("Could not read config.json (" + FileViewError.toString(error) + "); using defaults until it is fixed")
      root.applyConfig(Config.defaults(), false)
    }
    // Editors and shell redirects write in steps; read once they settle.
    onFileChanged: configReloadTimer.restart()
  }

  Timer {
    id: configReloadTimer
    interval: 250
    onTriggered: configFile.reload()
  }

  FileView {
    id: sounduxFile
    printErrors: false
    onLoaded: root.startFirstRun(text())
    onLoadFailed: root.startFirstRun("")
  }

  property string configText: ""
  // config.json exists but does not parse. Until it is fixed, nothing is
  // written to it: saving would replace the user's settings with whatever
  // Omahorn fell back to.
  property bool configBroken: false

  function startFirstRun(sounduxText) {
    var result = Config.firstRun(sounduxText)
    firstRun = true
    importedSoundux = result.imported
    log(result.imported ? "first run: imported the Soundux library" : "first run")
    var folder = Config.DEFAULT_FOLDER.replace(/^~/, home)
    Quickshell.execDetached(["mkdir", "-p", folder])
    applyConfig(result.config, true)
    if (result.imported) report("Imported your Soundux library", "info")
  }

  function loadConfigText(text) {
    var raw = String(text || "")
    if (ready && raw === configText) return
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      configBroken = true
      if (!ready) {
        report("config.json is not valid JSON (" + e + "); using defaults until it is fixed")
        applyConfig(Config.defaults(), false)
      } else {
        report("config.json has a syntax error; keeping the previous settings until it is fixed")
      }
      return
    }
    if (configBroken) log("config.json is valid again")
    configBroken = false
    applyConfig(Config.normalize(parsed), false)
  }

  // Adopts a config and runs whatever its changes require. `save` writes it
  // back; edits made to the file by hand arrive here with save = false.
  // `adopted` marks a change the system already made (the user picked another
  // default input elsewhere), which must not be pushed back to it.
  function applyConfig(next, save, adopted) {
    var previous = config
    var wasReady = ready
    config = next
    configText = JSON.stringify(next, null, 2) + "\n"
    if (save && !configBroken) configFile.setText(configText)
    if (!wasReady) {
      ready = true
      setupAudio()
      rescan()
      syncBinds()
      return
    }
    if (JSON.stringify(previous.folders) !== JSON.stringify(next.folders)) rescan()
    else if (JSON.stringify(previous.sounds) !== JSON.stringify(next.sounds)) sounds = mergeSoundSettings(sounds, next)
    if (JSON.stringify(previous.hotkeys) !== JSON.stringify(next.hotkeys)
        || JSON.stringify(Config.usedKeys(previous)) !== JSON.stringify(Config.usedKeys(next))) syncBinds()
    if (previous.routing !== next.routing) {
      log("routing: " + next.routing)
      setupAudio()
      return
    }
    if (JSON.stringify(previous.exclude) !== JSON.stringify(next.exclude)) refreshTargets()
    if (next.routing !== "vmic") return
    if (previous.mic !== next.mic) audioCommand(["set-mic", next.mic])
    if (previous.defaultMic !== next.defaultMic && !adopted) {
      audioCommand(["set-default", next.defaultMic ? "on" : "off"], function(status) {
        if (next.defaultMic && status.isDefault) saveState({ defaultApplied: true })
        if (!status.ok) report(status.error)
      })
    }
  }

  function setSetting(key, value) {
    if (!ready) return
    applyConfig(Config.withSetting(config, key, value), true)
  }

  // The same setting without touching the system, when the system already
  // changed (the user picked another default input elsewhere).
  function adoptSetting(key, value) {
    if (!ready || config[key] === value) return
    applyConfig(Config.withSetting(config, key, value), true, true)
  }

  function mergeSoundSettings(list, cfg) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      var saved = cfg.sounds[s.path] || {}
      var copy = {}
      for (var k in s) copy[k] = s[k]
      copy.favorite = saved.favorite === true
      copy.volume = saved.volume || 100
      copy.hotkey = saved.hotkey ? { keys: saved.hotkey.keys, label: saved.hotkey.label } : null
      out.push(copy)
    }
    return out
  }

  // ------------------------------------------------------------- library

  function rescan() {
    if (!ready) return
    if (scanning) {
      rescanQueued = true
      return
    }
    scanning = true
    scanProc.run([pluginDir + "/bin/omahorn-scan", JSON.stringify(config.folders)])
  }

  // Cheap enough to run on every open: only new files get probed.
  function refreshIfStale() {
    if (Date.now() - scannedAt > 3000) rescan()
  }

  Command {
    id: scanProc
    onFinished: function(exitCode, output, errorOutput) {
      if (errorOutput.trim()) root.warn("scan: " + errorOutput.trim())
      if (exitCode === 0) root.applyScan(output)
      else root.report("Could not read the sound folders (exit " + exitCode + ")")
      root.scanning = false
      if (root.rescanQueued) {
        root.rescanQueued = false
        Qt.callLater(root.rescan)
      }
    }
  }

  function applyScan(text) {
    var list = Library.parseScan(text, config.sounds)
    scannedAt = Date.now()
    // Rescans on every board open are the common case; leave the grid alone
    // when nothing on disk changed.
    if (JSON.stringify(list) !== JSON.stringify(sounds)) sounds = list
    queueDecodes(list)
    queuePeaks(list)
  }

  // ------------------------------------------------------------- waveforms

  // { soundId: { key, values } }. `key` follows the file's size and mtime,
  // so an edited sound gets a new envelope.
  property var peaks: ({})
  property var peaksIncoming: ({})
  property bool peaksQueued: false
  // Sounds ffmpeg could not read, by the key they failed with: skipped until
  // the file changes.
  property var peaksFailed: ({})

  function peaksKey(sound) {
    return Library.hash(sound.path + "|" + sound.size + "|" + sound.mtime)
  }

  function queuePeaks(list) {
    var items = []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      var key = peaksKey(s)
      if (peaks[s.id] && peaks[s.id].key === key) continue
      if (peaksFailed[s.id] === key) continue
      items.push({ id: s.id, path: s.path, duration: s.duration || 0, key: key })
    }
    if (items.length === 0) return
    if (peaksProc.running) {
      peaksQueued = true
      return
    }
    // One argv string holds at most 128 KiB; a few hundred sounds per run
    // stays well under it, and the rest follow when this batch exits.
    var batch = items.slice(0, 300)
    if (items.length > batch.length) peaksQueued = true
    peaksProc.keys = {}
    for (var j = 0; j < batch.length; j++) peaksProc.keys[batch[j].id] = batch[j].key
    peaksProc.exec([pluginDir + "/bin/omahorn-peaks", cacheDir, JSON.stringify(batch)])
  }

  Process {
    id: peaksProc
    property var keys: ({})
    stdout: SplitParser {
      onRead: function(line) {
        var item
        try { item = JSON.parse(line) } catch (e) { return }
        if (!item || typeof item.id !== "string" || !Array.isArray(item.peaks)) return
        root.peaksIncoming[item.id] = { key: peaksProc.keys[item.id] || "", values: item.peaks }
        peaksFlush.restart()
      }
    }
    onExited: {
      root.flushPeaks()
      // Anything this batch did not deliver is retried with the next one, so
      // record a failure for it instead of asking again forever.
      for (var id in peaksProc.keys) {
        if (!root.peaks[id] || root.peaks[id].key !== peaksProc.keys[id]) root.peaksFailed[id] = peaksProc.keys[id]
      }
      if (root.peaksQueued) {
        root.peaksQueued = false
        Qt.callLater(function() { root.queuePeaks(root.sounds) })
      }
    }
  }

  // Envelopes stream in one per line; hand them to the pads in batches.
  Timer {
    id: peaksFlush
    interval: 120
    onTriggered: root.flushPeaks()
  }

  function flushPeaks() {
    var incoming = peaksIncoming
    if (Object.keys(incoming).length === 0) return
    peaksIncoming = {}
    var next = {}
    for (var id in peaks) next[id] = peaks[id]
    for (var newId in incoming) next[newId] = incoming[newId]
    peaks = next
  }

  // ------------------------------------------------------------- decoding

  function needsDecode(sound) {
    return sound && !Library.isNative(sound.ext)
  }

  function queueDecodes(list) {
    var queue = decodeQueue.slice()
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (!needsDecode(s)) continue
      var target = Library.decodedPath(cacheDir, s)
      if (decoded[target] || queue.some(function(job) { return job.target === target })) continue
      queue.push({ source: s.path, target: target, playAfter: null })
    }
    decodeQueue = queue
    runNextDecode()
  }

  property var decodeJob: null

  function runNextDecode() {
    if (decodeJob || decodeQueue.length === 0) return
    decodeJob = decodeQueue[0]
    decodeQueue = decodeQueue.slice(1)
    decodeProc.run([pluginDir + "/bin/omahorn-decode", decodeJob.source, decodeJob.target], decodeJob)
  }

  Command {
    id: decodeProc
    onFinished: function(exitCode, output, errorOutput, job) {
      root.decodeJob = null
      if (exitCode === 0) {
        var next = {}
        for (var k in root.decoded) next[k] = root.decoded[k]
        next[job.target] = true
        root.decoded = next
        if (job.playAfter) root.play(job.playAfter.id, job.playAfter.options)
      } else {
        root.warn("decode failed for " + job.source + ": " + errorOutput.trim())
        if (job.playAfter) root.report("Could not convert " + job.source.split("/").pop() + " for playback")
      }
      Qt.callLater(root.runNextDecode)
    }
  }

  // ------------------------------------------------------------- playback

  function soundById(id) {
    for (var i = 0; i < sounds.length; i++) if (sounds[i].id === id) return sounds[i]
    return null
  }

  function soundForPath(path) {
    for (var i = 0; i < sounds.length; i++) if (sounds[i].path === path) return sounds[i]
    return null
  }

  function spaString(text) {
    return "\"" + String(text || "").replace(/[\u0000-\u001f"\\]/g, " ").slice(0, 96) + "\""
  }

  function streamProps(role, sound) {
    var props = [
      "application.name = \"Omahorn\"",
      "application.id = \"omahorn\"",
      "node.name = \"omahorn." + role + "\"",
      "media.name = " + spaString(sound.name),
      "state.restore-props = false",
      "state.restore-target = false"
    ]
    // The mic copy must never fall back to the speakers if the virtual
    // microphone is missing; pw-play then fails and we can say so.
    if (role === "mic") props.push("node.dont-fallback = true", "node.dont-reconnect = true")
    return "{ " + props.join(" ") + " }"
  }

  function playCommand(file, target, amplitude, role, sound) {
    var cmd = ["pw-play", "--volume", amplitude.toFixed(4), "-P", streamProps(role, sound)]
    if (target) cmd.push("--target", target)
    cmd.push(file)
    return cmd
  }

  // options: { preview: bool } — a preview plays only for you.
  function play(id, options) {
    var sound = soundById(id)
    if (!sound) {
      report("That sound is no longer in the library")
      return false
    }
    var opts = options || {}
    var preview = opts.preview === true

    var file = sound.path
    var decodedTarget = ""
    if (needsDecode(sound)) {
      var target = Library.decodedPath(cacheDir, sound)
      if (!decoded[target]) {
        var queue = decodeQueue.filter(function(job) { return job.target !== target })
        if (decodeJob && decodeJob.target === target) decodeJob.playAfter = { id: id, options: opts }
        else queue.unshift({ source: sound.path, target: target, playAfter: { id: id, options: opts } })
        decodeQueue = queue
        runNextDecode()
        report("Preparing " + sound.name + "…", "info")
        return true
      }
      file = target
      decodedTarget = target
    }

    var keepOthers = config.overlap
    for (var key in voices) {
      if (!keepOthers || voices[key].soundId === id) stopVoice(key)
    }

    var toMic = !preview && micReady
    var toMonitor = preview || config.monitor
    if (!preview && !micReady) {
      report(audio.error ? audio.error : "Omahorn Microphone is not ready; playing only for you")
      audioCommand(["ensure", config.mic])
      toMonitor = true
    }
    var gain = sound.volume || 100
    var micAmplitude = Library.amplitude(config.micVolume * gain / 100)
    var parts = []
    if (toMic && injecting) parts.push({ role: "mic", command: [pluginDir + "/bin/omahorn-inject", "play", file, micAmplitude.toFixed(4), sound.name, JSON.stringify(config.exclude)] })
    else if (toMic) parts.push({ role: "mic", command: playCommand(file, captureName, micAmplitude, "mic", sound) })
    if (toMonitor) parts.push({ role: "monitor", command: playCommand(file, "", Library.amplitude(config.monitorVolume * gain / 100), "monitor", sound) })
    if (parts.length === 0) return false

    voiceSerial++
    var voiceKey = "v" + voiceSerial
    var voice = {
      key: voiceKey,
      soundId: sound.id,
      name: sound.name,
      startedAt: Date.now(),
      duration: sound.duration,
      preview: preview,
      decodedTarget: decodedTarget,
      missingFile: false,
      retried: opts.retried === true,
      options: opts,
      procs: [],
      failure: "",
      stopped: false
    }
    for (var p = 0; p < parts.length; p++) {
      var proc = processComponent.createObject(root, { voiceKey: voiceKey, role: parts[p].role })
      if (!proc) continue
      voice.procs.push(proc)
      proc.run(parts[p].command)
    }
    var nextVoices = {}
    for (var vk in voices) nextVoices[vk] = voices[vk]
    nextVoices[voiceKey] = voice
    voices = nextVoices
    trimVoices()
    syncPlaying()
    return true
  }

  // Keeps overlapping playback bounded; the oldest voices go first.
  function trimVoices() {
    var keys = Object.keys(voices)
    while (keys.length > 8) {
      stopVoice(keys.shift())
    }
  }

  function stopVoice(key) {
    var voice = voices[key]
    if (!voice) return
    voice.stopped = true
    for (var i = 0; i < voice.procs.length; i++) {
      if (voice.procs[i].running) voice.procs[i].signal(15)
    }
  }

  function stop(id) {
    for (var key in voices) if (voices[key].soundId === id) stopVoice(key)
  }

  function stopAll() {
    for (var key in voices) stopVoice(key)
  }

  function isSoundPlaying(id) {
    for (var i = 0; i < playing.length; i++) if (playing[i].id === id) return true
    return false
  }

  function syncPlaying() {
    var list = []
    for (var key in voices) {
      var v = voices[key]
      list.push({ key: v.key, id: v.soundId, name: v.name, startedAt: v.startedAt, duration: v.duration, preview: v.preview })
    }
    playing = list
  }

  function processExited(proc, exitCode, errorText) {
    var voice = voices[proc.voiceKey]
    if (voice && proc.role === "mic" && injecting && !voice.stopped && (exitCode === 3 || exitCode === 4)) {
      // Nobody to play into is news, not an error: say so once, and let a
      // copy you are hearing carry on.
      var heard = voice.procs.length > 1
      report(exitCode === 3
        ? "No app is recording a microphone" + (heard ? "; " + voice.name + " plays only for you" : "")
        : "The app recording your microphone went away mid-sound", heard ? "info" : "error")
      refreshTargets()
      exitCode = 0
    }
    if (voice) {
      voice.procs = voice.procs.filter(function(p) { return p !== proc })
      if (exitCode !== 0 && !voice.stopped) {
        var detail = String(errorText || "").trim().split("\n").filter(function(l) { return l.trim() })
        var reason = detail.length ? detail[detail.length - 1] : "exit " + exitCode
        if (proc.role === "mic" && /target not found/i.test(reason)) reason = "Omahorn Microphone disappeared"
        voice.failure = reason
        voice.missingFile = voice.missingFile || /No such file or directory/i.test(String(errorText || ""))
      }
      if (voice.procs.length === 0) {
        var next = {}
        for (var key in voices) if (key !== voice.key) next[key] = voices[key]
        voices = next
        syncPlaying()
        if (voice.failure && voice.missingFile && voice.decodedTarget && !voice.retried && !voice.stopped) {
          // The converted copy went missing (a cleared cache): convert again.
          var nextDecoded = {}
          for (var target in decoded) if (target !== voice.decodedTarget) nextDecoded[target] = decoded[target]
          decoded = nextDecoded
          var retryOptions = { preview: voice.preview, retried: true }
          Qt.callLater(function() { root.play(voice.soundId, retryOptions) })
        } else if (voice.failure) {
          report("Could not play " + voice.name + ": " + voice.failure)
          if (!injecting && /Microphone/.test(voice.failure)) audioCommand(["ensure", config.mic])
        }
      }
    }
    proc.destroy()
  }

  Component {
    id: processComponent

    Command {
      id: proc
      property string voiceKey: ""
      property string role: ""
      onFinished: function(exitCode, output, errorOutput) { root.processExited(proc, exitCode, errorOutput) }
    }
  }

  function playRandom(category) {
    var tab = category && category !== "all" ? category : "all"
    var pool = Library.filterSounds(sounds, "", tab)
    if (pool.length === 0) return false
    return play(pool[Math.floor(Math.random() * pool.length)].id, {})
  }

  // ------------------------------------------------------------- sound settings

  function toggleFavorite(id) {
    var s = soundById(id)
    if (!s) return
    applyConfig(Config.withSound(config, s.path, { favorite: !s.favorite }), true)
  }

  function setSoundVolume(id, volume) {
    var s = soundById(id)
    if (!s) return
    applyConfig(Config.withSound(config, s.path, { volume: Math.max(5, Math.min(200, Math.round(volume))) }), true)
  }

  // ------------------------------------------------------------- microphone

  property var audioQueue: []
  property var audioJob: null

  function audioCommand(args, callback) {
    audioQueue = audioQueue.concat([{ args: args, callback: callback || null }])
    runNextAudio()
  }

  function runNextAudio() {
    if (audioJob || audioQueue.length === 0) return
    audioJob = audioQueue[0]
    audioQueue = audioQueue.slice(1)
    audioProc.run([pluginDir + "/bin/omahorn-audio"].concat(audioJob.args), audioJob)
  }

  function applyAudioOutput(text, errorText, job) {
    var before = audio
    var status = null
    try { status = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (e) { status = null }
    if (!status || typeof status !== "object") {
      warn("omahorn-audio " + job.args.join(" ") + " printed no status: " + String(errorText || "").trim())
      status = { ok: false, error: "Could not query the audio setup", present: before.present, mic: before.mic, micDescription: before.micDescription, isDefault: before.isDefault, sources: before.sources || [], listeners: [] }
    }
    audio = status
    audioJob = null
    if (job && job.callback) {
      try { job.callback(status, before) } catch (e) { warn("audio callback failed: " + e) }
    }
    Qt.callLater(runNextAudio)
  }

  Command {
    id: audioProc
    onFinished: function(exitCode, output, errorOutput, job) { root.applyAudioOutput(output, errorOutput, job) }
  }

  function setupAudio() {
    if (injecting) {
      audioReady = true
      retireVmic()
      refreshTargets()
      return
    }
    retireTimer.stop()
    audioCommand(["ensure", config.mic], function(status, before) {
      if (!status.ok) report(status.error)
      audioReady = true
      lastDefaultSource = defaultSourceName
      // WirePlumber restores a configured default a moment after the node
      // appears, so judge the default only once it had the chance.
      if (status.present && !before.present) reconcileTimer.restart()
      else reconcileDefault()
    })
  }

  Timer {
    id: reconcileTimer
    interval: 1500
    onTriggered: root.reconcileDefault()
  }

  function reconcileDefault() {
    audioCommand(["status"], function(status) {
      if (injecting || !status.present) return
      if (config.defaultMic && !status.isDefault) {
        if (!appState.defaultApplied) {
          audioCommand(["set-default", "on"], function(after) {
            if (after.isDefault) {
              saveState({ defaultApplied: true })
              log("Omahorn Microphone is now the default input")
            } else if (after.error) report(after.error)
          })
        } else {
          // The user moved the default elsewhere since; follow them.
          adoptSetting("defaultMic", false)
        }
      } else if (!config.defaultMic && status.isDefault) {
        adoptSetting("defaultMic", true)
      }
    })
  }

  function setMic(name) {
    setSetting("mic", name || "auto")
  }

  function refreshAudio() {
    if (injecting) refreshTargets()
    else if (!audioJob && audioQueue.length === 0) audioCommand(["status"])
  }

  // Injecting leaves no use for a virtual mic made earlier, but an app may be
  // recording it right now, mid-call: only take it away once nobody is.
  function retireVmic() {
    audioCommand(["status"], function(status) {
      if (!injecting || !status.present) return
      if ((status.listeners || []).length > 0) {
        retireTimer.restart()
        return
      }
      audioCommand(["teardown"], function(after) {
        if (!after.present) log("removed Omahorn Microphone; sounds now go straight into apps")
        else if (after.error) report(after.error)
      })
    })
  }

  Timer {
    id: retireTimer
    interval: 30000
    onTriggered: if (root.injecting) root.retireVmic()
  }

  // --------------------------------------------------- inject targets

  function refreshTargets() {
    if (!injecting || targetsProc.running) return
    targetsProc.run([pluginDir + "/bin/omahorn-inject", "list", JSON.stringify(config.exclude)])
  }

  Command {
    id: targetsProc
    onFinished: function(exitCode, output) {
      var list = null
      try { list = JSON.parse(String(output || "").trim() || "[]") } catch (e) { list = null }
      if (Array.isArray(list) && JSON.stringify(list) !== JSON.stringify(root.injectTargets)) root.injectTargets = list
    }
  }

  // Apps that recorded a microphone at some point this session, so ones you
  // excluded stay listed (and can be let back in) while they are idle.
  property var seenApps: []
  onInjectTargetsChanged: {
    var next = seenApps.slice()
    for (var i = 0; i < injectTargets.length; i++) {
      var t = injectTargets[i]
      if (!next.some(function(a) { return a.app === t.app })) next.push({ app: t.app, binary: t.binary, label: Library.appLabel(t.app, t.binary) })
    }
    if (next.length !== seenApps.length) seenApps = next
  }

  function appExcluded(app) {
    var names = config.exclude || []
    return names.indexOf(app.app) !== -1 || (app.binary && names.indexOf(app.binary) !== -1)
  }

  function setAppExcluded(app, excluded) {
    var key = app.binary || app.app
    var names = (config.exclude || []).filter(function(n) { return n !== app.app && n !== app.binary })
    if (excluded) names.push(key)
    setSetting("exclude", names)
  }

  // Default input changes made anywhere (Omarchy's audio panel, pavucontrol)
  // decide whether Omahorn is the default mic and which mic it passes on.
  readonly property string defaultSourceName: Pipewire.defaultAudioSource ? String(Pipewire.defaultAudioSource.name || "") : ""
  readonly property bool vmicNodePresent: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) if (nodes[i] && nodes[i].name === root.vmicName) return true
    return false
  }
  property string lastDefaultSource: ""
  // Only a virtual mic this instance has seen can go missing; the node list
  // may simply not have arrived yet at startup.
  property bool vmicSeen: false

  onDefaultSourceNameChanged: defaultSourceTimer.restart()
  onVmicNodePresentChanged: {
    if (vmicNodePresent) vmicSeen = true
    else if (audioReady && vmicSeen) vmicLostTimer.restart()
  }

  Timer {
    id: defaultSourceTimer
    interval: 400
    onTriggered: root.handleDefaultSourceChange()
  }

  // The virtual mic vanished (PipeWire restarted, someone unloaded it):
  // bring it back once things settle.
  Timer {
    id: vmicLostTimer
    interval: 2500
    onTriggered: if (!root.injecting && !root.vmicNodePresent) {
      root.log("virtual microphone missing, recreating it")
      root.audioCommand(["ensure", root.config.mic])
    }
  }

  function handleDefaultSourceChange() {
    if (injecting) return
    var name = defaultSourceName
    if (!audioReady || !name || name === lastDefaultSource) {
      if (name) lastDefaultSource = name
      return
    }
    lastDefaultSource = name
    if (name === vmicName) {
      adoptSetting("defaultMic", true)
      refreshAudio()
      return
    }
    // Losing the virtual mic also moves the default; that is not a choice.
    if (!vmicNodePresent) return
    adoptSetting("defaultMic", false)
    if (config.mic === "auto") audioCommand(["set-mic", "auto"])
    else refreshAudio()
  }

  // While the board is open, keep the listener list and mic picker fresh.
  Timer {
    interval: 3000
    repeat: true
    running: root.boardOpen && root.ready
    onTriggered: root.refreshAudio()
  }

  // ------------------------------------------------------------- hotkeys

  function soundLabel(path) {
    var s = soundForPath(path)
    return s ? s.name : Library.prettyName(String(path).split("/").pop())
  }

  function computeShortcuts(cfg) {
    var list = []
    if (cfg.hotkeys.toggle) list.push({ name: "toggle", keys: cfg.hotkeys.toggle.keys, label: cfg.hotkeys.toggle.label, action: "toggle", description: bindPrefix + "open soundboard" })
    if (cfg.hotkeys.stop) list.push({ name: "stop", keys: cfg.hotkeys.stop.keys, label: cfg.hotkeys.stop.label, action: "stop", description: bindPrefix + "stop all sounds" })
    for (var path in cfg.sounds) {
      var hk = cfg.sounds[path].hotkey
      if (!hk) continue
      var name = path.split("/").pop()
      list.push({ name: "play-" + Library.soundId(path), keys: hk.keys, label: hk.label, action: "play", path: path, description: bindPrefix + "play " + Library.prettyName(name) })
    }
    return list
  }

  function runShortcut(entry) {
    if (!entry) return
    if (entry.action === "toggle") toggleBoard()
    else if (entry.action === "stop") stopAll()
    else if (entry.action === "play") {
      var s = soundForPath(entry.path)
      if (s) play(s.id, {})
      else report("Hotkey " + entry.label + ": " + Library.prettyName(String(entry.path).split("/").pop()) + " is missing")
    }
  }

  Instantiator {
    model: root.ready && root.hotkeysEnabled ? root.shortcuts : []

    delegate: GlobalShortcut {
      required property var modelData
      appid: root.appId
      name: modelData.name
      description: modelData.description
      onPressed: root.runShortcut(modelData)
    }
  }

  // Keys an earlier instance bound (it may have died without cleaning up)
  // come from the file it left, so the first sync can release them.
  property bool bindsAdopted: false

  function adoptPreviousBinds() {
    if (bindsAdopted) return
    bindsAdopted = true
    var text = ""
    try { text = bindsFile.text() } catch (e) { text = "" }
    var keys = appliedKeys.slice()
    var fromFile = Hotkeys.keysInBindsFile(text)
    for (var i = 0; i < fromFile.length; i++) if (keys.indexOf(fromFile[i]) === -1) keys.push(fromFile[i])
    appliedKeys = keys
  }

  // Keys Hyprland currently binds for Omahorn, whoever bound them: an earlier
  // instance, a reload of the binds file. Releasing them before binding is
  // what keeps a key from ending up bound twice, which would fire twice.
  // A key the user also bound is left alone, since unbinding is per key.
  function ownBindsInHyprland() {
    var own = []
    var shared = {}
    for (var i = 0; i < hyprBinds.length; i++) {
      var b = hyprBinds[i]
      if (b.description.indexOf(bindPrefix) !== 0) shared[b.mask + "|" + b.key] = true
    }
    for (var j = 0; j < hyprBinds.length; j++) {
      var o = hyprBinds[j]
      if (o.description.indexOf(bindPrefix) !== 0 || shared[o.mask + "|" + o.key]) continue
      if (Hotkeys.isValidKeys(o.combo) && own.indexOf(o.combo) === -1) own.push(o.combo)
    }
    return own
  }

  // Hotkeys left unbound because a Hyprland bind of the user's own already
  // has their keys: [{ name, label, by }].
  property var blockedHotkeys: []

  // Binds always start from a fresh look at Hyprland's own: a default must
  // never land on a key the user bound, and every bind Omahorn already has
  // is released first so none is ever doubled.
  function syncBinds() {
    if (!ready || !hotkeysEnabled) return
    refreshHyprBinds(applyBinds)
  }

  function applyBinds() {
    if (!ready || !hotkeysEnabled) return
    adoptPreviousBinds()
    var bindings = []
    var blocked = []
    if (!hotkeysSuspended) {
      for (var i = 0; i < shortcuts.length; i++) {
        var sc = shortcuts[i]
        var taken = Hotkeys.findConflict(hyprBinds, sc.keys, "", bindPrefix)
        if (taken) blocked.push({ name: sc.name, label: sc.label, by: taken.description || "another binding" })
        else bindings.push({ keys: sc.keys, name: sc.name, description: sc.description })
      }
      if (JSON.stringify(blocked) !== JSON.stringify(blockedHotkeys)) {
        blockedHotkeys = blocked
        if (blocked.length > 0) {
          report(blocked.map(function(b) { return b.label + " is taken by " + b.by }).join("; ")
            + ". Pick other keys in Omahorn's settings.")
        }
      }
    }
    if (!hotkeysSuspended) {
      var content = Hotkeys.bindsFile(appId, bindings)
      if (content !== lastBindsFile) {
        lastBindsFile = content
        bindsFile.setText(content)
      }
    }
    var code = Hotkeys.evalCode(appId, bindings, appliedKeys.concat(ownBindsInHyprland()))
    appliedKeys = bindings.map(function(b) { return b.keys })
    if (code) hyprEval(code)
    log("hotkeys: " + bindings.length + " bound" + (blockedHotkeys.length ? ", " + blockedHotkeys.length + " taken by Hyprland binds" : "")
      + (hotkeysSuspended ? " (suspended while recording)" : ""))
  }

  FileView {
    id: bindsFile
    path: root.bindsPath
    printErrors: false
    atomicWrites: true
    // Read once, at the first sync, and it is a few lines: blocking is fine.
    blockLoading: true
  }

  property var evalQueue: []

  function hyprEval(code) {
    evalQueue = evalQueue.concat([code])
    runNextEval()
  }

  property bool evalBusy: false

  function runNextEval() {
    if (evalBusy || evalQueue.length === 0) return
    evalBusy = true
    var code = evalQueue[0]
    evalQueue = evalQueue.slice(1)
    evalProc.run(["hyprctl", "eval", code])
  }

  Command {
    id: evalProc
    onFinished: function(exitCode, output, errorOutput) {
      if (exitCode !== 0) root.warn("hyprctl eval failed (" + exitCode + "): " + (output + errorOutput).trim())
      root.evalBusy = false
      Qt.callLater(root.runNextEval)
    }
  }

  // While a hotkey is being recorded our own binds would swallow the keys,
  // so they step aside until recording ends.
  function suspendHotkeys() {
    if (!hotkeysEnabled) {
      refreshHyprBinds(null)
      return
    }
    if (hotkeysSuspended) return
    hotkeysSuspended = true
    syncBinds()
    refreshHyprBinds(null)
  }

  function resumeHotkeys() {
    if (!hotkeysSuspended) return
    hotkeysSuspended = false
    syncBinds()
  }

  property var bindsWaiters: []

  function refreshHyprBinds(callback) {
    if (callback) bindsWaiters = bindsWaiters.concat([callback])
    if (!bindsProc.running && !bindsProc.pending) {
      bindsProc.pending = true
      bindsProc.run(["hyprctl", "binds"])
    }
  }

  Command {
    id: bindsProc
    property bool pending: false
    onFinished: function(exitCode, output) {
      bindsProc.pending = false
      if (exitCode === 0) root.hyprBinds = Hotkeys.parseHyprBinds(output)
      else root.warn("hyprctl binds failed (" + exitCode + "); hotkeys are bound without a conflict check")
      var waiters = root.bindsWaiters
      root.bindsWaiters = []
      for (var i = 0; i < waiters.length; i++) waiters[i]()
    }
  }

  // What already uses these keys: another Omahorn hotkey or a Hyprland bind.
  // Returns null when they are free.
  function hotkeyConflict(hotkey, owner) {
    if (!hotkey) return null
    var used = Config.usedKeys(config)[hotkey.keys]
    if (used) {
      var ownerMatches = owner && ((used.kind === "action" && owner.action === used.name) || (used.kind === "sound" && owner.path === used.path))
      if (!ownerMatches) {
        return {
          kind: "omahorn",
          description: used.kind === "sound" ? soundLabel(used.path) : (used.name === "toggle" ? "Open soundboard" : "Stop all sounds"),
          used: used
        }
      }
    }
    var bind = Hotkeys.findConflict(hyprBinds, hotkey.keys, hotkey.keysym, bindPrefix)
    if (bind) return { kind: "hyprland", description: bind.description || "another binding" }
    return null
  }

  // owner: { action: "toggle" | "stop" } or { path }. hotkey null clears it.
  // A key taken by another Omahorn hotkey moves here; Hyprland binds are
  // never overridden (the board refuses those before calling this).
  function assignHotkey(owner, hotkey) {
    var value = hotkey ? { keys: hotkey.keys, label: hotkey.label } : null
    var next = config
    if (value) {
      var used = Config.usedKeys(next)[value.keys]
      if (used && used.kind === "sound" && used.path !== owner.path) next = Config.withSound(next, used.path, { hotkey: null })
      if (used && used.kind === "action" && used.name !== owner.action) next = Config.withHotkey(next, used.name, null)
    }
    if (owner.action) next = Config.withHotkey(next, owner.action, value)
    else if (owner.path) next = Config.withSound(next, owner.path, { hotkey: value })
    applyConfig(next, true)
  }

  // ------------------------------------------------------------- board

  // One press reaches here once, but two binds on the same key would undo
  // each other's toggle in the same instant; ignore the echo.
  property double lastToggle: 0

  function toggleBoard() {
    var now = Date.now()
    if (now - lastToggle < 250) return
    lastToggle = now
    if (shell && typeof shell.toggle === "function") shell.toggle(pluginId, "{}")
  }

  function openBoard() {
    if (shell && typeof shell.summon === "function") shell.summon(pluginId, "{}")
  }

  function closeBoard() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function openFolder(path) {
    var target = String(path || "").replace(/^~(?=\/|$)/, home)
    if (!target) return
    Quickshell.execDetached(["xdg-open", target])
  }

  function soundFolder(id) {
    var s = soundById(id)
    if (!s) return ""
    return s.path.slice(0, s.path.lastIndexOf("/")) || "/"
  }

  function statusJson() {
    return JSON.stringify({
      ready: ready,
      sounds: sounds.length,
      playing: playing.map(function(p) { return p.name }),
      routing: config.routing,
      listeners: listeners.map(function(l) { return l.label }),
      mic: { present: audio.present, default: audio.isDefault, passthrough: audio.mic, error: audio.error },
      hotkeys: shortcuts.map(function(s) { return { keys: s.label, action: s.action, path: s.path || "" } }),
      bound: appliedKeys,
      blocked: blockedHotkeys,
      configBroken: configBroken
    })
  }

  IpcHandler {
    target: "omahorn"

    function toggle(): void { root.toggleBoard() }
    function open(): void { root.openBoard() }
    function close(): void { root.closeBoard() }
    function stop(): void { root.stopAll() }
    function rescan(): void { root.rescan() }
    function status(): string { return root.statusJson() }

    function play(query: string): string {
      var s = Library.resolve(root.sounds, query)
      if (!s) return "not found"
      return root.play(s.id, {}) ? s.name : "failed"
    }

    function preview(query: string): string {
      var s = Library.resolve(root.sounds, query)
      if (!s) return "not found"
      return root.play(s.id, { preview: true }) ? s.name : "failed"
    }

    function random(category: string): string {
      return root.playRandom(category) ? "ok" : "empty"
    }

    function setRouting(mode: string): string {
      if (mode !== "inject" && mode !== "vmic") return "use inject or vmic"
      root.setSetting("routing", mode)
      return "ok"
    }

    function setDefaultMic(enabled: string): string {
      root.setSetting("defaultMic", enabled === "true" || enabled === "on")
      return "ok"
    }
  }
}
