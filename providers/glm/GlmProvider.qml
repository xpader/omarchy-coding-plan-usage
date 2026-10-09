import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../.."
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
// (mode 600). Requests go out via the shared HttpFetcher (XMLHttpRequest),
// so the secret never appears in a process argv.

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

  // In-flight request (null when idle) and boot-grace flag.
  property bool booted: false
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
  readonly property string quotaUrl: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"

  property string apiKey: ""
  property string apiKeyToWrite: ""

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
    var n = parseInt(String(setting("startupFetchDelaySec", 2)), 10)
    if (!isFinite(n)) n = 15
    return Math.max(0, Math.min(300, n))
  }


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
      state = "no-key"
      return
    }
    state = "loading"
    // During the boot grace the startup timer fetches; afterwards a fresh
    // key is fetched right away.
    if (booted) refresh()
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
    if (fetcher.busy) return
    refreshing = true
    if (state !== "ok") state = "loading"
    fetcher.get()
  }

  function handleResponse(status, text) {
    refreshing = false
    var parsed = null
    var raw = String(text || "").trim()
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

    var message = parsed && parsed.error ? parsed.error : fetcher.statusMessage(status)
    if (windows.length > 0) {
      // Keep stale numbers on a wire failure; the panel shows the note.
      statusText = message + " — showing last known usage"
      return
    }
    state = "error"
    statusText = message
  }


  HttpFetcher {
    id: fetcher
    url: root.quotaUrl
    authHeader: root.apiKey
    onResponded: (status, text) => root.handleResponse(status, text)
    onTimedOut: {
      root.refreshing = false
      if (root.windows.length > 0)
        root.statusText = "Request timed out — showing last known usage"
      else {
        root.state = "error"
        root.statusText = "Request timed out"
      }
    }
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
    id: clearProcess
    running: false
    command: ["bash", "-c", "rm -f \"$0\"", root.keyPath]
    onExited: root.applyKey("")
  }

  // ------------------------------------------------------------- timers

  // Boot grace: no network during plugin startup. Once it lapses, fetch at
  // once (if a key is loaded) and let the poll timer take over.
  Timer {
    interval: root.startupFetchDelaySec * 1000
    running: true
    repeat: false
    onTriggered: {
      root.booted = true
      if (root.hasApiKey) root.refresh()
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    running: root.booted && root.hasApiKey
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
