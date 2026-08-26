pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.matiacone.omarci"
  ipcTarget: "io.github.matiacone.omarci"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var ci: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property bool darkBg: {
    var c = Color.background
    return (c.r * 299 + c.g * 587 + c.b * 114) < 500
  }
  readonly property color success: darkBg ? "#8bc47a" : "#2f7d32"
  readonly property color pillColor: {
    if (!ci) return dim
    if (ci.barState === "fail") return urgent
    if (ci.barState === "pass") return success
    if (ci.barState === "running") return foreground
    return dim
  }
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var jobs: ci ? ci.visibleJobs() : []

  property int selectedIndex: 0
  property bool cursorActive: false
  property bool settingsOpen: false
  property string logText: ""
  property string followId: ""
  property var logLines: []

  readonly property var selectedJob: {
    if (jobs.length === 0) return null
    var i = Math.max(0, Math.min(selectedIndex, jobs.length - 1))
    return jobs[i]
  }

  readonly property string heroMeta: {
    if (!ci || !ci.latestJob) return "no jobs yet"
    if (ci.barState === "running") return "running"
    if (ci.barState === "fail") return "failed"
    if (ci.barState === "pass") return "passed"
    return ""
  }

  readonly property string selectedWhen: ci && selectedJob ? ci.formatDateTime(selectedJob) : ""

  function clampIndex() {
    if (jobs.length === 0) {
      selectedIndex = 0
      return
    }
    if (selectedIndex < 0) selectedIndex = 0
    if (selectedIndex >= jobs.length) selectedIndex = jobs.length - 1
  }

  function moveCursor(dy) {
    cursorActive = true
    if (jobs.length === 0) return
    selectedIndex = Math.max(0, Math.min(jobs.length - 1, selectedIndex + dy))
  }

  function selectIndex(index) {
    cursorActive = true
    selectedIndex = index
    clampIndex()
  }

  function statusColor(job) {
    if (!job) return dim
    if (job.status === "fail") return urgent
    if (job.status === "pass") return success
    return foreground
  }

  function rowMessage(job) {
    if (!job) return ""
    var msg = String(job.message || "")
    if (/^exit \d+$/.test(msg)) return ""
    return msg
  }

  function stripAnsi(s) {
    return String(s || "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
  }

  function tidyLogLine(line) {
    var s = String(line || "")
    var prefixed = s.match(/^(@?[\w./-]+(?::[\w@./-]+)+):\s(.*)$/)
    if (prefixed) s = prefixed[2]
    s = s.replace(/: (error TS\d+:)/, "\n  $1")
    return s
  }

  function lineKind(line) {
    var s = String(line || "")
    if (/^[─–—-]{2,}/.test(s) || /^──/.test(s)) return "section"
    if (/^\s*[✗×xX] /.test(s) || /\berror TS\d+|\bERROR\b|failed|not signing off/.test(s))
      return "error"
    if (/^\s*[✓✔] /.test(s)) return "ok"
    return "plain"
  }

  function rebuildLog(text) {
    var raw = stripAnsi(text).replace(/\r/g, "").split("\n")
    var lines = []
    var blanks = 0
    var maxLines = 200
    var maxLine = 2048
    for (var i = 0; i < raw.length && lines.length < maxLines; i++) {
      var line = tidyLogLine(String(raw[i]).replace(/[ \t]+$/g, ""))
      if (line.length > maxLine) line = line.substring(0, maxLine)
      if (line === "") {
        blanks++
        if (blanks > 1) continue
        lines.push({ text: " ", kind: "plain" })
        continue
      }
      blanks = 0
      var parts = line.split("\n")
      for (var p = 0; p < parts.length && lines.length < maxLines; p++) {
        var part = parts[p]
        if (part.length > maxLine) part = part.substring(0, maxLine)
        lines.push({ text: part, kind: lineKind(part) })
      }
    }
    logLines = lines
  }

  function followSelected() {
    var job = selectedJob
    var id = job ? String(job.id || "") : ""
    followId = id
    var path = ci ? ci.safeLogPath(job) : ""
    if (!id || !ci || path === "") {
      logText = ""
      logLines = []
      return
    }
    // Byte cap is on the process: tail -n only picks the window, head -c
    // stops stdout before StdioCollector can grow without bound.
    if (tailProc.running) tailProc.running = false
    tailProc.command = [
      "bash", "-c",
      "tail -n \"$1\" -- \"$3\" | head -c \"$2\"",
      "omarci-log-tail",
      "200",
      String(ci.maxLogBytes),
      path
    ]
    tailProc.running = true
  }

  function activateSelected() {
    if (!selectedJob || !ci) return
    ci.openLog(selectedJob.id)
  }

  function dismissSelected() {
    if (!selectedJob || !ci) return
    ci.dismiss(selectedJob.id)
  }

  function persistNotify(value) {
    if (ci) ci.setNotify(value)
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var key in current) if (key !== "id") entry[key] = current[key]
    entry.notify = !!value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setSettingsOpen(value) {
    settingsOpen = !!value
    if (!value)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  onJobsChanged: {
    clampIndex()
    if (opened) followSelected()
  }
  onSelectedIndexChanged: if (opened) followSelected()
  onOpenedChanged: {
    if (opened) {
      cursorActive = jobs.length > 0
      clampIndex()
      followSelected()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onFollowIdChanged: {
    if (logFlick) logFlick.contentY = 0
  }

  Timer {
    interval: 700
    running: root.opened && selectedJob && selectedJob.status === "running"
    repeat: true
    onTriggered: root.followSelected()
  }

  Process {
    id: tailProc
    stdout: StdioCollector {
      id: tailOut
      waitForEnd: true
      onStreamFinished: {
        root.logText = String(tailOut.text || "")
        root.rebuildLog(root.logText)
      }
    }
    onExited: function(code) {
      if (code !== 0 && String(tailOut.text || "").trim() === "") {
        root.logText = ""
        root.logLines = []
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: {
      if (root.settingsOpen)
        return panel.fittedContentHeight(Style.space(260), Style.space(320))
      if (root.jobs.length === 0)
        return panel.fittedContentHeight(Style.space(188), Style.space(220))
      return panel.cappedContentHeight(Style.space(560))
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        }
      }
      onActivateRequested: if (!root.settingsOpen) root.activateSelected()
      onDeleteRequested: if (!root.settingsOpen) root.dismissSelected()
      onCloseRequested: {
        if (root.settingsOpen) root.setSettingsOpen(false)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") { root.setSettingsOpen(!root.settingsOpen); return }
        if (root.settingsOpen) return
        if (t === "d" || t === "D") { if (root.ci) root.ci.clearFinished() }
        else if (t === "r" || t === "R") { if (root.ci) root.ci.reload() }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "Omarci"
          meta: root.settingsOpen ? "settings" : root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "󰙨"
              color: root.pillColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        Column {
          visible: root.settingsOpen
          Layout.fillWidth: true
          spacing: Style.space(12)

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            text: "SETTINGS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Notifications"
            description: "Desktop toast when a job passes or fails"
            checked: root.ci ? root.ci.notify : true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.persistNotify(!(root.ci && root.ci.notify))
          }
        }

        PanelSeparator {
          visible: !root.settingsOpen && root.jobs.length > 0
          Layout.fillWidth: true
          foreground: root.foreground
        }

        PanelSectionHeader {
          visible: !root.settingsOpen && root.jobs.length > 0
          Layout.fillWidth: true
          text: "JOBS"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Flickable {
          id: jobFlick
          visible: !root.settingsOpen && root.jobs.length > 0
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(jobColumn.implicitHeight, Style.space(168))
          contentWidth: width
          contentHeight: jobColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          Column {
            id: jobColumn
            width: jobFlick.width
            spacing: Style.space(4)

            Repeater {
              model: root.jobs
              delegate: Item {
                id: row
                required property var modelData
                required property int index
                width: jobColumn.width
                implicitHeight: Math.max(Style.space(40), rowLabels.implicitHeight + Style.space(10))

                readonly property bool selected: root.cursorActive && root.selectedIndex === index

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: row.selected ? Color.menu.selectedBackground : "transparent"
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(8)

                  Column {
                    id: rowLabels
                    width: parent.width - Style.space(56) - Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    Text {
                      width: parent.width
                      text: row.modelData && row.modelData.name ? row.modelData.name : "job"
                      color: root.statusColor(row.modelData)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: root.rowMessage(row.modelData) !== ""
                      width: parent.width
                      text: root.rowMessage(row.modelData)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(56)
                    spacing: 0

                    Text {
                      width: parent.width
                      text: root.ci ? root.ci.formatClock(row.modelData) : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                    }

                    Text {
                      width: parent.width
                      text: root.ci ? root.ci.formatElapsed(row.modelData) : ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onClicked: root.selectIndex(row.index)
                  onDoubleClicked: root.activateSelected()
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: !root.settingsOpen && root.selectedJob !== null
          Layout.fillWidth: true
          foreground: root.foreground
        }

        RowLayout {
          visible: !root.settingsOpen && root.selectedJob !== null
          Layout.fillWidth: true
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "LOG"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item { Layout.fillWidth: true }

          Text {
            visible: root.selectedWhen !== ""
            text: root.selectedWhen
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          id: logFrame
          visible: !root.settingsOpen && root.selectedJob !== null
          Layout.fillWidth: true
          Layout.fillHeight: !root.settingsOpen && root.selectedJob !== null
          Layout.minimumHeight: !root.settingsOpen && root.selectedJob !== null ? Style.space(140) : 0
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

          Text {
            visible: root.logLines.length === 0
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            text: "No log yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Flickable {
            id: logFlick
            anchors.fill: parent
            anchors.margins: Style.space(10)
            visible: root.logLines.length > 0
            clip: true
            contentWidth: width
            contentHeight: logColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: logColumn
              width: logFlick.width
              spacing: Style.space(2)

              Repeater {
                model: root.logLines
                delegate: Text {
                  required property var modelData
                  required property int index
                  width: logColumn.width
                  text: modelData && modelData.text ? modelData.text : ""
                  color: {
                    var kind = modelData && modelData.kind ? modelData.kind : "plain"
                    if (kind === "error") return root.urgent
                    if (kind === "ok" || kind === "section") return root.dim
                    return root.foreground
                  }
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: modelData && modelData.kind === "section"
                  wrapMode: Text.Wrap
                  lineHeight: 1.25
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: !root.settingsOpen && root.jobs.length > 0
          Layout.fillWidth: true
          foreground: root.foreground
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(6)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Row {
              visible: !root.settingsOpen
              spacing: Style.space(8)

              Button {
                text: "Open log"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedJob !== null
                onClicked: root.activateSelected()
              }

              Button {
                text: "Dismiss"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedJob !== null
                onClicked: root.dismissSelected()
              }

              Button {
                text: "Clear finished"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.jobs.length > 0
                onClicked: if (root.ci) root.ci.clearFinished()
              }
            }

            Item { Layout.fillWidth: true }

            Button {
              text: root.settingsOpen ? "Done" : "Settings"
              bordered: true
              fontFamily: root.fontFamily
              foreground: root.foreground
              fontSize: Style.font.caption
              onClicked: root.setSettingsOpen(!root.settingsOpen)
            }
          }

          Text {
            width: parent.width
            text: root.settingsOpen
              ? "s / Esc back"
              : "j/k select · Enter open log · x dismiss · d clear · s settings · Esc close"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
