import QtQuick
import qs.Commons

// A pad's loudness envelope as bars. While the sound plays, the part already
// heard is drawn brighter, sliding smoothly rather than bar by bar.
Item {
  id: root

  property var values: []
  property real progress: 0
  property bool playing: false
  property color color: Color.foreground
  property real restOpacity: 0.2
  property real playedOpacity: 0.85

  readonly property int count: values ? values.length : 0
  readonly property real gap: count > 0 ? Math.max(1, Math.round(width / count * 0.3)) : 0
  readonly property real barWidth: count > 0 ? Math.max(1, (width - gap * (count - 1)) / count) : 0

  // A flat line until the envelope has been computed.
  Rectangle {
    visible: root.count === 0
    anchors.verticalCenter: parent.verticalCenter
    width: parent.width
    height: 1
    color: root.color
    opacity: root.restOpacity
  }

  component Bars: Item {
    property real level: 0.2

    Repeater {
      model: root.count

      Rectangle {
        required property int index
        x: index * (root.barWidth + root.gap)
        width: root.barWidth
        height: Math.max(1, Math.round(root.height * Math.max(0.08, (root.values[index] || 0) / 100)))
        anchors.verticalCenter: parent.verticalCenter
        radius: Math.min(width / 2, Style.cornerRadius)
        color: root.color
        opacity: parent.level
      }
    }
  }

  Bars {
    anchors.fill: parent
    level: root.restOpacity
  }

  Loader {
    active: root.playing && root.count > 0
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width * Math.max(0, Math.min(1, root.progress))
    clip: true

    sourceComponent: Bars {
      width: root.width
      height: root.height
      level: root.playedOpacity
    }
  }
}
