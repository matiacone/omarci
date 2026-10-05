pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One panel: every watched repo's runs and the local jobs down the left, the
// selected item's jobs, steps and log on the right, its actions top right.
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
  readonly property color cardFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.04)
  readonly property color cardBorder: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)

  property int selectedIndex: 0
  property bool cursorActive: false
  property bool settingsOpen: false

  // ---- The list: runs per watched repo, then local jobs ----------------

  readonly property var jobs: ci ? ci.visibleJobs() : []

  readonly property var ghRepos: {
    if (!ci) return []
    var byName = {}
    var fetched = ci.github && ci.github.repos ? ci.github.repos : []
    for (var i = 0; i < fetched.length; i++) byName[String(fetched[i].repo).toLowerCase()] = fetched[i]
    var out = []
    var offset = 0
    for (var j = 0; j < ci.repos.length; j++) {
      var name = ci.repos[j]
      var entry = byName[String(name).toLowerCase()]
      var runs = entry && entry.runs ? entry.runs : []
      out.push({ repo: name, error: entry ? entry.error : null, runs: runs, offset: offset, loaded: !!entry })
      offset += runs.length
    }
    return out
  }

  readonly property int runCount: {
    var n = 0
    for (var i = 0; i < ghRepos.length; i++) n += ghRepos[i].runs.length
    return n
  }

  readonly property var items: {
    var out = []
    for (var i = 0; i < ghRepos.length; i++) {
      var runs = ghRepos[i].runs
      for (var j = 0; j < runs.length; j++) out.push({ kind: "run", repo: ghRepos[i].repo, run: runs[j] })
    }
    for (var k = 0; k < jobs.length; k++) out.push({ kind: "job", job: jobs[k] })
    return out
  }

  readonly property var selected: items.length === 0 ? null
    : items[Math.max(0, Math.min(selectedIndex, items.length - 1))]
  readonly property bool runSelected: selected !== null && selected.kind === "run"
  readonly property bool jobSelected: selected !== null && selected.kind === "job"
  readonly property var selectedRun: runSelected ? selected.run : null
  readonly property var selectedJob: jobSelected ? selected.job : null
  readonly property string runState: ci && selectedRun ? ci.runState(selectedRun) : ""
  readonly property bool runFailed: runState === "failure" || runState === "timed_out" || runState === "startup_failure"

  readonly property string heroMeta: {
    if (root.settingsOpen) return "settings"
    if (!ci) return ""
    var parts = []
    if (ci.ghActiveCount > 0) parts.push(ci.ghActiveCount + " running")
    if (ci.repos.length > 0) parts.push(ci.repos.length + (ci.repos.length === 1 ? " repo" : " repos"))
    if (jobs.length > 0) parts.push(jobs.length + (jobs.length === 1 ? " local job" : " local jobs"))
    return parts.length ? parts.join(" · ") : "nothing watched yet"
  }

  // ---- Detail pane state --------------------------------------------------

  // Jobs and failed log of the selected run, from `omarci gh view`.
  property var runDetail: null
  property string runDetailKey: ""
  property bool runDetailLoading: false
  // The log as one StyledText block: one item instead of hundreds of lines.
  property string logHtml: ""
  // Finished runs' details already seen this session, by runKey.
  property var detailCache: ({})

  function runKey(item) {
    if (!item || item.kind !== "run") return ""
    return item.repo + "#" + item.run.id + "#" + item.run.updatedAt + "#" + item.run.status
  }

  function clampIndex() {
    if (items.length === 0) selectedIndex = 0
    else selectedIndex = Math.max(0, Math.min(selectedIndex, items.length - 1))
  }

  function moveCursor(dy) {
    cursorActive = true
    if (items.length === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
  }

  // Mouse wheels move ~3 lines a notch; touchpads report exact pixels.
  function wheelScroll(flick, event) {
    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * Style.space(60)
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY - dy))
    event.accepted = true
  }

  function select(index) {
    cursorActive = true
    selectedIndex = index
    clampIndex()
  }

  function runColor(run) {
    var st = ci ? ci.runState(run) : ""
    if (st === "success") return success
    if (st === "failure" || st === "timed_out" || st === "startup_failure") return urgent
    if (st === "running" || st === "queued") return foreground
    return dim
  }

  function glyphFor(status, conclusion) {
    if (status === "in_progress") return ci ? ci.spinnerGlyph : "…"
    if (status && status !== "completed") return "○"
    if (conclusion === "success") return "✓"
    if (conclusion === "failure" || conclusion === "timed_out" || conclusion === "startup_failure") return "✗"
    if (conclusion === "cancelled") return "⊘"
    if (conclusion === "skipped") return "–"
    return "·"
  }

  function colorFor(status, conclusion) {
    if (status && status !== "completed") return foreground
    if (conclusion === "success") return success
    if (conclusion === "failure" || conclusion === "timed_out" || conclusion === "startup_failure") return urgent
    return dim
  }

  function jobGlyph(job) {
    if (!job) return "·"
    if (job.status === "running") return ci ? ci.spinnerGlyph : "…"
    if (job.status === "fail") return "✗"
    if (job.status === "pass") return "✓"
    return "·"
  }

  function jobColor(job) {
    if (!job) return dim
    if (job.status === "fail") return urgent
    if (job.status === "pass") return success
    return foreground
  }

  function ago(sec) {
    if (!ci || !sec) return ""
    return ci.shortDuration(ci.nowSec - sec) + " ago"
  }

  function stripAnsi(s) {
    return String(s || "").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
  }

  // GitHub's log lines are `job<TAB>step<TAB>timestamp text`; keep the text.
  function tidyLine(line) {
    var s = String(line || "")
    var tab = s.lastIndexOf("\t")
    if (tab >= 0) s = s.substring(tab + 1)
    s = s.replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z ?/, "")
    var prefixed = s.match(/^(@?[\w./-]+(?::[\w@./-]+)+):\s(.*)$/)
    if (prefixed) s = prefixed[2]
    return s.replace(/^##\[(group|endgroup|command)\]/, "").replace(/^##\[error\]/, "error: ")
  }

  function lineKind(line) {
    var s = String(line || "")
    if (/^[─–—-]{2,}/.test(s)) return "section"
    if (/^\s*[✗×] |^error: |\berror TS\d+|\bERROR\b|\bFAIL\b|failed|Failed/.test(s)) return "error"
    if (/^\s*[✓✔] /.test(s)) return "ok"
    return "plain"
  }

  function escapeHtml(t) {
    return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  function rebuildLog(text) {
    if (String(text || "").trim() === "") { logHtml = ""; return }
    var raw = stripAnsi(text).replace(/\r/g, "").split("\n")
    var errorColor = String(urgent)
    var dimColor = String(dim)
    var out = []
    var blanks = 0
    for (var i = 0; i < raw.length && out.length < 300; i++) {
      var line = tidyLine(raw[i]).replace(/[ \t]+$/g, "")
      if (line.length > 2048) line = line.substring(0, 2048)
      if (line === "") {
        if (++blanks > 1) continue
        out.push("")
        continue
      }
      blanks = 0
      var kind = lineKind(line)
      // Keep indentation: StyledText collapses runs of spaces.
      var html = escapeHtml(line).replace(/^ +/, function(m) { return Array(m.length + 1).join("&nbsp;") })
        .replace(/  /g, " &nbsp;")
      if (kind === "error") html = "<font color=\"" + errorColor + "\">" + html + "</font>"
      else if (kind === "ok" || kind === "section") html = "<font color=\"" + dimColor + "\">" + html + "</font>"
      out.push(html)
    }
    logHtml = out.join("<br>")
  }

  // Shows new detail content only once it is laid out and scrolled to its
  // end, so the pane never visibly jumps.
  function showDetail(apply) {
    detailFlick.opacity = 0
    apply()
    Qt.callLater(function() {
      root.scrollDetailToEnd()
      detailFlick.opacity = 1
    })
  }

  function refreshDetail() {
    var item = selected
    if (!item || !ci) {
      runDetail = null
      runDetailKey = ""
      logHtml = ""
      return
    }
    if (item.kind === "job") {
      runDetail = null
      runDetailKey = ""
      var path = ci.safeLogPath(item.job)
      if (path === "") { logHtml = ""; return }
      if (tailProc.running) tailProc.running = false
      tailProc.command = [
        "bash", "-c",
        "tail -n \"$1\" -- \"$3\" | head -c \"$2\"",
        "omarci-log-tail", "300", String(ci.maxLogBytes), path
      ]
      tailProc.running = true
      return
    }
    var key = runKey(item)
    if (key === runDetailKey && runDetail) return
    var cached = detailCache[key]
    if (cached) {
      runDetailKey = key
      showDetail(function() {
        root.runDetail = cached
        root.rebuildLog(cached.log || "")
      })
      return
    }
    if (key !== runDetailKey) {
      runDetail = null
      logHtml = ""
    }
    runDetailKey = key
    runDetailLoading = true
    if (detailProc.running) detailProc.running = false
    detailProc.command = [ci.cliPath, "gh", "view", String(item.repo), String(item.run.id)]
    detailProc.running = true
  }

  // A log's verdict, or its error, is at the end.
  function scrollDetailToEnd() {
    if (logHtml === "") { detailFlick.contentY = 0; return }
    detailFlick.contentY = Math.max(0, detailFlick.contentHeight - detailFlick.height)
  }

  readonly property bool canRetry: selectedRun !== null && selectedRun.status === "completed"
  readonly property bool canCancel: selectedRun !== null && ci !== null && ci.runIsActive(selectedRun)

  // Open: the run on github.com, or a local job's log in a terminal.
  function openSelected() {
    if (!ci || !selected) return
    if (runSelected) ci.openRun(selected.repo, selectedRun.id)
    else ci.openLog(selectedJob.id)
  }

  // Retry: the failed jobs of a failed run, the whole run otherwise.
  function retrySelected() {
    if (!ci || !canRetry) return
    if (runFailed) ci.rerunFailed(selected.repo, selectedRun.id)
    else ci.rerunAll(selected.repo, selectedRun.id)
  }

  function cancelSelected() {
    if (ci && canCancel) ci.cancelRun(selected.repo, selectedRun.id)
  }

  function addRepoFromField() {
    if (ci) ci.addRepo(repoField.text)
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

  onItemsChanged: {
    clampIndex()
    if (opened) detailDebounce.restart()
  }
  onSelectedIndexChanged: {
    if (detailFlick) detailFlick.contentY = 0
    if (opened) detailDebounce.restart()
  }
  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      clampIndex()
      runDetailKey = ""
      refreshDetail()
      if (ci) ci.syncGithub()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  Connections {
    target: root.ci
    function onAddingRepoChanged() {
      if (root.ci && !root.ci.addingRepo && root.ci.repoError === "") repoField.text = ""
    }
  }

  Timer {
    id: detailDebounce
    interval: 120
    onTriggered: root.refreshDetail()
  }

  // Keeps the detail pane live while the selected item is still running.
  Timer {
    interval: root.runSelected ? 8000 : 700
    running: root.opened && root.selected !== null
      && (root.selectedRun ? (root.ci !== null && root.ci.runIsActive(root.selectedRun))
                           : (root.selectedJob !== null && root.selectedJob.status === "running"))
    repeat: true
    onTriggered: {
      if (root.runSelected) root.runDetailKey = ""
      root.refreshDetail()
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      id: detailOut
      waitForEnd: true
    }
    onExited: function(code) {
      root.runDetailLoading = false
      if (code !== 0) return
      try {
        var parsed = JSON.parse(String(detailOut.text || ""))
        var key = root.runDetailKey
        var finished = Array.isArray(parsed.jobs) && parsed.jobs.length > 0
          && parsed.jobs.every(function(j) { return j.status === "completed" })
        if (finished) {
          var next = Object.assign({}, root.detailCache)
          next[key] = parsed
          root.detailCache = next
        }
        var first = !root.runDetail
        var apply = function() {
          root.runDetail = parsed
          root.rebuildLog(parsed.log || "")
        }
        // A live refresh of the same run keeps the reader's scroll position.
        if (first) root.showDetail(apply)
        else apply()
      } catch (e) {
        console.warn("omarci: bad run detail", e)
      }
    }
  }

  Process {
    id: tailProc
    stdout: StdioCollector {
      id: tailOut
      waitForEnd: true
      onStreamFinished: {
        var text = String(tailOut.text || "")
        root.showDetail(function() { root.rebuildLog(text) })
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
    contentWidth: panel.fittedContentWidth(Style.space(940))
    contentHeight: root.settingsOpen
      ? panel.fittedContentHeight(Style.space(320), Style.space(460))
      : panel.cappedContentHeight(Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: repoField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.settingsOpen || dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (!root.settingsOpen) root.openSelected()
      onCloseRequested: {
        if (root.settingsOpen) root.setSettingsOpen(false)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") { root.setSettingsOpen(!root.settingsOpen); return }
        if (root.settingsOpen) return
        if (t === "r" || t === "R") root.retrySelected()
        else if (t === "c" || t === "C") root.cancelSelected()
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- Header: title left, every action right -----------------------

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

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
            Layout.alignment: Qt.AlignTop | Qt.AlignRight
            spacing: Style.space(6)

            Button {
              visible: !root.settingsOpen && root.selected !== null
              text: "Open"
              tooltipText: root.runSelected ? "Open the run on github.com (Enter)" : "Open the log in a terminal (Enter)"
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
              onClicked: root.openSelected()
            }
            Button {
              visible: !root.settingsOpen && root.canRetry
              text: "Retry"
              tooltipText: root.runFailed ? "Re-run the failed jobs (r)" : "Re-run the whole run (r)"
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
              onClicked: root.retrySelected()
            }
            Button {
              visible: !root.settingsOpen && root.canCancel
              text: "Cancel"
              tooltipText: "Cancel the run (c)"
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
              onClicked: root.cancelSelected()
            }
            Button {
              text: root.settingsOpen ? "Done" : ""
              iconText: root.settingsOpen ? "" : "󰒓"
              tooltipText: root.settingsOpen ? "Back (s)" : "Watched repos and notifications (s)"
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
              onClicked: root.setSettingsOpen(!root.settingsOpen)
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---- Settings ----------------------------------------------------

        Column {
          visible: root.settingsOpen
          Layout.fillWidth: true
          spacing: Style.space(12)

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
                bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
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
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
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

        // ---- Body: list left, detail right ------------------------------

        RowLayout {
          visible: !root.settingsOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(10)

          // Left: one card per watched repo, then local jobs.
          Flickable {
            id: listFlick
            Layout.preferredWidth: Style.space(360)
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            WheelHandler {
              target: null
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: function(event) { root.wheelScroll(listFlick, event) }
            }

            Column {
              id: listColumn
              width: listFlick.width
              spacing: Style.space(10)

              Column {
                visible: root.items.length === 0 && (!root.ci || root.ci.repos.length === 0)
                width: parent.width
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
                  bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
                  onClicked: {
                    root.setSettingsOpen(true)
                    Qt.callLater(function() { repoField.forceActiveFocus() })
                  }
                }
              }

              Repeater {
                model: root.ghRepos
                delegate: Rectangle {
                  id: card
                  required property var modelData
                  width: listColumn.width
                  implicitHeight: cardColumn.implicitHeight + Style.space(12)
                  radius: Style.cornerRadius
                  color: root.cardFill
                  border.width: 1
                  border.color: root.cardBorder

                  Column {
                    id: cardColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(6)
                    spacing: Style.space(1)

                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        Layout.fillWidth: true
                        leftPadding: Style.space(4)
                        text: String(card.modelData.repo)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        text: card.modelData.error ? "can't read"
                          : !card.modelData.loaded ? "loading…"
                          : card.modelData.runs.length === 0 ? "no runs" : ""
                        visible: text !== ""
                        color: card.modelData.error ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Repeater {
                      model: card.modelData.runs
                      delegate: Item {
                        id: runRow
                        required property var modelData
                        required property int index
                        readonly property int flatIndex: card.modelData.offset + index
                        readonly property bool isSelected: root.selectedIndex === flatIndex
                        width: cardColumn.width
                        implicitHeight: runText.implicitHeight + Style.space(8)

                        Rectangle {
                          anchors.fill: parent
                          radius: Style.cornerRadius
                          color: runRow.isSelected ? Color.menu.selectedBackground : "transparent"
                        }

                        Row {
                          anchors.fill: parent
                          anchors.leftMargin: Style.space(4)
                          anchors.rightMargin: Style.space(4)
                          spacing: Style.space(6)

                          Text {
                            width: Style.space(14)
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.glyphFor(runRow.modelData.status, runRow.modelData.conclusion)
                            color: root.runColor(runRow.modelData)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            horizontalAlignment: Text.AlignHCenter
                          }

                          Column {
                            id: runText
                            width: parent.width - Style.space(14) - Style.space(64) - Style.space(12)
                            anchors.verticalCenter: parent.verticalCenter

                            Text {
                              width: parent.width
                              text: (runRow.modelData.workflow || "workflow") + " · " + (runRow.modelData.branch || "")
                              color: root.foreground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }

                            Text {
                              width: parent.width
                              text: runRow.modelData.title || ""
                              color: root.dim
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              elide: Text.ElideRight
                            }
                          }

                          Text {
                            width: Style.space(64)
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.ci && root.ci.runIsActive(runRow.modelData)
                              ? root.ci.runTiming(runRow.modelData)
                              : root.ago(runRow.modelData.updatedAt)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            horizontalAlignment: Text.AlignRight
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          onClicked: root.select(runRow.flatIndex)
                          onDoubleClicked: root.openSelected()
                        }
                      }
                    }
                  }
                }
              }

              Rectangle {
                visible: root.jobs.length > 0
                width: listColumn.width
                implicitHeight: jobsColumn.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: root.cardFill
                border.width: 1
                border.color: root.cardBorder

                Column {
                  id: jobsColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(6)
                  spacing: Style.space(1)

                  Text {
                    leftPadding: Style.space(4)
                    text: "Local jobs"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Repeater {
                    model: root.jobs
                    delegate: Item {
                      id: jobRow
                      required property var modelData
                      required property int index
                      readonly property int flatIndex: root.runCount + index
                      readonly property bool isSelected: root.selectedIndex === flatIndex
                      width: jobsColumn.width
                      implicitHeight: jobText.implicitHeight + Style.space(8)

                      Rectangle {
                        anchors.fill: parent
                        radius: Style.cornerRadius
                        color: jobRow.isSelected ? Color.menu.selectedBackground : "transparent"
                      }

                      Row {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(4)
                        anchors.rightMargin: Style.space(4)
                        spacing: Style.space(6)

                        Text {
                          width: Style.space(14)
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.jobGlyph(jobRow.modelData)
                          color: root.jobColor(jobRow.modelData)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          horizontalAlignment: Text.AlignHCenter
                        }

                        Column {
                          id: jobText
                          width: parent.width - Style.space(14) - Style.space(64) - Style.space(12)
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            width: parent.width
                            text: jobRow.modelData.name || "job"
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideRight
                          }
                        }

                        Text {
                          width: Style.space(64)
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.ci ? root.ci.formatElapsed(jobRow.modelData) : ""
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignRight
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        onClicked: root.select(jobRow.flatIndex)
                        onDoubleClicked: root.openSelected()
                      }
                    }
                  }
                }
              }
            }
          }

          // Right: what the selected run or job did.
          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: root.cardFill
            border.width: 1
            border.color: root.cardBorder

            Text {
              visible: root.selected === null
              anchors.centerIn: parent
              text: "Select a run or job"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Flickable {
              id: detailFlick
              visible: root.selected !== null
              anchors.fill: parent
              anchors.margins: Style.space(10)
              clip: true
              contentWidth: width
              contentHeight: detailColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick
              interactive: contentHeight > height
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              WheelHandler {
                target: null
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(event) { root.wheelScroll(detailFlick, event) }
              }

              Column {
                id: detailColumn
                width: detailFlick.width
                spacing: Style.space(6)

                // Run header
                Column {
                  visible: root.runSelected
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: root.selectedRun
                      ? root.glyphFor(root.selectedRun.status, root.selectedRun.conclusion) + "  "
                        + (root.selectedRun.workflow || "") + " · " + (root.selectedRun.branch || "")
                      : ""
                    color: root.selectedRun ? root.runColor(root.selectedRun) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.selectedRun ? (root.selectedRun.title || "") : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.selectedRun && root.ci
                      ? root.selected.repo + " · " + (root.selectedRun.sha || "") + " · "
                        + (root.selectedRun.actor || "") + " · " + root.ci.runLabel(root.selectedRun)
                        + " · " + root.ci.runTiming(root.selectedRun)
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // Job header
                Column {
                  visible: root.jobSelected
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: root.selectedJob ? root.jobGlyph(root.selectedJob) + "  " + (root.selectedJob.name || "job") : ""
                    color: root.selectedJob ? root.jobColor(root.selectedJob) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.selectedJob && root.ci
                      ? "local job · " + root.ci.formatDateTime(root.selectedJob) + " · " + root.ci.formatElapsed(root.selectedJob)
                        + (root.selectedJob.message ? " · " + root.selectedJob.message : "")
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelSeparator { width: parent.width; foreground: root.foreground }

                // The run's jobs and their steps.
                Text {
                  visible: root.runSelected && root.runDetailLoading && !root.runDetail
                  text: "Loading jobs and log…"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: root.runSelected && root.runDetail ? root.runDetail.jobs : []
                  delegate: Column {
                    id: ghJob
                    required property var modelData
                    width: detailColumn.width
                    spacing: 0

                    Text {
                      width: parent.width
                      text: root.glyphFor(ghJob.modelData.status, ghJob.modelData.conclusion) + "  " + (ghJob.modelData.name || "job")
                        + (ghJob.modelData.startedAt && root.ci
                           ? "   " + root.ci.formatSeconds((ghJob.modelData.completedAt || root.ci.nowSec) - ghJob.modelData.startedAt)
                           : "")
                      color: root.colorFor(ghJob.modelData.status, ghJob.modelData.conclusion)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Repeater {
                      model: ghJob.modelData.steps || []
                      delegate: Text {
                        required property var modelData
                        width: ghJob.width
                        leftPadding: Style.space(20)
                        text: root.glyphFor(modelData.status, modelData.conclusion) + "  " + (modelData.name || "")
                        color: modelData.conclusion === "success" ? root.dim
                          : root.colorFor(modelData.status, modelData.conclusion)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                PanelSectionHeader {
                  visible: root.logHtml !== ""
                  text: root.runSelected && root.runDetail && root.runDetail.logKind === "failed" ? "FAILED JOBS' LOG" : "LOG"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  visible: root.selectedRun !== null && root.ci !== null && root.ci.runIsActive(root.selectedRun)
                  width: parent.width
                  text: "The log appears here when the run finishes; Open shows it live on github.com."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: root.jobSelected && root.logHtml === ""
                  text: "No log yet."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: root.logHtml !== ""
                  width: detailColumn.width
                  text: root.logHtml
                  textFormat: Text.StyledText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.Wrap
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          text: root.settingsOpen
            ? "Enter adds a repo · s / Esc back"
            : "j/k select · Enter open · r retry · c cancel · s settings · Esc close"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
