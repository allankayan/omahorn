import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Hotkeys.js" as Hotkeys

// Records a key combination for a sound or a board action. The board routes
// every key here while it is open; plain Enter, Backspace and Escape are
// the commands, anything with a modifier (or F13 and up) is the hotkey.
Item {
  id: root

  property bool opened: false
  property string title: ""
  property var current: null
  property var pending: null
  property string message: ""
  property bool blocked: false
  property string heldModifiers: ""
  // function(hotkey) -> { kind: "hyprland" | "omahorn", description } | null
  property var conflictCheck: null

  property color background: Color.background
  property color foreground: Color.foreground
  property color scrim: Util.alpha(Color.background, 0.7)
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.menuFamily

  signal saved(var hotkey)
  signal canceled()

  visible: opened

  function reset() {
    pending = null
    message = ""
    blocked = false
    heldModifiers = ""
  }

  onOpenedChanged: if (opened) reset()

  readonly property int commandMask: Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier

  function handleKey(event) {
    if (!opened) return false
    var plain = (event.modifiers & commandMask) === 0
    if (plain && event.key === Qt.Key_Escape) {
      canceled()
      return true
    }
    if (plain && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      if (pending && !blocked) saved({ keys: pending.keys, label: pending.label })
      return true
    }
    if (plain && (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete)) {
      saved(null)
      return true
    }

    var result = Hotkeys.fromKeyEvent(event.key, event.modifiers, event.nativeScanCode)
    if (result.state === "partial") {
      var labels = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" }
      heldModifiers = result.mods.map(function(m) { return labels[m] }).join("+")
      return true
    }
    heldModifiers = ""
    if (result.state === "invalid") {
      pending = null
      blocked = true
      message = result.reason
      return true
    }
    pending = result
    var conflict = conflictCheck ? conflictCheck(result) : null
    if (conflict && conflict.kind === "hyprland") {
      blocked = true
      message = "Already bound in Hyprland: " + conflict.description
    } else if (conflict) {
      blocked = false
      message = "Moves here from “" + conflict.description + "”"
    } else {
      blocked = false
      message = ""
    }
    return true
  }

  function handleKeyRelease(event) {
    if (!opened) return false
    if (Hotkeys.isModifierKey(event.key) && !pending) heldModifiers = ""
    return true
  }

  Rectangle {
    anchors.fill: parent
    color: root.scrim

    MouseArea {
      anchors.fill: parent
      onClicked: root.canceled()
    }

    BorderSurface {
      id: card
      width: Math.min(parent.width - Style.space(32), Style.space(420))
      height: column.implicitHeight + card.contentTopInset + card.contentBottomInset
      anchors.centerIn: parent
      color: root.background
      borderSpec: Border.flat(root.accent, Math.max(1, Style.normalBorderWidth))
      padding: Style.space(18)
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          text: "HOTKEY"
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
        }

        BorderSurface {
          width: parent.width
          height: comboText.implicitHeight + Style.space(24)
          color: Util.alpha(root.foreground, 0.04)
          borderSpec: Border.flat(Util.alpha(root.blocked ? root.urgent : root.foreground, root.blocked ? 0.8 : 0.2), Math.max(1, Style.normalBorderWidth))
          radius: Style.cornerRadius

          Text {
            id: comboText
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: root.pending ? root.pending.label
              : (root.heldModifiers ? root.heldModifiers + "+…"
              : (root.current ? root.current.label : "Press a key combination"))
            color: root.blocked ? root.urgent : root.foreground
            opacity: root.pending || root.heldModifiers ? 1 : 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: !!root.pending
            elide: Text.ElideRight
          }
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: root.message || (root.pending ? "" : (root.current ? "Current hotkey; press a new one to replace it" : "Use Super, Ctrl or Alt with any key, or F13 and up on their own"))
          color: root.blocked ? root.urgent : root.foreground
          opacity: root.blocked ? 1 : 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Row {
          spacing: Style.space(14)

          KeyHint { keys: "Enter"; label: "save"; foreground: root.foreground; fontFamily: root.fontFamily; opacity: root.pending && !root.blocked ? 1 : 0.4 }
          KeyHint { keys: "Backspace"; label: "remove"; foreground: root.foreground; fontFamily: root.fontFamily }
          KeyHint { keys: "Esc"; label: "cancel"; foreground: root.foreground; fontFamily: root.fontFamily }
        }
      }
    }
  }
}
