# Omahorn

A soundboard for [Omarchy](https://omarchy.org). Press a key, and a sound plays
into your microphone: whoever is on the other end of the call, stream or game
hears it along with your voice.

![The board](docs/board.png)

It is an Omarchy shell plugin, not a separate app. The board is a keyboard-first
overlay drawn with the shell's own components, so it follows whatever theme you
use, and it costs nothing while you are not using it: no daemon, no web view, no
audio processing running in the background.

- **Plays into your mic**, the way Soundux does: each sound goes straight into
  the apps recording a microphone (Discord, the browser, games), mixed with your
  voice. No virtual device, no setup, nothing changes in your audio settings.
  Prefer a device? Switch to a virtual "Omahorn Microphone" instead.
- **You hear it too**, on your own output and at your own volume.
- **Global hotkeys** for any sound, bound through Hyprland, plus one to open the
  board and one to stop everything.
- **Folders are the library.** Point it at folders of audio files; subfolders
  become tabs. Coming from Soundux? Your tabs and favorites are imported on first run.
- **Waveforms on every pad**, filling in as the sound plays.
- Plays wav, flac, ogg, opus, mp3 and aiff directly; m4a, aac, webm, wma and
  friends are converted once with ffmpeg and cached.

## Requirements

Everything here ships with Omarchy 4; there is nothing to install.

- **Omarchy 4**, whose shell (`omarchy-shell`, Quickshell 0.3) hosts the plugin
- **PipeWire** with WirePlumber and pipewire-pulse: `pw-play`, `pw-link`,
  `pw-dump` and `pactl`
- **Hyprland**, for the global hotkeys
- `bash`, `jq`, `find` and the usual coreutils
- `ffmpeg` and `ffprobe`, for sound lengths, waveforms and playing m4a, aac,
  webm or wma. Without them sounds still play, just without those.

## Install

```bash
omarchy plugin add https://github.com/allankayan/omahorn.git --enable
```

Or from a local checkout:

```bash
ln -s ~/path/to/omahorn ~/.config/omarchy/plugins/io.github.allankayan.omahorn
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.allankayan.omahorn --before omarchy.audio
```

A bullhorn appears in the bar. Put sounds in `~/Music/Soundboard` (created on
first run) and press <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>M</kbd>.

## Using the board

Type to search; the board narrows as you type, accents and case ignored.

| Key | Does |
| --- | --- |
| <kbd>Enter</kbd> | Play the selected sound (and close the board) |
| <kbd>Shift</kbd>+<kbd>Enter</kbd> | Play and keep the board open |
| <kbd>Ctrl</kbd>+<kbd>Enter</kbd> | Preview: play only for you, not into the mic |
| <kbd>Alt</kbd>+<kbd>1</kbd>…<kbd>9</kbd> | Play the first nine sounds shown |
| Arrows, <kbd>PgUp</kbd>/<kbd>PgDn</kbd>, <kbd>Home</kbd>/<kbd>End</kbd> | Move around the pads |
| <kbd>Tab</kbd> / <kbd>Shift</kbd>+<kbd>Tab</kbd> | Next / previous tab |
| <kbd>Ctrl</kbd>+<kbd>F</kbd> | Favorite (favorites lead the list and get their own tab) |
| <kbd>Ctrl</kbd>+<kbd>K</kbd> | Set a global hotkey for the sound |
| <kbd>Ctrl</kbd>+<kbd>←</kbd>/<kbd>→</kbd> | Make this sound quieter / louder |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> | Stop everything |
| <kbd>Ctrl</kbd>+<kbd>O</kbd> | Open the sound's folder |
| <kbd>Ctrl</kbd>+<kbd>R</kbd> | Rescan the folders |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> | Settings |
| <kbd>Esc</kbd> | Clear the search, then close |

With the mouse: click a pad to play it, right-click to preview, middle-click (or
the star) to favorite, click the hotkey chip to set one.

The bar button opens the board, right-click stops all sounds, middle-click
toggles hearing them yourself. While something plays, the icon turns into an
equalizer.

### Hotkeys

![Recording a hotkey](docs/hotkey.png)

<kbd>Ctrl</kbd>+<kbd>K</kbd> on a pad, then press the combination. Use
<kbd>Super</kbd>, <kbd>Ctrl</kbd> or <kbd>Alt</kbd> with any key, or F13 and up
on their own, which is what macro keys on most keyboards send. Keys Hyprland
already uses are refused, with what uses them; a key another sound uses moves to
this one. <kbd>Backspace</kbd> removes the hotkey.

Hotkeys follow the physical key, so they keep working when you switch layouts.
Omahorn registers them as Hyprland global shortcuts and keeps the binds in
`~/.local/state/omarchy/toggles/hypr/omahorn.lua`, a folder Omarchy loads on
every Hyprland reload. Your own config files are never touched.

| Default | Does |
| --- | --- |
| <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>M</kbd> | Open / close the board |
| <kbd>Super</kbd>+<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>M</kbd> | Stop all sounds |

Both can be changed or cleared in settings.

### From scripts

The shell exposes Omahorn over IPC:

```bash
omarchy-shell omahorn play "airhorn"      # best match by name, or an exact path
omarchy-shell omahorn preview "airhorn"   # only for you
omarchy-shell omahorn random Memes        # a random sound, optionally from one tab
omarchy-shell omahorn stop
omarchy-shell omahorn toggle
omarchy-shell omahorn status              # JSON: mic, who is listening, what plays
```

To reach the board from the Omarchy menu as well, add a row to
`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"trigger.soundboard": {"icon":"󰃦","label":"Soundboard","action":"omarchy-shell omahorn toggle"},
```

## How it works

**Into apps** (the default). When you play a sound, Omahorn looks for the
streams recording a microphone right now and links the sound into each of them;
PipeWire mixes it with the microphone they already hear. The player is created
unlinked, which holds it at its first sample until the links exist, so nothing
is cut off. Your devices, defaults and voice path stay exactly as they were.

```
 your mic ─────────────────────────────┐
                                       ├──► Discord, browser, game (each app recording a mic)
 pw-play sound ──(linked per app)──────┘
 pw-play sound ──────────────────────────► your headphones
```

Every app recording a microphone gets your sounds unless you switch it off in
settings, where apps show up as they start recording. The catch: an app has to
be recording when the sound starts. Apps that only open the microphone while you
hold push-to-talk need you to hold it.

**Virtual mic** (optional). A single `module-remap-source` in pipewire-pulse
creates "Omahorn Microphone", which passes your real microphone through, and
sounds are played into it. Apps that pick that device, or use the default input
while it is the default, always hear sounds, push-to-talk or not. The passthrough
follows your default input, and Omahorn never fights you over which device is
the default. Switching back to *Into apps* removes the device as soon as no app
is using it, so a call in progress carries on.

Either way each sound is a short-lived `pw-play` per destination, and nothing
runs between sounds.

## Settings

![Settings](docs/settings.png)

<kbd>Ctrl</kbd>+<kbd>,</kbd> in the board covers everything: how sounds reach
people and which apps get them, the volume of sounds for them and for you,
overlap, hotkeys and folders. Changes save as you go to
`~/.config/omahorn/config.json`, which you can also edit by hand; the shell
picks edits up live.

```json
{
  "version": 1,
  "folders": [
    { "path": "~/Music/Soundboard", "recursive": true },
    { "path": "~/Downloads/audios", "name": "Memes" }
  ],
  "routing": "inject",
  "exclude": ["obs"],
  "mic": "auto",
  "defaultMic": true,
  "monitor": true,
  "micVolume": 80,
  "monitorVolume": 60,
  "overlap": false,
  "closeOnPlay": true,
  "sounds": {
    "/home/you/Music/Soundboard/airhorn.mp3": {
      "favorite": true,
      "volume": 120,
      "hotkey": { "keys": "SUPER + ALT + code:38", "label": "Super+Alt+A" }
    }
  }
}
```

| Key | |
| --- | --- |
| `folders` | Where sounds come from. `recursive` folders turn their subfolders into tabs; `name` renames the tab |
| `routing` | `inject`: straight into apps recording a microphone. `vmic`: through the Omahorn Microphone device |
| `exclude` | Apps (name or binary) that never get sounds injected |
| `mic` | Virtual mic: `auto` follows your default input; or a source name from `pactl list short sources` |
| `defaultMic` | Virtual mic: make Omahorn Microphone the system default input |
| `monitor` | Hear sounds yourself |
| `micVolume`, `monitorVolume` | 0–150%: what others hear, what you hear |
| `overlap` | Let sounds play over each other instead of replacing the one playing |
| `closeOnPlay` | Enter closes the board |
| `sounds` | Per-sound favorite, volume and hotkey, keyed by full path |

The file must stay valid JSON. If it stops parsing, Omahorn keeps running on
the last good settings (defaults, if it started that way) and writes nothing
to the file until it parses again.

## Troubleshooting

**People hear me but not the sounds.** In Discord, turn off *Noise
Suppression* (Krisp): it is built to remove anything that is not a voice, sounds
included. Then check the header of the board: *Live · Discord* means the app is
getting them. If it says *No app listening*, the app is not recording right now
(push-to-talk released, call not joined) or is switched off in settings. With
the virtual mic, set the app's input to *Default* or *Omahorn Microphone*.

**They hear the sounds twice, or with an echo.** You are probably on speakers,
and your microphone picks up the copy you hear. Use headphones, or turn off
*Hear sounds yourself*.

**"Mic offline" in the board** (virtual mic only). Check the module and the
shell's log:

```bash
pactl list short modules | grep omahorn_mic
qs log -p "$OMARCHY_PATH/shell" | grep omahorn
```

**A hotkey does nothing.** `hyprctl globalshortcuts` should list
`omahorn:play-…` for it, and `omarchy menu keybindings --print` the bind.

## Updating

```bash
omarchy plugin update io.github.allankayan.omahorn
omarchy restart shell
```

The shell keeps a plugin's service loaded across plugin reloads, so a new
version of Omahorn only takes over after the shell restarts.

## Uninstall

```bash
omarchy plugin remove io.github.allankayan.omahorn
```

This removes the hotkeys and, if you used it, the virtual microphone, restoring
your default input. Settings stay in `~/.config/omahorn`; delete that folder and
`~/.cache/omahorn` to remove everything.

## Development

```bash
dev/run              # run Omahorn in its own Quickshell instance
dev/run ipc toggle   # open the board there
dev/run key ctrl+k   # simulate a key press on the board
dev/run log          # follow its log
dev/run stop
node --test tests/   # unit tests for the logic in lib/
```

The dev instance opens the board on the monitor you are not using and without
taking the keyboard, and leaves hotkeys off, so it never fights an installed
Omahorn. `OMAHORN_DEV_FOCUS=1` and `OMAHORN_DEV_HOTKEYS=1` turn those back on.

The pieces:

| | |
| --- | --- |
| `Service.qml` | Library, playback, virtual microphone, hotkeys, IPC |
| `Board.qml` | The overlay |
| `BarWidget.qml` | The bar button |
| `components/` | Pads, waveform, settings page, hotkey recorder |
| `lib/` | Pure logic: search, config, hotkey parsing (tested with node) |
| `bin/omahorn-inject` | Finds the apps recording a microphone and plays into them |
| `bin/omahorn-audio` | Creates and manages the virtual microphone |
| `bin/omahorn-scan` | Lists the sound folders, with cached durations |
| `bin/omahorn-peaks` | Computes and caches waveforms |
| `bin/omahorn-decode` | Converts formats pw-play cannot read |

## License

MIT
