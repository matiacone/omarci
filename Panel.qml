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

  // "github": the watched repos' Actions runs. "local": omarci's own jobs.
  property string view: "github"
  readonly property bool githubView: !settingsOpen && view === "github"
  readonly property bool localView: !settingsOpen && view === "local"

  property int selectedIndex: 0
  property int ghIndex: 0
  property bool cursorActive: false
  property bool settingsOpen: false
  property string logText: ""
  property string followId: ""
  property var logLines: []

  // The watched repos in the order they were added, each with its runs.
  readonly property var ghRepos: {
    if (!ci) return []
    var byName = {}
    var fetched = ci.github && ci.github.repos ? ci.github.repos : []
    for (var i = 0; i < fetched.length; i++) byName[String(fetched[i].repo).toLowerCase()] = fetched[i]
    var out = []
    var offset = 0
    for (var j = 0; j < ci.repos.length; j++) {
      var name = ci.repos[j]
      var entry = byName[String(name).toLowerCase()] || { repo: name, error: null, runs: [] }
      var runs = entry.runs || []
      out.push({ repo: name, error: entry.error, runs: runs, offset: offset, loaded: !!byName[String(name).toLowerCase()] })
      offset += runs.length
    }
    return out
  }

  // Every run across the repos, so j/k walks them in display order.
  readonly property var ghRows: {
    var rows = []
    for (var i = 0; i < ghRepos.length; i++) {
      var runs = ghRepos[i].runs
      for (var j = 0; j < runs.length; j++) rows.push({ repo: ghRepos[i].repo, run: runs[j] })
    }
    return rows
  }

  readonly property var selectedRow: {
    if (ghRows.length === 0) return null
    return ghRows[Math.max(0, Math.min(ghIndex, ghRows.length - 1))]
  }
  readonly property var selectedRun: selectedRow ? selectedRow.run : null
  readonly property string selectedRunState: ci && selectedRun ? ci.runState(selectedRun) : ""

  readonly property var selectedJob: {
    if (jobs.length === 0) return null
    var i = Math.max(0, Math.min(selectedIndex, jobs.length - 1))
    return jobs[i]
  }

  readonly property string heroMeta: {
    if (root.settingsOpen) return "settings"
    if (!ci) return ""
    if (root.view === "github") {
      if (ci.repos.length === 0) return "no repos watched"
      if (ci.ghActiveCount > 0) return ci.ghActiveCount + " running"
      return ci.repos.length + (ci.repos.length === 1 ? " repo" : " repos")
    }
    if (!ci.latestJob) return "no jobs yet"
    if (ci.localState === "running") return "running"
    if (ci.localState === "fail") return "failed"
    if (ci.localState === "pass") return "passed"
    return ""
  }

  readonly property string selectedWhen: ci && selectedJob ? ci.formatDateTime(selectedJob) : ""

  function clampIndex() {
    if (jobs.length === 0) selectedIndex = 0
    else selectedIndex = Math.max(0, Math.min(selectedIndex, jobs.length - 1))
    if (ghRows.length === 0) ghIndex = 0
    else ghIndex = Math.max(0, Math.min(ghIndex, ghRows.length - 1))
  }

  function moveCursor(dy) {
    cursorActive = true
    if (root.view === "github") {
      if (ghRows.length === 0) return
      ghIndex = Math.max(0, Math.min(ghRows.length - 1, ghIndex + dy))
      return
    }
    if (jobs.length === 0) return
    selectedIndex = Math.max(0, Math.min(jobs.length - 1, selectedIndex + dy))
  }

  function selectIndex(index) {
    cursorActive = true
    selectedIndex = index
    clampIndex()
  }

  function selectRun(index) {
    cursorActive = true
    ghIndex = index
    clampIndex()
  }

  function setView(value) {
    view = value
    cursorActive = false
    clampIndex()
    if (value === "local") followSelected()
  }

  function statusColor(job) {
    if (!job) return dim
    if (job.status === "fail") return urgent
    if (job.status === "pass") return success
    return foreground
  }

  function runColor(run) {
    var st = ci ? ci.runState(run) : ""
    if (st === "success") return success
    if (st === "failure" || st === "timed_out" || st === "startup_failure") return urgent
    if (st === "running" || st === "queued") return foreground
    return dim
  }

  function runGlyph(run) {
    var st = ci ? ci.runState(run) : ""
    if (st === "running") return ci.spinnerGlyph
    if (st === "queued") return "○"
    if (st === "success") return "✓"
    if (st === "failure" || st === "timed_out" || st === "startup_failure") return "✗"
    if (st === "cancelled") return "⊘"
    return "·"
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
    if (!ci) return
    if (root.view === "github") {
      if (selectedRow) ci.openRun(selectedRow.repo, selectedRun.id)
      return
    }
    if (selectedJob) ci.openLog(selectedJob.id)
  }

  function dismissSelected() {
    if (!selectedJob || !ci || root.view !== "local") return
    ci.dismiss(selectedJob.id)
  }

  function refresh() {
    if (!ci) return
    ci.reload()
    ci.syncGithub()
  }

  function addRepoFromField() {
    if (!ci) return
    ci.addRepo(repoField.text)
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
    if (opened && root.view === "local") followSelected()
  }
  onGhRowsChanged: clampIndex()
  onSelectedIndexChanged: if (opened && root.view === "local") followSelected()
  onOpenedChanged: {
    if (opened) {
      if (ci && ci.repos.length === 0 && jobs.length > 0) view = "local"
      cursorActive = false
      clampIndex()
      if (root.view === "local") followSelected()
      if (ci) ci.syncGithub()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onFollowIdChanged: {
    if (logFlick) logFlick.contentY = 0
  }

  Connections {
    target: root.ci
    function onRepoErrorChanged() {
      if (root.ci && root.ci.repoError === "" && !root.ci.addingRepo) repoField.text = ""
    }
    function onAddingRepoChanged() {
      if (root.ci && !root.ci.addingRepo && root.ci.repoError === "") repoField.text = ""
    }
  }

  Timer {
    interval: 700
    running: root.opened && root.view === "local" && selectedJob && selectedJob.status === "running"
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
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: {
      if (root.settingsOpen)
        return panel.fittedContentHeight(Style.space(320), Style.space(460))
      if (root.localView && root.jobs.length === 0)
        return panel.fittedContentHeight(Style.space(188), Style.space(220))
      return panel.cappedContentHeight(Style.space(600))
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: repoField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.settingsOpen) return
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
        if (t === "g" || t === "G") { root.setView(root.view === "github" ? "local" : "github"); return }
        if (t === "r") { root.refresh(); return }
        if (root.view === "github") {
          if (!root.selectedRow || !root.ci) return
          if (t === "f") root.ci.openFailedLog(root.selectedRow.repo, root.selectedRun.id)
          else if (t === "R") root.ci.rerunFailed(root.selectedRow.repo, root.selectedRun.id)
          else if (t === "c") root.ci.cancelRun(root.selectedRow.repo, root.selectedRun.id)
          return
        }
        if (t === "d" || t === "D") { if (root.ci) root.ci.clearFinished() }
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        PanelHero {
          Layout.fillWidth: true
          title: "Omarci"
          meta: root.heroMeta
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

        Row {
          visible: !root.settingsOpen
          Layout.fillWidth: true
          spacing: Style.space(6)

          Button {
            text: "GitHub"
            bordered: true
            selected: root.view === "github"
            fontFamily: root.fontFamily
            foreground: root.foreground
            fontSize: Style.font.caption
            onClicked: root.setView("github")
          }

          Button {
            text: "Local"
            bordered: true
            selected: root.view === "local"
            fontFamily: root.fontFamily
            foreground: root.foreground
            fontSize: Style.font.caption
            onClicked: root.setView("local")
          }
        }

        // ---- Settings -------------------------------------------------

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
            description: "Desktop toast when a local job, or a GitHub run you started, finishes"
            checked: root.ci ? root.ci.notify : true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.persistNotify(!(root.ci && root.ci.notify))
          }

          PanelSectionHeader {
            text: "WATCHED REPOS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.ci ? root.ci.repos : []
            delegate: RowLayout {
              id: repoRow
              required property var modelData
              width: parent ? parent.width : 0
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: String(repoRow.modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Button {
                text: "Remove"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                onClicked: if (root.ci) root.ci.removeRepo(repoRow.modelData)
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: repoField
              Layout.fillWidth: true
              placeholderText: "owner/repo or a github.com URL"
              foreground: root.foreground
              font.family: root.fontFamily
              enabled: !(root.ci && root.ci.addingRepo)
              onAccepted: root.addRepoFromField()
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Button {
              text: root.ci && root.ci.addingRepo ? "Adding…" : "Add"
              bordered: true
              fontFamily: root.fontFamily
              foreground: root.foreground
              fontSize: Style.font.caption
              enabled: repoField.text.trim() !== "" && !(root.ci && root.ci.addingRepo)
              onClicked: root.addRepoFromField()
            }
          }

          Text {
            visible: root.ci && root.ci.repoError !== ""
            width: parent.width
            text: root.ci ? root.ci.repoError : ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---- GitHub runs ----------------------------------------------

        Column {
          visible: root.githubView && root.ghRepos.length === 0
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "No repos watched yet. Add one to see its GitHub Actions runs here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            text: "Add a repo"
            bordered: true
            fontFamily: root.fontFamily
            foreground: root.foreground
            fontSize: Style.font.caption
            onClicked: {
              root.setSettingsOpen(true)
              Qt.callLater(function() { repoField.forceActiveFocus() })
            }
          }
        }

        Flickable {
          id: ghFlick
          visible: root.githubView && root.ghRepos.length > 0
          Layout.fillWidth: true
          Layout.fillHeight: root.githubView
          Layout.minimumHeight: root.githubView ? Style.space(160) : 0
          contentWidth: width
          contentHeight: repoColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: repoColumn
            width: ghFlick.width
            spacing: Style.space(10)

            Repeater {
              model: root.ghRepos
              delegate: Rectangle {
                id: card
                required property var modelData
                width: repoColumn.width
                implicitHeight: cardColumn.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)

                Column {
                  id: cardColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(8)
                  spacing: Style.space(2)

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      Layout.fillWidth: true
                      text: String(card.modelData.repo)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      text: {
                        if (card.modelData.error) return "can't read"
                        if (!card.modelData.loaded) return "loading…"
                        if (card.modelData.runs.length === 0) return "no runs"
                        return ""
                      }
                      visible: text !== ""
                      color: card.modelData.error ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    visible: !!card.modelData.error
                    width: parent.width
                    text: card.modelData.error ? String(card.modelData.error) : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }

                  Repeater {
                    model: card.modelData.runs
                    delegate: Item {
                      id: runRow
                      required property var modelData
                      required property int index
                      readonly property int flatIndex: card.modelData.offset + index
                      readonly property bool selected: root.cursorActive && root.ghIndex === flatIndex
                      width: cardColumn.width
                      implicitHeight: Math.max(Style.space(38), runLabels.implicitHeight + Style.space(8))

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: runRow.selected ? Color.menu.selectedBackground : "transparent"
                      }

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(6)
                        anchors.rightMargin: Style.space(6)
                        spacing: Style.space(8)

                        Text {
                          width: Style.space(14)
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.runGlyph(runRow.modelData)
                          color: root.runColor(runRow.modelData)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          horizontalAlignment: Text.AlignHCenter
                        }

                        Column {
                          id: runLabels
                          width: parent.width - Style.space(14) - Style.space(96) - Style.space(16)
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: 0

                          Text {
                            width: parent.width
                            text: (runRow.modelData.workflow || "workflow") + "  ·  " + (runRow.modelData.branch || "")
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideRight
                          }

                          Text {
                            width: parent.width
                            text: (runRow.modelData.title || "") + "  ·  " + (runRow.modelData.actor || "")
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }
                        }

                        Text {
                          width: Style.space(96)
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.ci ? root.ci.runTiming(runRow.modelData) : ""
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignRight
                          elide: Text.ElideLeft
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.selectRun(runRow.flatIndex)
                        onDoubleClicked: if (root.ci) root.ci.openRun(card.modelData.repo, runRow.modelData.id)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ---- Local jobs -----------------------------------------------

        Text {
          visible: root.localView && root.jobs.length === 0
          Layout.fillWidth: true
          text: "No local jobs. Start one with `omarci run -- <command>`."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Flickable {
          id: jobFlick
          visible: root.localView && root.jobs.length > 0
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

        RowLayout {
          visible: root.localView && root.selectedJob !== null
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
          visible: root.localView && root.selectedJob !== null
          Layout.fillWidth: true
          Layout.fillHeight: root.localView && root.selectedJob !== null
          Layout.minimumHeight: root.localView && root.selectedJob !== null ? Style.space(140) : 0
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

        // ---- Actions ---------------------------------------------------

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        Column {
          Layout.fillWidth: true
          spacing: Style.space(6)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Flow {
              visible: root.githubView
              Layout.fillWidth: true
              spacing: Style.space(6)

              Button {
                text: "Open"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedRow !== null
                onClicked: root.ci.openRun(root.selectedRow.repo, root.selectedRun.id)
              }

              Button {
                text: "Re-run failed"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedRunState === "failure" || root.selectedRunState === "cancelled"
                  || root.selectedRunState === "timed_out"
                onClicked: root.ci.rerunFailed(root.selectedRow.repo, root.selectedRun.id)
              }

              Button {
                text: "Re-run all"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedRun !== null && root.selectedRun.status === "completed"
                onClicked: root.ci.rerunAll(root.selectedRow.repo, root.selectedRun.id)
              }

              Button {
                text: "Cancel"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedRunState === "running" || root.selectedRunState === "queued"
                onClicked: root.ci.cancelRun(root.selectedRow.repo, root.selectedRun.id)
              }

              Button {
                text: "Failed log"
                bordered: true
                fontFamily: root.fontFamily
                foreground: root.foreground
                fontSize: Style.font.caption
                enabled: root.selectedRunState === "failure" || root.selectedRunState === "timed_out"
                onClicked: root.ci.openFailedLog(root.selectedRow.repo, root.selectedRun.id)
              }
            }

            Row {
              visible: root.localView
              Layout.fillWidth: true
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

            Item { visible: root.settingsOpen; Layout.fillWidth: true }

            Button {
              Layout.alignment: Qt.AlignTop
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
            text: {
              if (root.settingsOpen) return "Enter adds a repo · s / Esc back"
              if (root.view === "github")
                return "j/k select · Enter open · R re-run failed · c cancel · f failed log · r refresh · g local · s settings"
              return "j/k select · Enter open log · x dismiss · d clear · g GitHub · s settings · Esc close"
            }
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
