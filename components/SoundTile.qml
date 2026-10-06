import QtQuick
import qs.Commons
import qs.Ui
import "../lib/Library.js" as Library
import "../lib/Glyphs.js" as Glyphs

// One pad on the board: name, length, hotkey, favorite star, and a sweep
// across the pad while it plays.
BorderSurface {
  id: tile

  property var sound: null
  property bool hasCursor: false
  // { startedAt, duration, preview } while the sound plays, else null.
  property var voice: null
  property color foreground: Color.foreground
  property color selectedBackground: Util.alpha(Color.foreground, 0.08)
  property color selectedText: Color.accent
  property var selectedBorderSpec: Border.none()
  property string fontFamily: Style.font.menuFamily

  signal clicked(int button)
  signal favoriteClicked()
  signal hotkeyClicked()
  signal pointerMoved(var mouse)

  readonly property bool playing: voice !== null
  readonly property bool hot: hasCursor || hover.hovered
  readonly property color textColor: hasCursor ? selectedText : foreground
  readonly property bool hasHotkey: !!(sound && sound.hotkey)

  radius: Style.cornerRadius
  color: hasCursor ? selectedBackground : Util.alpha(foreground, playing ? 0.07 : 0.035)
  borderSpec: hasCursor ? selectedBorderSpec : Border.none()
  clip: true

  Behavior on color { ColorAnimation { duration: 90 } }

  // Share of the sound already played. Animated from the voice's start time,
  // so a board opened mid-sound picks up where the sound is.
  property real progress: 0

  NumberAnimation on progress {
    id: progressAnimation
    running: false
  }

  function syncProgress() {
    progressAnimation.stop()
    if (!voice || !(voice.duration > 0)) {
      progress = 0
      return
    }
    var elapsed = Math.max(0, (Date.now() - voice.startedAt) / 1000)
    var start = Math.min(1, elapsed / voice.duration)
    progress = start
    progressAnimation.from = start
    progressAnimation.to = 1
    progressAnimation.duration = Math.max(0, (voice.duration - elapsed) * 1000)
    progressAnimation.start()
  }

  onVoiceChanged: syncProgress()
  Component.onCompleted: syncProgress()

  Rectangle {
    visible: tile.playing
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width * tile.progress
    color: Util.alpha(tile.foreground, 0.06)
  }

  Rectangle {
    visible: tile.playing
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    width: parent.width * tile.progress
    height: Math.max(2, Style.space(2))
    color: tile.foreground
    opacity: tile.voice && tile.voice.preview ? 0.4 : 0.85
  }

  HoverHandler {
    id: hover
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onPositionChanged: function(mouse) { tile.pointerMoved(mouse) }
    onClicked: function(mouse) { tile.clicked(mouse.button) }
  }

  Item {
    id: content
    anchors.fill: parent
    anchors.leftMargin: tile.contentLeftInset + Style.space(10)
    anchors.rightMargin: tile.contentRightInset + Style.space(8)
    anchors.topMargin: tile.contentTopInset + Style.space(8)
    anchors.bottomMargin: tile.contentBottomInset + Style.space(7)

    Text {
      id: nameText
      anchors.left: parent.left
      anchors.right: starText.left
      anchors.rightMargin: Style.space(6)
      anchors.top: parent.top
      textFormat: Text.PlainText
      text: tile.sound ? tile.sound.name : ""
      color: tile.textColor
      font.family: tile.fontFamily
      font.pixelSize: Style.font.subtitle
      font.weight: Font.Medium
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
      lineHeight: 1.05
    }

    Text {
      id: starText
      anchors.right: parent.right
      anchors.top: parent.top
      textFormat: Text.PlainText
      text: tile.sound && tile.sound.favorite ? Glyphs.star : Glyphs.starOutline
      color: tile.textColor
      opacity: tile.sound && tile.sound.favorite ? 0.9 : (tile.hot ? 0.35 : 0)
      font.family: tile.fontFamily
      font.pixelSize: Style.font.body

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(5)
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.favoriteClicked()
      }
    }

    Row {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      spacing: Style.space(6)

      // Only playing pads pay for the animation.
      Loader {
        active: tile.playing
        visible: active
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: EqBars {
          running: true
          color: tile.textColor
          implicitHeight: Style.space(9)
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: tile.sound ? Library.formatDuration(tile.sound.duration) : ""
        color: tile.textColor
        opacity: 0.55
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        font.features: { "tnum": 1 }
      }

      Text {
        visible: tile.sound && tile.sound.volume !== 100
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: tile.sound ? tile.sound.volume + "%" : ""
        color: tile.textColor
        opacity: 0.55
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        font.features: { "tnum": 1 }
      }
    }

    BorderSurface {
      id: hotkeyPill
      visible: tile.hasHotkey || tile.hot
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      width: hotkeyText.implicitWidth + Style.space(8)
      height: hotkeyText.implicitHeight + Style.space(2)
      color: tile.hasHotkey ? Util.alpha(tile.textColor, 0.06) : "transparent"
      borderSpec: Border.flat(Util.alpha(tile.textColor, tile.hasHotkey ? 0.22 : 0.14), Math.max(1, Style.normalBorderWidth))
      radius: Math.min(Style.cornerRadius, Style.space(4))

      Text {
        id: hotkeyText
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: tile.hasHotkey ? tile.sound.hotkey.label : "+ hotkey"
        color: tile.textColor
        opacity: tile.hasHotkey ? 0.85 : 0.4
        font.family: tile.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: tile.hasHotkey
      }

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(3)
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.hotkeyClicked()
      }
    }
  }
}
