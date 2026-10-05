import QtQuick
import Quickshell
import Quickshell.Io

// Headless job bus and GitHub Actions watcher. The CLI owns writes; this
// service watches index.json (local jobs) and github.json (the watched repos'
// runs, refreshed by `omarci gh sync` on a timer) so the bar and panel stay
// live.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string indexPath: stateHome + "/omarci/index.json"
  readonly property string settingsPath: stateHome + "/omarci/settings.json"
  readonly property string githubPath: stateHome + "/omarci/github.json"
  readonly property string cliPath: (manifest && manifest.__sourceDir)
    ? (manifest.__sourceDir + "/bin/omarci")
    : "omarci"

  property bool notify: true
  property var repos: []
  property var github: ({ me: "", fetchedAt: 0, repos: [] })
  property string repoError: ""
  property bool addingRepo: false

  // Bounded reads: FileView never maps these files. `head -c` is the cap
  // before stdout reaches StdioCollector / JSON.parse.
  readonly property int maxIndexBytes: 65536
  readonly property int maxSettingsBytes: 4096
  readonly property int maxGithubBytes: 1048576
  readonly property int maxLogBytes: 65536
  readonly property string logsDir: stateHome + "/omarci/logs/"

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

  readonly property string localState: {
    var job = latestJob
    if (!job) return "idle"
    if (job.status === "running") return "running"
    if (job.status === "fail") return "fail"
    if (job.status === "pass") return "pass"
    return "idle"
  }

  readonly property int ghActiveCount: {
    var n = 0
    var list = github && github.repos ? github.repos : []
    for (var i = 0; i < list.length; i++) {
      var runs = list[i].runs || []
      for (var j = 0; j < runs.length; j++)
        if (runIsActive(runs[j])) n++
    }
    return n
  }

  // Your newest finished run across the watched repos: the bar's GitHub verdict.
  readonly property var myLatestRun: {
    var best = null
    var me = github ? github.me : ""
    var list = github && github.repos ? github.repos : []
    for (var i = 0; i < list.length; i++) {
      var runs = list[i].runs || []
      for (var j = 0; j < runs.length; j++) {
        var r = runs[j]
        if (!r || r.actor !== me || r.status !== "completed") continue
        if (!best || r.updatedAt > best.run.updatedAt) best = { repo: list[i].repo, run: r }
      }
    }
    return best
  }

  readonly property string ghState: {
    if (ghActiveCount > 0) return "running"
    var latest = myLatestRun
    if (!latest) return "idle"
    var c = latest.run.conclusion
    if (c === "success") return "pass"
    if (c === "failure" || c === "timed_out" || c === "startup_failure") return "fail"
    return "idle"
  }

  readonly property string barState: {
    if (localState === "running" || ghState === "running") return "running"
    if (localState === "fail" || ghState === "fail") return "fail"
    if (localState === "pass" || ghState === "pass") return "pass"
    return "idle"
  }

  readonly property string tooltip: {
    var parts = []
    if (ghActiveCount > 0) parts.push(ghActiveCount + " GitHub run" + (ghActiveCount === 1 ? "" : "s") + " in progress")
    else if (myLatestRun) parts.push(myLatestRun.run.workflow + " " + runLabel(myLatestRun.run) + " · " + myLatestRun.repo)
    var job = latestJob
    if (job) parts.push((job.name || "job") + " " + (job.status === "running" ? "running" : job.status === "fail" ? "failed" : "passed"))
    return parts.length ? "Omarci — " + parts.join(" · ") : "Omarci — nothing yet"
  }

  function runIsActive(run) {
    return !!run && run.status !== "completed"
  }

  // "running", "queued", or the conclusion ("success", "failure", ...).
  function runState(run) {
    if (!run) return ""
    if (run.status === "in_progress") return "running"
    if (run.status !== "completed") return "queued"
    return run.conclusion || "completed"
  }

  function runLabel(run) {
    var st = runState(run)
    if (st === "success") return "passed"
    if (st === "failure") return "failed"
    if (st === "cancelled") return "cancelled"
    return st.replace(/_/g, " ")
  }

  function shortDuration(s) {
    s = Math.max(0, Math.floor(s))
    if (s >= 86400) return Math.floor(s / 86400) + "d"
    if (s >= 3600) return Math.floor(s / 3600) + "h"
    if (s >= 60) return Math.floor(s / 60) + "m"
    return s + "s"
  }

  // Finished runs: how long they took and how long ago. Running: for how long.
  function runTiming(run) {
    if (!run) return ""
    if (runIsActive(run)) return shortDuration(root.nowSec - (run.startedAt || run.createdAt))
    var took = (run.updatedAt || 0) - (run.startedAt || run.createdAt || 0)
    return formatSeconds(took) + " · " + shortDuration(root.nowSec - (run.updatedAt || 0)) + " ago"
  }

  function formatSeconds(s) {
    s = Math.max(0, Math.floor(s))
    if (s >= 3600) return Math.floor(s / 3600) + "h" + pad2(Math.floor((s % 3600) / 60)) + "m"
    if (s >= 60) return Math.floor(s / 60) + "m" + pad2(s % 60) + "s"
    return s + "s"
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

  function boundedText(collector, exitCode, cap) {
    if (exitCode !== 0) return ""
    var text = collector.text
    if (text.length >= cap) return ""
    return text
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
    root.readIndexBounded()
  }

  function readIndexBounded() {
    if (indexReader.running) indexReader.running = false
    indexReader.running = true
  }

  function readSettingsBounded() {
    if (settingsReader.running) settingsReader.running = false
    settingsReader.running = true
  }

  function parseSettings(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (!parsed || typeof parsed !== "object") return
      if (typeof parsed.notify === "boolean") root.notify = parsed.notify
      root.repos = Array.isArray(parsed.repos) ? parsed.repos.filter(function(r) { return typeof r === "string" }) : []
    } catch (e) {
      console.warn("omarci: ignoring bad settings", e)
    }
  }

  function setNotify(value) {
    root.notify = !!value
    settingsFile.setText(JSON.stringify({ notify: root.notify, repos: root.repos }, null, 2) + "\n")
  }

  function safeLogPath(job) {
    if (!job) return ""
    var p = String(job.log || "")
    var prefix = root.logsDir
    if (p.indexOf(prefix) !== 0) return ""
    var rest = p.substring(prefix.length)
    if (rest.length === 0 || rest.indexOf("/") !== -1 || rest.indexOf("..") !== -1)
      return ""
    return p
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
      root.readIndexBounded()
      root.readSettingsBounded()
      root.readGithubBounded()
    }
  }

  function parseGithub(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.repos)) return
      root.github = parsed
    } catch (e) {
      console.warn("omarci: ignoring bad github.json", e)
    }
  }

  function readGithubBounded() {
    if (githubReader.running) githubReader.running = false
    githubReader.running = true
  }

  function syncGithub() {
    if (root.repos.length === 0 || syncProc.running) return
    syncProc.command = [root.cliPath, "gh", "sync"]
    syncProc.running = true
  }

  function addRepo(name) {
    var repo = String(name || "").trim().replace(/^https?:\/\/github\.com\//, "").replace(/\/+$/, "")
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) {
      root.repoError = "Use OWNER/REPO"
      return
    }
    root.repoError = ""
    root.addingRepo = true
    addRepoProc.command = [root.cliPath, "repos", "add", repo]
    addRepoProc.running = true
  }

  function removeRepo(repo) {
    removeRepoProc.command = [root.cliPath, "repos", "remove", String(repo)]
    removeRepoProc.running = true
  }

  function runAction(action, repo, id, extra) {
    if (!repo || !id || actionProc.running) return
    var cmd = [root.cliPath, "gh", action, String(repo), String(id)]
    if (extra) cmd.push(extra)
    actionProc.command = cmd
    actionProc.running = true
  }

  function openRun(repo, id) { runAction("open", repo, id) }
  function rerunFailed(repo, id) { runAction("rerun", repo, id, "--failed") }
  function rerunAll(repo, id) { runAction("rerun", repo, id) }
  function cancelRun(repo, id) { runAction("cancel", repo, id) }

  function openFailedLog(repo, id) {
    if (!repo || !id) return
    openLogProc.command = [
      "omarchy-launch-tui", "bash", "-c",
      "\"$0\" gh log \"$1\" \"$2\" 2>&1 | less -R",
      root.cliPath, String(repo), String(id)
    ]
    openLogProc.running = true
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
    running: root.runningCount > 0 || root.ghActiveCount > 0
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // Ages ("5m ago") drift while nothing runs; a slow tick keeps them honest.
  Timer {
    interval: 30000
    running: root.repos.length > 0
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // Faster while a watched run is in progress, so the bar flips soon after it ends.
  Timer {
    interval: root.ghActiveCount > 0 ? 15000 : 60000
    running: root.repos.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncGithub()
  }

  onReposChanged: Qt.callLater(root.syncGithub)

  Timer {
    interval: 80
    running: root.runningCount > 0 || root.ghActiveCount > 0
    repeat: true
    onTriggered: root.spinnerFrame = (root.spinnerFrame + 1) % root.spinnerGlyphs.length
  }

  // Watch only. preload off and text() is never called, so a huge or
  // symlinked index cannot be mapped into the shell.
  FileView {
    id: indexWatch
    path: root.indexPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readIndexBounded()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    preload: false
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.readSettingsBounded()
  }

  Process {
    id: indexReader
    command: ["head", "-c", String(root.maxIndexBytes), root.indexPath]
    stdout: StdioCollector {
      id: indexOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var text = root.boundedText(indexOut, exitCode, root.maxIndexBytes)
      if (text === "" && exitCode === 0 && indexOut.text.length >= root.maxIndexBytes) {
        console.warn("omarci: index.json exceeds", root.maxIndexBytes, "bytes")
        root.jobs = []
        return
      }
      if (text === "") {
        root.jobs = []
        return
      }
      root.parse(text)
    }
  }

  Process {
    id: settingsReader
    command: ["head", "-c", String(root.maxSettingsBytes), root.settingsPath]
    stdout: StdioCollector {
      id: settingsOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var text = root.boundedText(settingsOut, exitCode, root.maxSettingsBytes)
      if (text === "") {
        root.notify = true
        return
      }
      root.parseSettings(text)
    }
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

  FileView {
    id: githubWatch
    path: root.githubPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readGithubBounded()
  }

  Process {
    id: githubReader
    command: ["head", "-c", String(root.maxGithubBytes), root.githubPath]
    stdout: StdioCollector {
      id: githubOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var text = root.boundedText(githubOut, exitCode, root.maxGithubBytes)
      if (text !== "") root.parseGithub(text)
    }
  }

  Process {
    id: syncProc
    onExited: root.readGithubBounded()
  }

  Process {
    id: addRepoProc
    stderr: StdioCollector {
      id: addRepoErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.addingRepo = false
      if (exitCode !== 0)
        root.repoError = String(addRepoErr.text || "").replace(/^omarci: /, "").trim() || "Could not add that repo"
      root.readSettingsBounded()
    }
  }

  Process {
    id: removeRepoProc
    onExited: {
      root.readSettingsBounded()
      root.readGithubBounded()
    }
  }

  Process {
    id: actionProc
    onExited: root.readGithubBounded()
  }
}
