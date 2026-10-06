import QtQuick
import qs.Commons

// Three bouncing bars: the "now playing" mark on pads, the footer and the
// bar widget. Animations only run while visible and playing.
Item {
  id: root

  property bool running: true
  property color color: Color.foreground
  property real barWidth: Math.max(2, Style.space(2))
  property real gap: Math.max(1, Style.space(2))

  implicitWidth: barWidth * 3 + gap * 2
  implicitHeight: Style.space(10)

  Repeater {
    model: 3

    Rectangle {
      id: bar
      required property int index

      x: index * (root.barWidth + root.gap)
      width: root.barWidth
      anchors.bottom: parent.bottom
      height: root.height * 0.35
      radius: Math.min(width / 2, Style.cornerRadius)
      color: root.color

      SequentialAnimation on height {
        running: root.running && root.visible
        loops: Animation.Infinite
        NumberAnimation { to: root.height; duration: 240 + bar.index * 70; easing.type: Easing.OutQuad }
        NumberAnimation { to: root.height * (0.25 + bar.index * 0.1); duration: 280 + bar.index * 50; easing.type: Easing.InOutQuad }
      }
    }
  }
}
