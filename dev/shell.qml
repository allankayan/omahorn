import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import ".." as Omaboard

// Development host: runs Omaboard in its own Quickshell instance, outside
// omarchy-shell, with a stand-in for the shell's plugin API. Commons and Ui
// are symlinks to Omarchy's own, so the board renders exactly as it will
// in the shell.
//
//   qs -p dev/shell.qml
//   qs -p dev/shell.qml ipc call omaboard toggle
ShellRoot {
  id: root

  QtObject {
    id: hostShell

    function summon(id, payload) { board.open(payload); return true }
    function hide(id) { board.close(); return true }
    function toggle(id, payload) { if (board.opened) board.close(); else board.open(payload); return true }
    function isPluginOpen(id) { return board.opened }
    function serviceFor(id) { return service }
    function updateEntryInline(id, settings) { return false }
  }

  // Hotkeys stay off unless asked for (OMABOARD_DEV_HOTKEYS=1), so the dev
  // instance never fights an installed Omaboard over the same keys.
  Omaboard.Service {
    id: service
    shell: hostShell
    manifest: ({ id: "omaboard" })
    appId: "omaboard-dev"
    hotkeysEnabled: Quickshell.env("OMABOARD_DEV_HOTKEYS") === "1"
  }

  // Opens on a monitor you are not using and leaves the keyboard alone;
  // OMABOARD_DEV_FOCUS=1 restores the real behaviour for hands-on testing.
  readonly property bool handsOn: Quickshell.env("OMABOARD_DEV_FOCUS") === "1"
  readonly property var quietScreen: {
    var focused = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (screens[i].name !== focused) return screens[i]
    return null
  }

  Omaboard.Board {
    id: board
    shell: hostShell
    service: service
    manifest: ({ id: "omaboard" })
    grabKeyboard: root.handsOn
    targetScreen: root.handsOn || Quickshell.env("OMABOARD_DEV_SCREEN") === "auto" ? null : root.quietScreen
  }

  // Simulated key presses, so the board's keyboard handling can be driven
  // without injecting input into the session:
  //   dev/run key ctrl+k     dev/run key Return     dev/run key b
  IpcHandler {
    target: "omaboard-dev"

    function key(spec: string): string {
      var parts = String(spec).split("+")
      var name = parts.pop()
      var mods = 0
      for (var i = 0; i < parts.length; i++) {
        var m = parts[i].toLowerCase()
        if (m === "ctrl") mods |= Qt.ControlModifier
        else if (m === "shift") mods |= Qt.ShiftModifier
        else if (m === "alt") mods |= Qt.AltModifier
        else if (m === "super") mods |= Qt.MetaModifier
      }
      var named = {
        Return: Qt.Key_Return, Escape: Qt.Key_Escape, Tab: Qt.Key_Tab, Backtab: Qt.Key_Backtab,
        Left: Qt.Key_Left, Right: Qt.Key_Right, Up: Qt.Key_Up, Down: Qt.Key_Down,
        Backspace: Qt.Key_Backspace, Delete: Qt.Key_Delete, Comma: Qt.Key_Comma, Space: Qt.Key_Space,
        Home: Qt.Key_Home, End: Qt.Key_End, F13: Qt.Key_F13, F5: Qt.Key_F5
      }
      var codes = { Return: 36, Escape: 9, Tab: 23, Backspace: 22, Delete: 119, Comma: 59, Space: 65, F13: 191, F5: 71 }
      var row = { q: 24, w: 25, e: 26, r: 27, t: 28, y: 29, u: 30, i: 31, o: 32, p: 33, a: 38, s: 39, d: 40, f: 41,
                  g: 42, h: 43, j: 44, k: 45, l: 46, z: 52, x: 53, c: 54, v: 55, b: 56, n: 57, m: 58 }
      var key = 0
      var text = ""
      var code = 0
      if (named[name] !== undefined) {
        key = named[name]
        code = codes[name] || 0
        if (name === "Space") text = " "
      } else if (/^[0-9]$/.test(name)) {
        key = Qt.Key_0 + Number(name)
        text = name
        code = name === "0" ? 19 : 9 + Number(name)
      } else if (/^[a-z]$/i.test(name)) {
        key = name.toUpperCase().charCodeAt(0)
        text = (mods & Qt.ControlModifier) ? "" : ((mods & Qt.ShiftModifier) ? name.toUpperCase() : name.toLowerCase())
        code = row[name.toLowerCase()]
      } else {
        return "unknown key " + name
      }
      var event = { key: key, modifiers: mods, text: text, nativeScanCode: code, accepted: false }
      return board.handleKey(event) ? "handled" : "ignored"
    }

    function type(text: string): string {
      for (var i = 0; i < text.length; i++) {
        var ch = text.charAt(i)
        board.handleKey({ key: ch.toUpperCase().charCodeAt(0), modifiers: 0, text: ch, nativeScanCode: 0, accepted: false })
      }
      return board.filterText
    }

    function screenName(): string {
      return root.quietScreen ? root.quietScreen.name : ""
    }

    function state(): string {
      return JSON.stringify({
        opened: board.opened, view: board.view, filter: board.filterText, tab: board.tab,
        selected: board.selectedSound ? board.selectedSound.name : null, shown: board.displayed.length,
        capturing: board.captureOwner !== null,
        capture: board.captureOwner ? { pending: board.captureState().pending, message: board.captureState().message, blocked: board.captureState().blocked } : null
      })
    }
  }
}
