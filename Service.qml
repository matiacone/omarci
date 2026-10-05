import QtQuick
import Quickshell
import Quickshell.Io

// GitHub Actions watcher. The CLI owns writes; this service runs `omarci gh
// sync` on a timer and watches settings.json (the watched repos) and
// github.json (their latest runs) so the bar and panel stay live.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
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
  readonly property int maxSettingsBytes: 4096
  readonly property int maxGithubBytes: 1048576

  property double nowSec: Date.now() / 1000
  property int spinnerFrame: 0
  readonly property var spinnerGlyphs: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  readonly property string spinnerGlyph: spinnerGlyphs[spinnerFrame % spinnerGlyphs.length]

  readonly property int activeCount: {
    var n = 0
    var list = github && github.repos ? github.repos : []
    for (var i = 0; i < list.length; i++) {
      var runs = list[i].runs || []
      for (var j = 0; j < runs.length; j++)
        if (runIsActive(runs[j])) n++
    }
    return n
  }

  // Your newest finished run across the watched repos: the bar's verdict.
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

  readonly property string barState: {
    if (activeCount > 0) return "running"
    var latest = myLatestRun
    if (!latest) return "idle"
    var c = latest.run.conclusion
    if (c === "success") return "pass"
    if (c === "failure" || c === "timed_out" || c === "startup_failure") return "fail"
    return "idle"
  }

  readonly property string tooltip: {
    if (activeCount > 0) return "Omarci — " + activeCount + " run" + (activeCount === 1 ? "" : "s") + " in progress"
    if (myLatestRun) return "Omarci — " + myLatestRun.run.workflow + " " + runLabel(myLatestRun.run) + " · " + myLatestRun.repo
    return repos.length ? "Omarci" : "Omarci — add a repo to watch"
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
    return st.replace(/_/g, " ")
  }

  function pad2(n) {
    n = String(n)
    return n.length < 2 ? "0" + n : n
  }

  function shortDuration(s) {
    s = Math.max(0, Math.floor(s))
    if (s >= 86400) return Math.floor(s / 86400) + "d"
    if (s >= 3600) return Math.floor(s / 3600) + "h"
    if (s >= 60) return Math.floor(s / 60) + "m"
    return s + "s"
  }

  function formatSeconds(s) {
    s = Math.max(0, Math.floor(s))
    if (s >= 3600) return Math.floor(s / 3600) + "h" + pad2(Math.floor((s % 3600) / 60)) + "m"
    if (s >= 60) return Math.floor(s / 60) + "m" + pad2(s % 60) + "s"
    return s + "s"
  }

  // Finished runs: how long they took and how long ago. Running: for how long.
  function runTiming(run) {
    if (!run) return ""
    if (runIsActive(run)) return shortDuration(root.nowSec - (run.startedAt || run.createdAt))
    var took = (run.updatedAt || 0) - (run.startedAt || run.createdAt || 0)
    return formatSeconds(took) + " · " + shortDuration(root.nowSec - (run.updatedAt || 0)) + " ago"
  }

  function boundedText(collector, exitCode, cap) {
    if (exitCode !== 0) return ""
    var text = collector.text
    if (text.length >= cap) return ""
    return text
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

  Process {
    id: seedDir
    command: [
      "bash", "-c",
      "mkdir -p -- \"$1\" && if [ ! -f \"$1/settings.json\" ]; then printf '%s\\n' '{\"notify\":true}' > \"$1/settings.json\"; fi",
      "omarci-seed",
      stateHome + "/omarci"
    ]
    running: true
    onExited: {
      root.readSettingsBounded()
      root.readGithubBounded()
    }
  }

  Timer {
    interval: 1000
    running: root.activeCount > 0
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
    interval: root.activeCount > 0 ? 15000 : 60000
    running: root.repos.length > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: root.syncGithub()
  }

  onReposChanged: Qt.callLater(root.syncGithub)

  Timer {
    interval: 80
    running: root.activeCount > 0
    repeat: true
    onTriggered: root.spinnerFrame = (root.spinnerFrame + 1) % root.spinnerGlyphs.length
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

  // Watch only. preload off and text() is never called, so a huge or
  // symlinked file cannot be mapped into the shell.
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
