pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One panel: each watched repo's runs down the left, the selected run's jobs,
// steps and log on the right, Open / Retry / Cancel top right.
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
  property bool settingsOpen: false

  // ---- The list: each watched repo's runs ---------------------------------

  readonly property var repoCards: {
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

  readonly property var items: {
    var out = []
    for (var i = 0; i < repoCards.length; i++) {
      var runs = repoCards[i].runs
      for (var j = 0; j < runs.length; j++) out.push({ repo: repoCards[i].repo, run: runs[j] })
    }
    return out
  }

  readonly property var selected: items.length === 0 ? null
    : items[Math.max(0, Math.min(selectedIndex, items.length - 1))]
  readonly property var selectedRun: selected ? selected.run : null
  readonly property bool selectedFailed: {
    var st = ci && selectedRun ? ci.runState(selectedRun) : ""
    return st === "failure" || st === "timed_out" || st === "startup_failure"
  }
  readonly property bool canRetry: selectedRun !== null && selectedRun.status === "completed"
  readonly property bool canCancel: selectedRun !== null && ci !== null && ci.runIsActive(selectedRun)

  readonly property string heroMeta: {
    if (root.settingsOpen) return "settings"
    if (!ci) return ""
    if (ci.repos.length === 0) return "no repos watched"
    var parts = []
    if (ci.activeCount > 0) parts.push(ci.activeCount + " running")
    parts.push(ci.repos.length + (ci.repos.length === 1 ? " repo" : " repos"))
    return parts.join(" · ")
  }

  // ---- The detail pane ------------------------------------------------------
  //
  // The pane shows `shown`, not the selection: a click moves the highlight at
  // once, and the pane swaps header, jobs and log together when the new run's
  // details are ready, already scrolled to the log's end. Nothing blanks or
  // blinks in between.

  property var shown: null          // { repo, run } the pane displays
  property var shownDetail: null    // its { jobs, log, logKind }
  property string shownLogHtml: ""
  property var pendingItem: null    // the run being fetched
  property bool loading: false
  property var detailCache: ({})    // finished runs seen this session, by runKey

  function runKey(item) {
    if (!item) return ""
    return item.repo + "#" + item.run.id + "#" + item.run.attempt + "#" + item.run.status + "#" + item.run.updatedAt
  }

  function isFinished(detail) {
    return !!detail && Array.isArray(detail.jobs) && detail.jobs.length > 0
      && detail.jobs.every(function(j) { return j.status === "completed" })
  }

  function clampIndex() {
    selectedIndex = items.length === 0 ? 0 : Math.max(0, Math.min(selectedIndex, items.length - 1))
  }

  function moveCursor(dy) {
    if (items.length === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
  }

  function select(index) {
    selectedIndex = index
    clampIndex()
  }

  // Mouse wheels move ~3 lines a notch; touchpads report exact pixels.
  function wheelScroll(flick, event) {
    var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * Style.space(60)
    var max = Math.max(0, flick.contentHeight - flick.height)
    flick.contentY = Math.max(0, Math.min(max, flick.contentY - dy))
    event.accepted = true
  }

  function runColor(run) {
    return colorFor(run ? run.status : "", run ? run.conclusion : "")
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

  function ago(sec) {
    return ci && sec ? ci.shortDuration(ci.nowSec - sec) + " ago" : ""
  }

  // GitHub's log lines are `job<TAB>step<TAB>timestamp text`; keep the text.
  function tidyLine(line) {
    var s = String(line || "")
    var tab = s.lastIndexOf("\t")
    if (tab >= 0) s = s.substring(tab + 1)
    s = s.replace(/^\ufeff/, "").replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z ?/, "")
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

  // The log as one StyledText block: one item instead of hundreds of lines.
  function logHtmlFor(text) {
    if (String(text || "").trim() === "") return ""
    // Colour codes arrive as real escapes or, from GitHub, as literal "^[[…m".
    var raw = String(text).replace(/(\x1b|\^\[)\[[0-9;?]*[A-Za-z]/g, "").replace(/\r/g, "").split("\n")
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
    return out.join("<br>")
  }

  // Puts a run and its details in the pane in one step, laid out and
  // scrolled before the next frame paints. A live refresh of the run already
  // shown keeps the reader's scroll position.
  function show(item, detail, keepScroll) {
    var sameRun = shown !== null && shown.repo === item.repo && shown.run.id === item.run.id
    shown = item
    shownDetail = detail
    shownLogHtml = detail ? logHtmlFor(detail.log || "") : ""
    if (keepScroll && sameRun) return
    detailColumn.forceLayout()
    var max = Math.max(0, detailColumn.implicitHeight - detailFlick.height)
    detailFlick.contentY = shownLogHtml === "" ? 0 : max
  }

  function refreshDetail(force) {
    var item = selected
    if (!item || !ci) {
      shown = null
      shownDetail = null
      shownLogHtml = ""
      return
    }
    var key = runKey(item)
    var cached = detailCache[key]
    if (cached && !force) {
      show(item, cached, false)
      return
    }
    if (detailProc.running && runKey(pendingItem) === key) return
    pendingItem = item
    loading = true
    if (detailProc.running) detailProc.running = false
    detailProc.command = [ci.cliPath, "gh", "view", String(item.repo), String(item.run.id)]
    detailProc.running = true
  }

  function openSelected() {
    if (ci && selected) ci.openRun(selected.repo, selectedRun.id)
  }

  // Retry: the failed jobs of a failed run, the whole run otherwise.
  function retrySelected() {
    if (!ci || !canRetry) return
    if (selectedFailed) ci.rerunFailed(selected.repo, selectedRun.id)
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
    if (opened) refreshDetail(false)
  }
  onSelectedIndexChanged: if (opened) refreshDetail(false)
  onOpenedChanged: {
    if (opened) {
      clampIndex()
      refreshDetail(false)
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

  // Keeps the pane live while the shown run is still running.
  Timer {
    interval: 8000
    running: root.opened && root.shown !== null && root.ci !== null && root.ci.runIsActive(root.shown.run)
    repeat: true
    onTriggered: root.refreshDetail(true)
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      id: detailOut
      waitForEnd: true
    }
    onExited: function(code) {
      root.loading = false
      var item = root.pendingItem
      if (code !== 0 || !item) return
      var detail
      try {
        detail = JSON.parse(String(detailOut.text || ""))
      } catch (e) {
        console.warn("omarci: bad run detail", e)
        return
      }
      var key = root.runKey(item)
      if (root.isFinished(detail)) {
        var next = Object.assign({}, root.detailCache)
        next[key] = detail
        root.detailCache = next
      }
      // A reply for a run no longer selected only fills the cache.
      if (root.runKey(root.selected) !== key) return
      root.show(item, detail, true)
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
      ? panel.fittedContentHeight(Style.space(300), Style.space(440))
      : panel.cappedContentHeight(Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: repoField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.settingsOpen && dy !== 0) root.moveCursor(dy)
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

        // ---- Header: title left, actions right ------------------------------

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
              tooltipText: "Open the run on github.com (Enter)"
              bordered: true; fontFamily: root.fontFamily; foreground: root.foreground; fontSize: Style.font.caption
              onClicked: root.openSelected()
            }
            Button {
              visible: !root.settingsOpen && root.canRetry
              text: "Retry"
              tooltipText: root.selectedFailed ? "Re-run the failed jobs (r)" : "Re-run the whole run (r)"
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

        // ---- Settings ----------------------------------------------------------

        Column {
          visible: root.settingsOpen
          Layout.fillWidth: true
          spacing: Style.space(12)

          Toggle {
            width: parent.width
            label: "Notifications"
            description: "Desktop toast when a run you started finishes"
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

        // ---- Body: runs left, the shown run right -----------------------------

        RowLayout {
          visible: !root.settingsOpen
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(10)

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
                visible: root.ci !== null && root.ci.repos.length === 0
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
                model: root.repoCards
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
                        width: cardColumn.width
                        implicitHeight: runText.implicitHeight + Style.space(8)

                        Rectangle {
                          anchors.fill: parent
                          radius: Style.cornerRadius
                          color: root.selectedIndex === runRow.flatIndex ? Color.menu.selectedBackground : "transparent"
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
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.cornerRadius
            color: root.cardFill
            border.width: 1
            border.color: root.cardBorder

            Text {
              visible: root.shown === null
              anchors.centerIn: parent
              text: root.loading ? "Loading…" : "Select a run"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // A quiet marker while a newer selection's details are on their way.
            Text {
              visible: root.loading && root.shown !== null
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(8)
              z: 1
              text: root.ci ? root.ci.spinnerGlyph + " loading" : "loading"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Flickable {
              id: detailFlick
              visible: root.shown !== null
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

                Column {
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: root.shown
                      ? root.glyphFor(root.shown.run.status, root.shown.run.conclusion) + "  "
                        + (root.shown.run.workflow || "") + " · " + (root.shown.run.branch || "")
                      : ""
                    color: root.shown ? root.runColor(root.shown.run) : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.shown ? (root.shown.run.title || "") : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: root.shown && root.ci
                      ? root.shown.repo + " · " + (root.shown.run.sha || "") + " · "
                        + (root.shown.run.actor || "") + " · " + root.ci.runLabel(root.shown.run)
                        + " · " + root.ci.runTiming(root.shown.run)
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                PanelSeparator { width: parent.width; foreground: root.foreground }

                Repeater {
                  model: root.shownDetail ? root.shownDetail.jobs : []
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

                Text {
                  visible: root.shown !== null && root.ci !== null && root.ci.runIsActive(root.shown.run)
                  width: parent.width
                  text: "The log appears here when the run finishes; Open shows it live on github.com."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                PanelSectionHeader {
                  visible: root.shownLogHtml !== ""
                  text: root.shownDetail && root.shownDetail.logKind === "failed" ? "FAILED JOBS' LOG" : "LOG"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  visible: root.shownLogHtml !== ""
                  width: detailColumn.width
                  text: root.shownLogHtml
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
