import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.matiacone.omarci"

  readonly property var ci: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  readonly property string barState: ci ? ci.barState : "idle"
  readonly property bool darkBg: {
    var c = Color.background
    return (c.r * 299 + c.g * 587 + c.b * 114) < 500
  }
  readonly property color success: darkBg ? "#8bc47a" : "#2f7d32"
  readonly property color pillColor: {
    if (barState === "fail") return bar ? bar.urgent : Color.urgent
    if (barState === "pass") return success
    if (barState === "running") return bar ? bar.barForeground : Color.foreground
    return Qt.darker(bar ? bar.barForeground : Color.foreground, 1.55)
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("ci" in target) target.ci = root.ci
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: Qt.callLater(injectPanel)
  onSettingsChanged: Qt.callLater(injectPanel)
  onCiChanged: Qt.callLater(injectPanel)
  Component.onCompleted: Qt.callLater(injectPanel)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  IpcHandler {
    target: "io.github.matiacone.omarci"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { if (root.ci) root.ci.syncGithub() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: false
    useActiveColor: false
    dimmed: false
    tooltipText: ci ? ci.tooltip : "Omarci"
    iconComponent: Component {
      Text {
        text: root.barState === "running" && root.ci ? root.ci.spinnerGlyph : "󰙨"
        color: root.pillColor
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton && root.ci) root.ci.syncGithub()
      else root.toggle()
    }
  }
}
