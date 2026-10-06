import QtQuick
import qs.Commons
import qs.Ui
import "components"
import "lib/Glyphs.js" as Glyphs

// Bar button: opens the board, and turns into a live equalizer while a
// sound plays. Right-click stops everything; middle-click toggles hearing
// sounds yourself.
BarWidget {
  id: root
  moduleName: "omaboard"

  property var service: null

  readonly property bool playing: service ? service.isPlaying : false
  readonly property bool micOk: service ? (service.micReady || !service.audioReady) : true

  function resolveService() {
    if (service) return
    var host = bar && bar.shell
    if (host && typeof host.serviceFor === "function") service = host.serviceFor(moduleName)
    if (!service) serviceRetry.restart()
  }

  onBarChanged: resolveService()
  Component.onCompleted: resolveService()

  // The service can finish loading a moment after the widget.
  Timer {
    id: serviceRetry
    interval: 500
    repeat: false
    onTriggered: root.resolveService()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: barSize

  Component {
    id: liveIcon

    Item {
      EqBars {
        anchors.centerIn: parent
        running: root.playing
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        barWidth: Math.max(2, Math.round(parent.width / 7))
        gap: Math.max(1, Math.round(parent.width / 9))
        implicitHeight: Math.round(parent.height * 0.75)
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.micOk ? Glyphs.app : Glyphs.micOff
    iconComponent: root.playing ? liveIcon : null
    active: !root.micOk
    tooltipText: {
      var s = root.service
      if (!s) return "Omaboard"
      if (s.isPlaying) return "Playing " + s.playing.map(function(p) { return p.name }).join(", ") + " · right-click to stop"
      if (!root.micOk) return "Omaboard: " + (s.audio.error || "virtual microphone unavailable")
      var listeners = s.listeners.map(function(l) { return l.app })
      var hotkey = s.config.hotkeys.toggle ? " · " + s.config.hotkeys.toggle.label : ""
      return "Omaboard · " + s.sounds.length + " sounds" + (listeners.length ? " · live in " + listeners.join(", ") : "") + hotkey
    }

    onPressed: function(b) {
      var s = root.service
      if (!s) return
      if (b === Qt.RightButton) s.stopAll()
      else if (b === Qt.MiddleButton) s.setSetting("monitor", !s.config.monitor)
      else s.toggleBoard()
    }
  }
}
