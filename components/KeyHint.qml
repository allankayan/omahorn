import QtQuick
import qs.Commons
import qs.Ui

// A key cap and what it does, for the board's footer.
Row {
  id: root

  property string keys: ""
  property string label: ""
  property color foreground: Color.foreground
  property string fontFamily: Style.font.menuFamily

  spacing: Style.space(5)

  BorderSurface {
    anchors.verticalCenter: parent.verticalCenter
    width: keyText.implicitWidth + Style.space(8)
    height: keyText.implicitHeight + Style.space(2)
    color: Util.alpha(root.foreground, 0.06)
    borderSpec: Border.flat(Util.alpha(root.foreground, 0.2), Math.max(1, Style.normalBorderWidth))
    radius: Math.min(Style.cornerRadius, Style.space(4))

    Text {
      id: keyText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.keys
      color: root.foreground
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  Text {
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.label
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
