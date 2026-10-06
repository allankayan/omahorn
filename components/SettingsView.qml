import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "../lib/Glyphs.js" as Glyphs

// The board's settings page: microphone routing, volumes, playback, hotkeys
// and library folders. Keyboard-first like the rest of the board: the board
// forwards navigation here and this view keeps its own cursor.
Item {
  id: root

  property var service: null
  property color foreground: Color.foreground
  property color background: Color.background
  property color selectedBackground: Util.alpha(Color.foreground, 0.08)
  property color selectedText: Color.accent
  property var selectedBorderSpec: Border.none()
  property string fontFamily: Style.font.menuFamily

  // Asks the board to record a hotkey: owner is { action } or { path }.
  signal captureRequested(var owner, string title, var current)
  // The folder path field let go of the keyboard; the board takes it back.
  signal focusReleased()

  readonly property var config: service ? service.config : null
  readonly property var audio: service ? service.audio : null
  readonly property bool editing: folderField.activeFocus

  property int cursorIndex: 1

  // Fake bar for PanelSlider, which takes its colors from a bar object.
  readonly property QtObject sliderBar: QtObject {
    property color foreground: root.foreground
    property color background: root.background
  }

  readonly property bool injecting: service ? service.injecting : true

  // Apps that recorded a microphone this session, and whether they are now.
  readonly property var apps: {
    if (!service) return []
    var live = service.injectTargets.map(function(t) { return t.app })
    return service.seenApps.map(function(a) {
      return { app: a.app, binary: a.binary, live: live.indexOf(a.app) !== -1 }
    })
  }

  // Rows rebuild only when their shape really changes (folders, routing,
  // the app list); any other setting updates the existing rows in place.
  readonly property string rowsKey: config ? JSON.stringify([config.folders, injecting, apps]) : "[]"

  readonly property var rows: {
    var key = JSON.parse(rowsKey)
    var folders = key[0] || []
    var list = [
      { type: "header", text: "ROUTING" },
      { type: "routing", label: "Send sounds" }
    ]
    if (key[1]) {
      var apps = key[2] || []
      for (var a = 0; a < apps.length; a++) list.push({ type: "app", app: apps[a] })
      if (apps.length === 0) list.push({ type: "info", text: "Apps show up here while they record a microphone: join a call and its app appears. Each one gets your sounds unless you switch it off." })
    } else {
      list.push(
        { type: "toggle", key: "defaultMic", label: "Use as default microphone", description: "Apps that record the default input hear your sounds, no per-app setup" },
        { type: "mic", label: "Your microphone", description: "Mixed into Omaboard Microphone along with the sounds" },
        { type: "listeners" })
    }
    list.push(
      { type: "header", text: "VOLUME" },
      { type: "slider", key: "micVolume", label: "Sounds in the mic", description: "What other people hear", max: 150 },
      { type: "toggle", key: "monitor", label: "Hear sounds yourself", description: "Also play them on your current output" },
      { type: "slider", key: "monitorVolume", label: "Sounds for you", description: "Your own level, independent from the mic", max: 150 },
      { type: "header", text: "PLAYBACK" },
      { type: "toggle", key: "overlap", label: "Overlap sounds", description: "Off: a new sound stops the one playing" },
      { type: "toggle", key: "closeOnPlay", label: "Close after Enter", description: "Shift+Enter always keeps the board open" },
      { type: "header", text: "HOTKEYS" },
      { type: "hotkey", action: "toggle", label: "Open soundboard" },
      { type: "hotkey", action: "stop", label: "Stop all sounds" },
      { type: "header", text: "FOLDERS" })
    for (var i = 0; i < folders.length; i++)
      list.push({ type: "folder", index: i, folder: folders[i] })
    list.push({ type: "addFolder" })
    return list
  }

  function selectable(row) {
    return row && row.type !== "header" && row.type !== "listeners" && row.type !== "info"
  }

  function toggleRouting() {
    service.setSetting("routing", injecting ? "vmic" : "inject")
  }

  function reset() {
    cursorIndex = 0
    moveCursor(1)
    flick.contentY = 0
  }

  // Hidden items keep the keyboard in Qt, so the field must give it back
  // explicitly whenever the cursor leaves it.
  function releaseField() {
    if (!folderField.activeFocus) return
    folderField.focus = false
    focusReleased()
  }

  function moveCursor(delta) {
    releaseField()
    var i = cursorIndex
    for (var steps = 0; steps < rows.length; steps++) {
      i = Math.max(0, Math.min(rows.length - 1, i + delta))
      if (selectable(rows[i])) {
        cursorIndex = i
        ensureVisible(i)
        return
      }
      if (i === 0 || i === rows.length - 1) return
    }
  }

  function ensureVisible(index) {
    var item = repeater.itemAt(index)
    if (!item) return
    var margin = Style.space(8)
    if (item.y < flick.contentY) flick.contentY = Math.max(0, item.y - margin)
    else if (item.y + item.height > flick.contentY + flick.height)
      flick.contentY = Math.min(flick.contentHeight - flick.height, item.y + item.height - flick.height + margin)
  }

  function micChoices() {
    var list = [{ name: "auto", description: "Default input" }]
    var sources = audio && audio.sources ? audio.sources : []
    for (var i = 0; i < sources.length; i++) list.push(sources[i])
    return list
  }

  function micLabel() {
    if (!config) return ""
    var current = audio && audio.micDescription ? audio.micDescription : ""
    if (config.mic === "auto") return current ? "Auto · " + current : "Auto"
    var sources = audio && audio.sources ? audio.sources : []
    for (var i = 0; i < sources.length; i++) if (sources[i].name === config.mic) return sources[i].description
    return config.mic + " (unplugged)"
  }

  function cycleMic(delta) {
    var choices = micChoices()
    var at = 0
    for (var i = 0; i < choices.length; i++) if (choices[i].name === config.mic) at = i
    var next = choices[(at + delta + choices.length) % choices.length]
    service.setMic(next.name)
  }

  function adjust(delta) {
    releaseField()
    var row = rows[cursorIndex]
    if (!row || !service) return
    if (row.type === "slider") service.setSetting(row.key, Math.max(0, Math.min(row.max, config[row.key] + delta * 5)))
    else if (row.type === "routing") toggleRouting()
    else if (row.type === "app") service.setAppExcluded(row.app, delta < 0)
    else if (row.type === "mic") cycleMic(delta)
    else if (row.type === "toggle") service.setSetting(row.key, delta > 0)
  }

  function activate() {
    var row = rows[cursorIndex]
    if (!row || !service) return
    if (row.type !== "addFolder") releaseField()
    if (row.type === "toggle") service.setSetting(row.key, !config[row.key])
    else if (row.type === "routing") toggleRouting()
    else if (row.type === "app") service.setAppExcluded(row.app, !service.appExcluded(row.app))
    else if (row.type === "mic") cycleMic(1)
    else if (row.type === "hotkey") captureRequested({ action: row.action }, row.label, config.hotkeys[row.action])
    else if (row.type === "folder") service.openFolder(row.folder.path)
    else if (row.type === "addFolder") folderField.forceActiveFocus()
  }

  function deleteCurrent() {
    releaseField()
    var row = rows[cursorIndex]
    if (!row || !service) return
    if (row.type === "folder") {
      var folders = config.folders.filter(function(f, i) { return i !== row.index })
      service.setSetting("folders", folders)
      Qt.callLater(function() { root.moveCursor(0) })
    } else if (row.type === "hotkey") {
      service.assignHotkey({ action: row.action }, null)
    }
  }

  // Printable keys on the "add folder" row start typing a path.
  function textKey(text) {
    var row = rows[cursorIndex]
    if (row && row.type === "addFolder") {
      folderField.forceActiveFocus()
      folderField.insert(folderField.cursorPosition, text)
      return true
    }
    return false
  }

  function toggleRecursive() {
    var row = rows[cursorIndex]
    if (!row || row.type !== "folder") return
    var folders = JSON.parse(JSON.stringify(config.folders))
    folders[row.index].recursive = !folders[row.index].recursive
    service.setSetting("folders", folders)
  }

  function addFolder(path) {
    var p = String(path || "").trim()
    if (!p) return
    if (p.charAt(0) !== "/" && p.charAt(0) !== "~") {
      service.report("Use an absolute path or one starting with ~/", "error")
      return
    }
    var folders = config.folders.concat([{ path: p, name: "", recursive: true }])
    service.setSetting("folders", folders)
    folderField.text = ""
  }

  Flickable {
    id: flick
    anchors.fill: parent
    clip: true
    contentWidth: width
    contentHeight: column.implicitHeight
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: flick.contentHeight > flick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

    Column {
      id: column
      width: flick.width
      spacing: Style.space(4)

      Repeater {
        id: repeater
        model: root.rows

        delegate: Loader {
          id: rowLoader
          required property var modelData
          required property int index
          width: column.width
          sourceComponent: modelData.type === "header" ? headerRow
            : modelData.type === "listeners" || modelData.type === "info" ? listenersRow
            : modelData.type === "addFolder" ? addFolderRow
            : controlRow
        }
      }
    }
  }

  // The path being typed. It lives outside the repeater so focus survives
  // row rebuilds, and stays invisible: the "add folder" row mirrors it.
  // (Hidden items cannot take focus, so it is transparent instead.)
  TextField {
    id: folderField
    width: 1
    height: 1
    opacity: 0
    onAccepted: root.addFolder(text)
  }

  Component {
    id: headerRow

    Item {
      width: parent ? parent.width : 0
      height: headerText.implicitHeight + (index === 0 ? Style.space(2) : Style.space(12))

      PanelSectionHeader {
        id: headerText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.bottom: parent.bottom
        text: modelData.text
        foreground: root.foreground
        fontFamily: root.fontFamily
      }
    }
  }

  Component {
    id: listenersRow

    Item {
      width: parent ? parent.width : 0
      height: listenersText.implicitHeight + Style.space(6)

      Text {
        id: listenersText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: {
          if (modelData.type === "info") return modelData.text
          var a = root.audio
          if (!a) return ""
          if (!a.present) return a.error ? a.error : "Omaboard Microphone is not available yet."
          var apps = (a.listeners || []).map(function(l) { return l.app })
          if (apps.length > 0) return Glyphs.mic + "  Live in " + apps.join(", ")
          return a.isDefault
            ? "No app is recording right now. Apps on the default input will hear your sounds."
            : "No app is recording it. Pick “Omaboard Microphone” as the input in your call app."
        }
      }
    }
  }

  Component {
    id: controlRow

    CursorSurface {
      id: row
      readonly property var entry: modelData
      readonly property int rowIndex: index
      hasCursor: root.cursorIndex === rowIndex
      foreground: root.foreground
      fill: root.selectedBackground
      width: parent ? parent.width : 0
      height: Math.max(Style.space(46), labels.implicitHeight + Style.space(16))

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: root.cursorIndex = row.rowIndex
        onClicked: function(mouse) {
          root.releaseField()
          root.cursorIndex = row.rowIndex
          if (mouse.button === Qt.RightButton) root.deleteCurrent()
          else if (row.entry.type !== "slider") root.activate()
        }
      }

      Column {
        id: labels
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: control.left
        anchors.rightMargin: Style.space(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.entry.type === "folder" ? row.entry.folder.path
            : (row.entry.type === "app" ? row.entry.app.app : row.entry.label)
          color: row.hasCursor ? root.selectedText : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.weight: Font.Medium
          elide: Text.ElideMiddle
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: {
            var d = row.entry
            if (d.type === "routing") return root.injecting
              ? "Straight into apps recording a microphone, like Soundux; nothing new in your devices"
              : "Through an Omaboard Microphone device that apps pick as their input"
            if (d.type === "app") return (d.app.live ? "Recording now" : "Not recording right now")
              + (d.app.binary && d.app.binary !== d.app.app ? " · " + d.app.binary : "")
            if (d.type === "folder") return (d.folder.recursive ? "Includes subfolders" : "This folder only") + (row.hasCursor ? "  ·  Enter open · R subfolders · Del remove" : "")
            if (d.type === "hotkey") return row.hasCursor ? "Enter change · Del clear" : ""
            return d.description || ""
          }
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        id: control
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        width: row.entry.type === "slider" ? sliderRow.implicitWidth
          : (row.entry.type === "toggle" || row.entry.type === "app" ? toggle.implicitWidth : valueText.implicitWidth)
        height: Math.max(Style.space(22), toggle.implicitHeight)

        ToggleSwitch {
          id: toggle
          visible: row.entry.type === "toggle" || row.entry.type === "app"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          interactive: false
          checked: row.entry.type === "app"
            ? !!(root.service && root.config && !root.service.appExcluded(row.entry.app))
            : !!(root.config && row.entry.key && root.config[row.entry.key])
          foreground: root.foreground
        }

        Row {
          id: sliderRow
          visible: row.entry.type === "slider"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(10)

          PanelSlider {
            id: slider
            width: Style.space(170)
            anchors.verticalCenter: parent.verticalCenter
            bar: root.sliderBar
            minimum: 0
            maximum: row.entry.max || 100
            step: 5
            integer: true
            value: root.config && row.entry.key ? root.config[row.entry.key] : 0
            onMoved: function(v) { root.cursorIndex = row.rowIndex }
            onReleased: function(v) { if (root.service) root.service.setSetting(row.entry.key, Math.round(v)) }
          }

          Text {
            width: Style.space(40)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: Math.round(slider.dragging ? slider.liveValue : slider.value) + "%"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.features: { "tnum": 1 }
          }
        }

        Text {
          id: valueText
          visible: row.entry.type === "mic" || row.entry.type === "hotkey" || row.entry.type === "folder" || row.entry.type === "routing"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: {
            var d = row.entry
            if (d.type === "routing") return "‹  " + (root.injecting ? "Into apps" : "Virtual mic") + "  ›"
            if (d.type === "mic") return "‹  " + root.micLabel() + "  ›"
            if (d.type === "hotkey") {
              var hk = root.config ? root.config.hotkeys[d.action] : null
              return hk ? hk.label : "Not set"
            }
            if (d.type === "folder") return Glyphs.folder
            return ""
          }
          color: row.hasCursor ? root.selectedText : root.foreground
          opacity: row.entry.type === "hotkey" && !(root.config && root.config.hotkeys[row.entry.action]) ? 0.45 : 0.85
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.entry.type === "hotkey"
        }
      }
    }
  }

  Component {
    id: addFolderRow

    CursorSurface {
      id: addRow
      readonly property int rowIndex: index
      hasCursor: root.cursorIndex === rowIndex
      foreground: root.foreground
      fill: root.selectedBackground
      width: parent ? parent.width : 0
      height: Math.max(Style.space(46), field.implicitHeight + Style.space(12))

      MouseArea {
        anchors.fill: parent
        onClicked: {
          root.cursorIndex = addRow.rowIndex
          folderField.forceActiveFocus()
        }
      }

      Text {
        id: plus
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "+"
        color: root.foreground
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }

      // Mirrors the hidden field so typing lands in the row itself.
      Text {
        id: field
        anchors.left: plus.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: folderField.text !== "" ? folderField.text + (folderField.activeFocus ? "▏" : "")
          : (folderField.activeFocus ? "▏" : "Add a folder: type a path like ~/Sounds, then Enter")
        color: addRow.hasCursor ? root.selectedText : root.foreground
        opacity: folderField.text !== "" ? 1 : 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        elide: Text.ElideLeft
      }
    }
  }
}
