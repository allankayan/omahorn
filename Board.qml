import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "components"
import "lib/Library.js" as Library
import "lib/Glyphs.js" as Glyphs

// The soundboard overlay: a grid of pads over a dimmed screen, styled with
// the [menu] surface tokens like the launcher, clipboard and emoji picker.
// Type to search, arrows to move, Enter to play.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var service: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "omaboard"

  property bool opened: false
  // Hosts can open the board without taking the keyboard or pick its screen
  // (the dev host does both, so tests never steal the session's input).
  property bool grabKeyboard: true
  property var targetScreen: null
  property string view: "sounds"
  property string filterText: ""
  property string tab: "all"
  property int selectedIndex: 0
  property bool cursorActive: true
  property var displayed: []

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int tabsHeight: Math.max(Style.space(26), Style.font.body + Style.space(12))
  property int footerHeight: Math.max(Style.space(22), Style.font.caption + Style.space(12))
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(880), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)
  property int tileMinWidth: Style.space(196)
  property int tileHeight: Math.max(Style.space(96), Style.font.subtitle * 2 + Style.font.caption + Style.space(56))
  property int tileGap: Style.space(6)

  readonly property var sounds: service ? service.sounds : []
  readonly property var playing: service ? service.playing : []
  readonly property var audio: service ? service.audio : ({})
  readonly property var config: service ? service.config : null
  readonly property int columns: Math.max(1, Math.floor((grid.width + tileGap) / (tileMinWidth + tileGap)))
  readonly property var selectedSound: displayed.length > 0 && selectedIndex >= 0 && selectedIndex < displayed.length ? displayed[selectedIndex] : null

  readonly property var tabs: {
    var list = [{ key: "all", label: "All", count: sounds.length }]
    var favorites = 0
    for (var i = 0; i < sounds.length; i++) if (sounds[i].favorite) favorites++
    if (favorites > 0) list.push({ key: "favorites", label: Glyphs.star + " Favorites", count: favorites })
    var cats = service ? service.categories : []
    if (cats.length > 1) for (var c = 0; c < cats.length; c++) list.push({ key: cats[c].name, label: cats[c].name, count: cats[c].count })
    return list
  }

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var wasOpen = opened
    opened = true
    if (!wasOpen) {
      view = "sounds"
      filterText = ""
      cursorActive = true
      pointerGate.reset()
      if (service) {
        var lastTab = service.boardTab || "all"
        tab = tabs.some(function(t) { return t.key === lastTab }) ? lastTab : "all"
        service.refreshIfStale()
      }
      rebuild(service ? service.boardSoundId : "")
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (capture.opened) cancelCapture()
    opened = false
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  onOpenedChanged: if (service) service.boardOpen = opened
  // Switching pages must never leave the keyboard in a field of the old one.
  onViewChanged: Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  onServiceChanged: if (service) service.boardOpen = opened

  // The shell unloads the board when it closes; never leave the hotkeys
  // suspended or the service thinking the board is still up.
  Component.onDestruction: {
    if (!service) return
    if (captureOwner) service.resumeHotkeys()
    service.boardOpen = false
  }
  onSoundsChanged: rebuild(selectedSound ? selectedSound.id : "")
  onSelectedSoundChanged: if (service && opened && selectedSound) service.boardSoundId = selectedSound.id
  onTabsChanged: {
    for (var i = 0; i < tabs.length; i++) if (tabs[i].key === tab) return
    tab = "all"
    rebuild("")
  }

  // ------------------------------------------------------------- list

  function rebuild(keepId) {
    var list = Library.filterSounds(sounds, filterText, tab)
    displayed = list
    if (keepId) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].id === keepId) {
          selectedIndex = i
          break
        }
      }
    }
    if (selectedIndex >= list.length) selectedIndex = Math.max(0, list.length - 1)
    if (selectedIndex < 0) selectedIndex = 0
    Qt.callLater(ensureVisible)
  }

  function ensureVisible() {
    if (displayed.length > 0) grid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  function setFilter(text) {
    filterText = text
    selectedIndex = 0
    cursorActive = true
    pointerGate.reset()
    rebuild("")
  }

  function setTab(key) {
    if (tab === key) return
    tab = key
    if (service) service.boardTab = key
    selectedIndex = 0
    rebuild("")
  }

  function cycleTab(delta) {
    var at = 0
    for (var i = 0; i < tabs.length; i++) if (tabs[i].key === tab) at = i
    setTab(tabs[(at + delta + tabs.length) % tabs.length].key)
  }

  function move(delta) {
    if (displayed.length === 0) return
    pointerGate.reset()
    if (!cursorActive) {
      cursorActive = true
      return
    }
    selectedIndex = Math.max(0, Math.min(displayed.length - 1, selectedIndex + delta))
    ensureVisible()
  }

  function moveRow(delta) {
    if (displayed.length === 0) return
    var next = selectedIndex + delta * columns
    if (next < 0 || next >= displayed.length) {
      // Clamp into the first/last row rather than stopping a row short.
      next = Math.max(0, Math.min(displayed.length - 1, next))
    }
    move(next - selectedIndex)
  }

  function voiceFor(id) {
    for (var i = 0; i < playing.length; i++) if (playing[i].id === id) return playing[i]
    return null
  }

  // ------------------------------------------------------------- actions

  // mode: "close" (Enter), "stay" (Shift+Enter, clicks), "preview" (Ctrl+Enter)
  function playSound(sound, mode) {
    if (!sound || !service) return
    var ok = service.play(sound.id, { preview: mode === "preview" })
    if (ok && mode === "close" && config && config.closeOnPlay) dismiss()
  }

  function toggleFavorite(sound) {
    if (sound && service) service.toggleFavorite(sound.id)
  }

  function nudgeVolume(sound, delta) {
    if (sound && service) service.setSoundVolume(sound.id, (sound.volume || 100) + delta)
  }

  function openFolder() {
    if (!service) return
    var dir = selectedSound ? service.soundFolder(selectedSound.id) : ""
    if (!dir && config && config.folders.length > 0) dir = config.folders[0].path
    service.openFolder(dir)
  }

  // ------------------------------------------------------------- hotkeys

  property var captureOwner: null

  function startCapture(owner, title, current) {
    if (!service) return
    keyCatcher.forceActiveFocus()
    captureOwner = owner
    capture.title = title
    capture.current = current
    capture.opened = true
    service.suspendHotkeys()
  }

  function captureForSound(sound) {
    if (sound) startCapture({ path: sound.path }, sound.name, sound.hotkey)
  }

  function finishCapture(hotkey) {
    if (service && captureOwner) service.assignHotkey(captureOwner, hotkey)
    capture.opened = false
    captureOwner = null
    if (service) service.resumeHotkeys()
  }

  function captureState() {
    return { pending: capture.pending ? capture.pending.label : "", message: capture.message, blocked: capture.blocked }
  }

  function cancelCapture() {
    capture.opened = false
    captureOwner = null
    if (service) service.resumeHotkeys()
  }

  // ------------------------------------------------------------- keys

  function handleSoundsKey(event) {
    var mods = event.modifiers
    var ctrl = (mods & Qt.ControlModifier) !== 0
    var shift = (mods & Qt.ShiftModifier) !== 0
    var alt = (mods & Qt.AltModifier) !== 0
    var key = event.key

    if (key === Qt.Key_Escape) {
      if (filterText) setFilter("")
      else dismiss()
    } else if (ctrl && key === Qt.Key_Comma) {
      view = "settings"
      settingsView.reset()
    } else if (ctrl && key === Qt.Key_S) {
      if (service) service.stopAll()
    } else if (ctrl && key === Qt.Key_F) {
      toggleFavorite(selectedSound)
    } else if (ctrl && key === Qt.Key_K) {
      captureForSound(selectedSound)
    } else if (ctrl && key === Qt.Key_O) {
      openFolder()
    } else if (ctrl && key === Qt.Key_R) {
      if (service) service.rescan()
    } else if (ctrl && key === Qt.Key_Left) {
      nudgeVolume(selectedSound, -10)
    } else if (ctrl && key === Qt.Key_Right) {
      nudgeVolume(selectedSound, 10)
    } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      cycleTab(key === Qt.Key_Backtab || shift ? -1 : 1)
    } else if (Util.editsFilter(event, filterText)) {
      setFilter(Util.editedFilter(event, filterText))
    } else if (key === Qt.Key_Left) {
      move(-1)
    } else if (key === Qt.Key_Right) {
      move(1)
    } else if (key === Qt.Key_Up) {
      moveRow(-1)
    } else if (key === Qt.Key_Down) {
      moveRow(1)
    } else if (key === Qt.Key_PageUp || key === Qt.Key_PageDown) {
      var rows = Math.max(1, Math.floor(grid.height / grid.cellHeight))
      moveRow((key === Qt.Key_PageUp ? -1 : 1) * rows)
    } else if (key === Qt.Key_Home) {
      move(-selectedIndex)
    } else if (key === Qt.Key_End) {
      move(displayed.length - 1 - selectedIndex)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (!cursorActive && displayed.length > 0) cursorActive = true
      else playSound(selectedSound, ctrl ? "preview" : (shift ? "stay" : "close"))
    } else if (alt && !ctrl && key >= Qt.Key_1 && key <= Qt.Key_9) {
      playSound(displayed[key - Qt.Key_1], "close")
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
        && (mods === Qt.NoModifier || mods === Qt.ShiftModifier || mods === Qt.KeypadModifier)) {
      setFilter(filterText + event.text)
    } else {
      return false
    }
    return true
  }

  function handleSettingsKey(event) {
    var key = event.key
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (key === Qt.Key_Escape || (ctrl && key === Qt.Key_Comma)) {
      if (settingsView.editing) keyCatcher.forceActiveFocus()
      else view = "sounds"
    } else if (key === Qt.Key_Up || key === Qt.Key_Backtab) {
      settingsView.moveCursor(-1)
      keyCatcher.forceActiveFocus()
    } else if (key === Qt.Key_Down || key === Qt.Key_Tab) {
      settingsView.moveCursor(1)
      keyCatcher.forceActiveFocus()
    } else if (settingsView.editing) {
      return false
    } else if (key === Qt.Key_Left) {
      settingsView.adjust(-1)
    } else if (key === Qt.Key_Right) {
      settingsView.adjust(1)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      settingsView.activate()
    } else if (key === Qt.Key_Delete || key === Qt.Key_Backspace) {
      settingsView.deleteCurrent()
    } else if (ctrl && key === Qt.Key_S) {
      if (service) service.stopAll()
    } else if (event.text === "r" || event.text === "R") {
      if (!settingsView.textKey(event.text)) settingsView.toggleRecursive()
    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && !ctrl) {
      return settingsView.textKey(event.text)
    } else {
      return false
    }
    return true
  }

  // Every key press on the board lands here first.
  function handleKey(event) {
    if (capture.opened) {
      capture.handleKey(event)
      return true
    }
    return view === "settings" ? handleSettingsKey(event) : handleSoundsKey(event)
  }

  // ------------------------------------------------------------- footer clock

  // Elapsed time for the footer; pads animate on their own.
  property double now: Date.now()

  Timer {
    interval: 250
    repeat: true
    running: root.opened && root.playing.length > 0
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  readonly property var newestVoice: playing.length > 0 ? playing[playing.length - 1] : null

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // ------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omaboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && root.grabKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }
        Keys.onReleased: function(event) {
          if (capture.opened) {
            capture.handleKeyRelease(event)
            event.accepted = true
          }
        }

        Item {
          id: content
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset

          // ---- header: search text, mic status, settings
          Item {
            id: header
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.headerHeight

            Text {
              anchors.left: parent.left
              anchors.right: headerTools.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.view === "settings" ? "Settings" : (root.filterText || "Search sounds…")
              color: root.foreground
              opacity: root.view === "settings" || root.filterText ? 1 : 0.58
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Row {
              id: headerTools
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                id: micChip
                readonly property bool ok: !!root.service && root.service.micReady
                readonly property var apps: root.service ? root.service.listeners.map(function(l) { return l.label }) : []
                anchors.verticalCenter: parent.verticalCenter
                foreground: ok ? root.foreground : Color.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.body
                iconText: ok ? Glyphs.mic : Glyphs.micOff
                verticalPadding: Style.space(4)
                text: {
                  if (!ok) return "Mic offline"
                  if (apps.length > 0) return "Live · " + apps.join(", ")
                  if (root.service.injecting) return "No app listening"
                  return root.audio.isDefault ? "Default mic" : "Mic ready"
                }
                tooltipText: {
                  if (!root.service) return ""
                  if (root.service.injecting) return apps.length > 0
                    ? "Sounds go straight into " + apps.join(", ")
                    : "Sounds go into any app recording a microphone; none is right now"
                  return ok ? "Omaboard Microphone · " + (root.audio.micDescription || "no microphone")
                    : (root.audio.error || "The virtual microphone is not set up")
                }
                onClicked: {
                  root.view = "settings"
                  settingsView.reset()
                }
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                foreground: root.foreground
                fontFamily: root.fontFamily
                iconText: root.view === "settings" ? Glyphs.grid : Glyphs.settings
                iconSize: Style.font.title
                verticalPadding: Style.space(4)
                tooltipText: root.view === "settings" ? "Back to sounds (Esc)" : "Settings (Ctrl+,)"
                onClicked: {
                  if (root.view === "settings") root.view = "sounds"
                  else {
                    root.view = "settings"
                    settingsView.reset()
                  }
                }
              }
            }
          }

          // ---- category tabs
          Row {
            id: tabRow
            visible: root.view === "sounds" && root.tabs.length > 1
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: header.bottom
            anchors.topMargin: root.contentSpacing
            height: visible ? root.tabsHeight : 0
            spacing: Style.space(4)
            clip: true

            Repeater {
              model: root.tabs

              BorderSurface {
                id: tabChip
                required property var modelData
                readonly property bool current: modelData.key === root.tab
                anchors.verticalCenter: parent.verticalCenter
                width: tabLabel.implicitWidth + tabCount.implicitWidth + Style.space(22)
                height: root.tabsHeight
                radius: root.cornerRadius
                color: current ? root.selectedBackground : (tabHover.hovered ? Util.alpha(root.foreground, 0.04) : "transparent")
                borderSpec: current ? root.selectedBorderSpec : Border.none()

                HoverHandler { id: tabHover }

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    id: tabLabel
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: tabChip.modelData.label
                    color: tabChip.current ? root.selectedText : root.foreground
                    opacity: tabChip.current ? 1 : 0.72
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: tabChip.current
                  }

                  Text {
                    id: tabCount
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: tabChip.modelData.count
                    color: tabChip.current ? root.selectedText : root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.features: { "tnum": 1 }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setTab(tabChip.modelData.key)
                }
              }
            }
          }

          // ---- body: pads or settings
          Item {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: tabRow.visible ? tabRow.bottom : header.bottom
            anchors.topMargin: root.contentSpacing
            anchors.bottom: footer.top
            anchors.bottomMargin: root.contentSpacing

            GridView {
              id: grid
              visible: root.view === "sounds"
              anchors.fill: parent
              clip: true
              model: root.displayed
              cellWidth: Math.floor(width / root.columns)
              cellHeight: root.tileHeight + root.tileGap
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                id: cell
                required property var modelData
                required property int index
                width: grid.cellWidth
                height: grid.cellHeight

                SoundTile {
                  id: tile
                  anchors.fill: parent
                  anchors.rightMargin: root.tileGap
                  anchors.bottomMargin: root.tileGap
                  sound: cell.modelData
                  hasCursor: root.cursorActive && cell.index === root.selectedIndex
                  voice: root.voiceFor(cell.modelData.id)
                  peaks: root.service && root.service.peaks[cell.modelData.id] ? root.service.peaks[cell.modelData.id].values : []
                  foreground: root.foreground
                  selectedBackground: root.selectedBackground
                  selectedText: root.selectedText
                  selectedBorderSpec: root.selectedBorderSpec
                  fontFamily: root.fontFamily

                  onPointerMoved: function(mouse) {
                    if (!pointerGate.moved(tile, mouse)) return
                    root.cursorActive = true
                    root.selectedIndex = cell.index
                  }
                  onClicked: function(button) {
                    root.cursorActive = true
                    root.selectedIndex = cell.index
                    if (button === Qt.RightButton) root.playSound(cell.modelData, "preview")
                    else if (button === Qt.MiddleButton) root.toggleFavorite(cell.modelData)
                    else root.playSound(cell.modelData, "stay")
                  }
                  onFavoriteClicked: root.toggleFavorite(cell.modelData)
                  onHotkeyClicked: root.captureForSound(cell.modelData)
                }
              }
            }

            // Fade the pads into the card edge once there is more to scroll.
            Rectangle {
              visible: grid.visible && opacity > 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Math.min(Style.space(28), parent.height / 3)
              opacity: grid.contentHeight > grid.height
                ? Math.max(0, Math.min(1, (grid.originY + grid.contentHeight - grid.height - grid.contentY) / height))
                : 0
              gradient: Gradient {
                GradientStop { position: 0; color: Util.alpha(root.background, 0) }
                GradientStop { position: 1; color: root.background }
              }
            }

            Column {
              anchors.centerIn: parent
              width: Math.min(parent.width, Style.space(420))
              spacing: Style.space(8)
              visible: root.view === "sounds" && root.displayed.length === 0

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: Glyphs.wave
                color: root.selectedText
                opacity: 0.8
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: root.filterText ? "No matches for “" + root.filterText + "”"
                  : (root.service && root.service.scanning ? "Loading sounds…" : "No sounds yet")
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              Text {
                width: parent.width
                visible: !root.filterText && !(root.service && root.service.scanning) && root.sounds.length === 0
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                text: "Drop audio files into " + (root.config && root.config.folders.length > 0 ? root.config.folders[0].path : "a folder") + ". Ctrl+O opens it, Ctrl+, adds more folders."
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            SettingsView {
              id: settingsView
              visible: root.view === "settings"
              anchors.fill: parent
              service: root.service
              foreground: root.foreground
              background: root.background
              selectedBackground: root.selectedBackground
              selectedText: root.selectedText
              selectedBorderSpec: root.selectedBorderSpec
              fontFamily: root.fontFamily
              onCaptureRequested: function(owner, title, current) { root.startCapture(owner, title, current) }
              onFocusReleased: keyCatcher.forceActiveFocus()
            }
          }

          // ---- footer: what's playing / notices, and the key hints
          Item {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: root.footerHeight

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              height: Style.spacing.hairline
              color: Util.alpha(root.foreground, 0.1)
            }

            Row {
              id: footerStatus
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.right: hints.left
              anchors.rightMargin: Style.space(16)
              spacing: Style.space(8)
              clip: true

              EqBars {
                visible: root.newestVoice !== null && !(root.service && root.service.notice)
                running: visible
                color: root.foreground
                implicitHeight: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, footerStatus.width - Style.space(24))
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.features: { "tnum": 1 }
                color: root.service && root.service.notice && root.service.noticeKind === "error" ? Color.urgent : root.foreground
                opacity: root.service && root.service.notice ? 0.95 : 0.6
                text: {
                  var s = root.service
                  if (s && s.notice) return s.notice
                  var v = root.newestVoice
                  if (v) {
                    var elapsed = Math.max(0, (root.now - v.startedAt) / 1000)
                    var extra = root.playing.length > 1 ? "  +" + (root.playing.length - 1) : ""
                    return (v.preview ? "Preview · " : "") + v.name + "  " + Library.formatDuration(elapsed)
                      + (v.duration ? " / " + Library.formatDuration(v.duration) : "") + extra
                  }
                  if (root.view === "settings") return "Changes save as you go"
                  var count = root.displayed.length
                  return count + (count === 1 ? " sound" : " sounds") + (root.filterText ? " found" : "")
                }
              }
            }

            Row {
              id: hints
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(12)

              KeyHint { visible: root.view === "sounds"; keys: "Enter"; label: "play"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "sounds"; keys: "Ctrl+Enter"; label: "preview"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "sounds"; keys: "Ctrl+F"; label: "favorite"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "sounds"; keys: "Ctrl+K"; label: "hotkey"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.playing.length > 0; keys: "Ctrl+S"; label: "stop"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "settings"; keys: "←→"; label: "adjust"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "settings"; keys: "Esc"; label: "back"; foreground: root.foreground; fontFamily: root.fontFamily }
              KeyHint { visible: root.view === "sounds"; keys: "Ctrl+,"; label: "settings"; foreground: root.foreground; fontFamily: root.fontFamily }
            }
          }
        }

        HotkeyCapture {
          id: capture
          anchors.fill: parent
          z: 10
          background: root.background
          foreground: root.foreground
          scrim: Util.alpha(root.background, 0.72)
          accent: root.selectedText
          fontFamily: root.fontFamily
          conflictCheck: function(hotkey) { return root.service ? root.service.hotkeyConflict(hotkey, root.captureOwner) : null }
          onSaved: function(hotkey) { root.finishCapture(hotkey) }
          onCanceled: root.cancelCapture()
        }
      }
    }
  }
}
