import QtQuick
import Quickshell
import Quickshell.Io

// Headless job bus. The CLI owns writes; this service watches index.json
// so the bar and panel stay live without polling.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string indexPath: stateHome + "/omarci/index.json"
  readonly property string settingsPath: stateHome + "/omarci/settings.json"
  readonly property string cliPath: (manifest && manifest.__sourceDir)
    ? (manifest.__sourceDir + "/bin/omarci")
    : "omarci"

  property bool notify: true

  property var jobs: []
  property double nowSec: Date.now() / 1000
  property int spinnerFrame: 0
  readonly property var spinnerGlyphs: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  readonly property string spinnerGlyph: spinnerGlyphs[spinnerFrame % spinnerGlyphs.length]

  readonly property int runningCount: countStatus("running")
  readonly property int failedCount: countUndismissed("fail")
  readonly property int passedCount: countUndismissed("pass")

  readonly property var latestJob: {
    var list = visibleJobs()
    return list.length > 0 ? list[0] : null
  }

  readonly property string barState: {
    var job = latestJob
    if (!job) return "idle"
    if (job.status === "running") return "running"
    if (job.status === "fail") return "fail"
    if (job.status === "pass") return "pass"
    return "idle"
  }

  readonly property string tooltip: {
    var job = latestJob
    if (!job) return "Omarci — no jobs"
    if (job.status === "running") return "Omarci — " + (job.name || "job") + " running"
    if (job.status === "fail") return "Omarci — " + (job.name || "job") + " failed"
    if (job.status === "pass") return "Omarci — " + (job.name || "job") + " passed"
    return "Omarci"
  }

  function countStatus(status) {
    var n = 0
    for (var i = 0; i < jobs.length; i++)
      if (jobs[i] && jobs[i].status === status) n++
    return n
  }

  function countUndismissed(status) {
    var n = 0
    for (var i = 0; i < jobs.length; i++) {
      var j = jobs[i]
      if (j && j.status === status && j.dismissed !== true) n++
    }
    return n
  }

  function visibleJobs() {
    var out = []
    for (var i = 0; i < jobs.length; i++) {
      var j = jobs[i]
      if (!j) continue
      if (j.status === "running" || j.dismissed !== true) out.push(j)
    }
    return out
  }

  function jobById(id) {
    for (var i = 0; i < jobs.length; i++)
      if (jobs[i] && jobs[i].id === id) return jobs[i]
    return null
  }

  function elapsed(job) {
    if (!job || !job.startedAt) return 0
    var end = job.finishedAt ? job.finishedAt : root.nowSec
    var s = Math.max(0, Math.floor(end - job.startedAt))
    return s
  }

  function pad2(n) {
    n = String(n)
    return n.length < 2 ? "0" + n : n
  }

  function formatElapsed(job) {
    var s = elapsed(job)
    if (s >= 3600) return Math.floor(s / 3600) + "h" + pad2(Math.floor((s % 3600) / 60)) + "m"
    if (s >= 60) return Math.floor(s / 60) + "m" + pad2(s % 60) + "s"
    return s + "s"
  }

  function jobTime(job) {
    if (!job) return 0
    var sec = Number(job.startedAt)
    return isFinite(sec) && sec > 0 ? sec : 0
  }

  function formatClock(job) {
    var sec = jobTime(job)
    if (!sec) return ""
    var d = new Date(sec * 1000)
    return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }

  function formatDateTime(job) {
    var sec = jobTime(job)
    if (!sec) return ""
    var d = new Date(sec * 1000)
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return d.getDate() + " " + months[d.getMonth()] + " " + pad2(d.getHours()) + ":" + pad2(d.getMinutes())
  }

  function parse(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (!parsed || typeof parsed !== "object") return
      root.jobs = Array.isArray(parsed.jobs) ? parsed.jobs : []
    } catch (e) {
      console.warn("omarci: ignoring bad index", e)
    }
  }

  function reload() {
    indexFile.reload()
  }

  function parseSettings(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (parsed && typeof parsed === "object" && typeof parsed.notify === "boolean")
        root.notify = parsed.notify
    } catch (e) {
      console.warn("omarci: ignoring bad settings", e)
    }
  }

  function setNotify(value) {
    root.notify = !!value
    settingsFile.setText(JSON.stringify({ notify: root.notify }, null, 2) + "\n")
  }

  Process {
    id: seedDir
    command: [
      "bash", "-c",
      "mkdir -p -- \"$1/logs\" && if [ ! -f \"$1/index.json\" ]; then printf '%s\\n' '{\"version\":1,\"jobs\":[]}' > \"$1/index.json\"; fi && if [ ! -f \"$1/settings.json\" ]; then printf '%s\\n' '{\"notify\":true}' > \"$1/settings.json\"; fi",
      "omarci-seed",
      stateHome + "/omarci"
    ]
    running: true
    onExited: {
      indexFile.reload()
      settingsFile.reload()
    }
  }

  function dismiss(id) {
    if (!id) return
    dismissProc.command = [root.cliPath, "dismiss", String(id)]
    dismissProc.running = true
  }

  function clearFinished() {
    clearProc.command = [root.cliPath, "clear"]
    clearProc.running = true
  }

  function openLog(id) {
    var job = jobById(id)
    if (!job || !job.log) return
    openLogProc.command = ["omarchy-launch-tui", "less", "-R", "--", String(job.log)]
    openLogProc.running = true
  }

  Timer {
    interval: 1000
    running: root.runningCount > 0
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Timer {
    interval: 80
    running: root.runningCount > 0
    repeat: true
    onTriggered: root.spinnerFrame = (root.spinnerFrame + 1) % root.spinnerGlyphs.length
  }

  FileView {
    id: indexFile
    path: root.indexPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.parse(text())
    onLoadFailed: root.jobs = []
    onFileChanged: reload()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.parseSettings(text())
    onLoadFailed: root.notify = true
    onFileChanged: settingsFile.reload()
  }

  Process {
    id: dismissProc
    onExited: root.reload()
  }

  Process {
    id: clearProc
    onExited: root.reload()
  }

  Process {
    id: openLogProc
  }
}
