import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../../Util.js" as Util
import "Model.js" as Model

// GLM Coding Plan provider (Zhipu BigModel open platform).
//
// Provider contract — every providers/<id>/<Id>Provider.qml must expose:
//   providerId / providerName / iconGlyph / keyLabel   display identity
//   state      "no-key" | "loading" | "ok" | "error"
//   statusText human-readable error or transient note ("" when clean)
//   planLabel  plan/tier name from the platform ("" when unknown)
//   windows    [{ id, title, percent(0-100|-1), resetAtMs, used, limit,
//                 details: [{ name, value }] }]
//   headlinePercent  the binding (fullest) window percent, -1 unknown
//   updatedAtMs / refreshing
//   refresh() / setKey(key) / clearKey() / hasApiKey
//
// The API key lives at <stateHome>/omarchy/coding-plan-usage/keys/<id>
// (mode 600). A twin `.headers` file carrying "Authorization: <key>" is
// rebuilt from it via bash so the secret never shows up in a process argv
// (`curl -H @file`).

Item {
  id: root

  property var settings: ({})

  readonly property string providerId: "glm"
  readonly property string providerName: "GLM Coding Plan"
  readonly property string iconGlyph: "\uF0374" // nf-md-gauge
  readonly property url brandIcon: Qt.resolvedUrl("../../icons/glm-brand.svg")
  readonly property string keyLabel: "GLM API key"
  readonly property string usageHeader: "LIMITS"

  property string state: "loading"
  property string statusText: ""
  property string planLabel: ""
  property var windows: []
  property double updatedAtMs: 0
  property bool refreshing: false
  readonly property bool hasApiKey: apiKey !== ""
  readonly property real headlinePercent: {
    var w = Util.bindingWindow(windows)
    return w ? Number(w.percent) : -1
  }

  // Bar-pill segments: the 5-hour window percent once it has any usage.
  readonly property var barSegments: {
    var segs = []
    if (state !== "ok") return segs
    var w = Util.windowById(windows, "five-hour")
    if (w && Number(w.percent) > 0) {
      segs.push({
        icon: iconGlyph,
        brandIcon: brandIcon,
        text: Util.formatPercent(w.percent),
        tooltip: providerName + " — " + w.title + " " + Util.formatPercent(w.percent),
        urgent: Util.severity(w.percent) === "urgent"
      })
    }
    return segs
  }

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/coding-plan-usage"
  readonly property string keyPath: stateDir + "/keys/" + providerId
  readonly property string headerPath: keyPath + ".headers"
  readonly property string quotaUrl: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

  property string apiKey: ""
  property bool headersReady: false
  property string apiKeyToWrite: ""
  property string _stdoutText: ""
  property string _stderrText: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 600)), 10)
    if (!isFinite(n)) n = 600
    return Math.max(60, Math.min(86400, n))
  }

  // How long to idle after startup before the first fetch (stability over
  // freshness; the panel fetches on open anyway).
  readonly property int startupFetchDelaySec: {
    var n = parseInt(String(setting("startupFetchDelaySec", 15)), 10)
    if (!isFinite(n)) n = 15
    return Math.max(0, Math.min(300, n))
  }

  property bool cycleStarted: false

  // ------------------------------------------------------------------ key

  property FileView keyFile: FileView {
    path: root.keyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var key = String(text() || "").trim()
      if (key === root.apiKey && root.state !== "loading" && root.state !== "no-key") return
      root.applyKey(key)
    }
    onLoadFailed: {
      if (root.apiKey === "" && root.state === "no-key") return
      root.applyKey("")
    }
  }

  // Dedicated writer (watchChanges off) so a save never races the watcher.
  property FileView keyWriter: FileView {
    path: root.keyPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  function applyKey(key) {
    var value = String(key || "").trim()
    apiKey = value
    windows = []
    planLabel = ""
    statusText = ""
    updatedAtMs = 0
    if (value === "") {
      headersReady = false
      state = "no-key"
      return
    }
    state = "loading"
    syncHeaders()
  }

  function setKey(key) {
    var value = String(key || "").trim()
    if (value === "") return
    apiKeyToWrite = value
    if (!mkdirProcess.running) mkdirProcess.running = true
  }

  function performSetKey() {
    keyWriter.setText(apiKeyToWrite + "\n")
    keyFile.reload()
  }

  function clearKey() {
    if (!clearProcess.running) clearProcess.running = true
  }

  // ------------------------------------------------------------- fetching

  function refresh() {
    if (apiKey === "") {
      // Picks up a key dropped onto disk by hand, including the very first
      // one (the watcher can't watch a file that does not exist yet).
      keyFile.reload()
      return
    }
    if (!headersReady) {
      syncHeaders()
      return
    }
    if (fetchProcess.running) return
    _stdoutText = ""
    _stderrText = ""
    refreshing = true
    if (state !== "ok") state = "loading"
    fetchProcess.running = true
  }

  function handleFetch(stdout, stderr, exitCode) {
    refreshing = false
    var parsed = null
    var raw = String(stdout || "").trim()
    if (raw !== "") {
      try {
        parsed = Model.parseQuota(JSON.parse(raw))
      } catch (e) {
        parsed = null
      }
    }
    if (parsed && parsed.ok) {
      windows = parsed.windows
      planLabel = parsed.level
      statusText = ""
      updatedAtMs = Date.now()
      state = "ok"
      return
    }

    var message = parsed && parsed.error ? parsed.error : fetchErrorMessage(stderr, exitCode)
    if (windows.length > 0) {
      // Keep stale numbers on a wire failure; the panel shows the note.
      statusText = message + " — showing last known usage"
      return
    }
    state = "error"
    statusText = message
  }

  function fetchErrorMessage(stderr, exitCode) {
    var text = String(stderr || "")
    var http = text.match(/error:\s*(\d{3})/)
    if (http) return "HTTP " + http[1]
    if (exitCode === 6) return "Could not resolve host"
    if (exitCode === 28) return "Request timed out"
    if (exitCode === 7) return "Could not connect"
    return "Request failed"
  }

  function syncHeaders() {
    if (!syncProcess.running) syncProcess.running = true
  }

  Process {
    id: mkdirProcess
    running: false
    command: ["bash", "-c", "umask 077 && mkdir -p \"$0\"", root.stateDir + "/keys"]
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.state = "error"
        root.statusText = "Could not create " + root.stateDir + "/keys"
        return
      }
      root.performSetKey()
    }
  }

  Process {
    id: syncProcess
    running: false
    // Rebuild the curl header twin from the key file. The key travels file
    // to file inside one bash process, never through argv.
    command: ["bash", "-c",
      "umask 077; f=$0; [[ -s $f ]] || exit 1; mkdir -p \"$(dirname \"$f\")\"; printf 'Authorization: %s\\n' \"$(cat \"$f\")\" > \"$f.headers\"",
      root.keyPath]
    onExited: function(exitCode) {
      root.headersReady = exitCode === 0
      if (root.headersReady) root.refresh()
      else if (root.state === "loading") {
        root.state = "error"
        root.statusText = "Could not prepare credentials"
      }
    }
  }

  Process {
    id: clearProcess
    running: false
    command: ["bash", "-c", "rm -f \"$0\" \"$0.headers\"", root.keyPath]
    onExited: root.applyKey("")
  }

  Process {
    id: fetchProcess
    running: false
    command: ["curl", "-fsS", "--max-time", "15",
      "-H", "@" + root.headerPath,
      "-H", "Accept: application/json",
      root.quotaUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stdoutText = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stderrText = text
    }
    onExited: function(exitCode) {
      root.handleFetch(_stdoutText, _stderrText, exitCode)
    }
  }

  // ------------------------------------------------------------- timers

  // Same startup deal as the DeepSeek provider: fetch only after the key is
  // loaded plus a grace period — no network during plugin startup itself.
  Timer {
    id: startupDelay
    interval: root.startupFetchDelaySec * 1000
    running: root.headersReady && !root.cycleStarted
    repeat: false
    onTriggered: {
      root.cycleStarted = true
      root.refresh()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    running: root.cycleStarted
    repeat: true
    onTriggered: root.refresh()
  }

  // A freshly created key file can't trip the watcher, so poll for it while
  // unlocked; reloading an unchanged file is a cheap no-op.
  Timer {
    interval: 15000
    running: root.state === "no-key"
    repeat: true
    onTriggered: root.keyFile.reload()
  }

  // Refetch as soon as a window rolls over, like the reference extension.
  Timer {
    interval: 60000
    running: root.state === "ok"
    repeat: true
    onTriggered: {
      var now = Date.now()
      for (var i = 0; i < root.windows.length; i++) {
        var resetAt = Number(root.windows[i].resetAtMs)
        if (resetAt > 0 && now >= resetAt) {
          root.refresh()
          return
        }
      }
    }
  }
}
