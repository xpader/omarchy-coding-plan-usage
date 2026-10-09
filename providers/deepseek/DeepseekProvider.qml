import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "../../Util.js" as Util
import "Model.js" as Model

// DeepSeek pay-as-you-go balance provider (api.deepseek.com).
//
// Implements the provider contract documented in
// providers/glm/GlmProvider.qml, with the balance-flavoured extensions:
//   barLabel   bar-pill text replacing the percent ("¥110.00"), "" = percent
//   windows[]  entries may carry kind: "balance" with valueText (a
//              pre-formatted amount) instead of a percent meter.
//   usageHeader  section title ("BALANCE" here vs "LIMITS" for quotas)
//
// Money flows through this provider as integer 分 (cents) — parsed,
// ledgered and formatted without a single float (see Model.js toCents).

Item {
  id: root

  property var settings: ({})

  readonly property string providerId: "deepseek"
  readonly property string providerName: "DeepSeek"
  readonly property string iconGlyph: "\uF1095" // nf-md-cash
  readonly property url brandIcon: Qt.resolvedUrl("../../icons/deepseek.svg")
  readonly property string keyLabel: "DeepSeek API key"
  readonly property string usageHeader: "BALANCE"

  property string state: "loading"
  property string statusText: ""
  property string planLabel: ""
  property var windows: []
  property double updatedAtMs: 0
  property bool refreshing: false
  readonly property bool hasApiKey: apiKey !== ""
  readonly property real headlinePercent: -1
  readonly property string barLabel: balance >= 0 ? Util.formatMoney(balance) : ""

  // Bar-pill segments: today's spend once anything was consumed today.
  readonly property var barSegments: {
    var segs = []
    if (state === "ok" && spentToday > 0) {
      segs.push({
        icon: iconGlyph,
        brandIcon: brandIcon,
        text: Util.formatMoney(spentToday),
        tooltip: providerName + " — Today " + Util.formatMoney(spentToday)
          + " · Balance " + Util.formatMoney(balance),
        urgent: false
      })
    }
    return segs
  }

  // Integer 分; -1 = not fetched yet.
  property int balance: -1
  property bool serviceAvailable: true

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/coding-plan-usage"
  readonly property string keyPath: stateDir + "/keys/" + providerId
  readonly property string headerPath: keyPath + ".headers"
  readonly property string balanceUrl: "https://api.deepseek.com/user/balance"

  property string apiKey: ""
  property bool headersReady: false
  property string apiKeyToWrite: ""
  property string _stdoutText: ""
  property string _stderrText: ""

  // Daily-spend ledger persisted at <stateDir>/deepseek-daily.json.
  property var dailyState: null
  property int spentToday: 0
  // Fetching before the ledger loads would rebase the baseline and zero
  // today's spend, so the refresh timer stays off until it is readable.
  property bool ledgerReady: false

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

  property FileView keyWriter: FileView {
    path: root.keyPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Historical ledger: last-seen balance per day so consumption between
  // refreshes can be attributed to "today". Read and written through the
  // same FileView (mirrors keyFile's proven watchChanges pattern).
  property FileView dailyFile: FileView {
    path: root.stateDir + "/deepseek-daily.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        root.dailyState = JSON.parse(String(text() || ""))
      } catch (e) {
        root.dailyState = null
      }
      root.ledgerReady = true
    }
    onLoadFailed: {
      root.dailyState = null
      root.ledgerReady = true // no ledger yet — start fresh, but start
    }
  }

  function recordDaily(totalCents) {
    if (!ledgerReady) return // ledger not loaded — keep old baseline
    var result = Model.applyDailyState(dailyState, totalCents, Model.todayString())
    dailyState = result.state
    spentToday = result.spentToday
    dailyFile.setText(JSON.stringify(result.state, null, 2) + "\n")
  }

  function applyKey(key) {
    var value = String(key || "").trim()
    apiKey = value
    windows = []
    planLabel = ""
    statusText = ""
    updatedAtMs = 0
    balance = -1
    spentToday = 0
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
        parsed = Model.parseBalance(JSON.parse(raw))
      } catch (e) {
        parsed = null
      }
    }
    if (parsed && parsed.ok) {
      balance = parsed.total
      serviceAvailable = parsed.available
      recordDaily(parsed.total)
      planLabel = "Pay-as-you-go"
      statusText = parsed.available ? "" : "API service currently unavailable on this account"
      windows = root.buildWindows(parsed.total, parsed.granted, parsed.topped)
      updatedAtMs = Date.now()
      state = "ok"
      return
    }

    var message = parsed && parsed.error ? parsed.error : fetchErrorMessage(stderr, exitCode)
    if (windows.length > 0) {
      statusText = message + " — showing last known balance"
      return
    }
    state = "error"
    statusText = message
  }

  function fetchErrorMessage(stderr, exitCode) {
    var text = String(stderr || "")
    if (exitCode === 22 && /401/.test(text)) return "Invalid API key"
    if (exitCode === 22 && /402/.test(text)) return "Payment required"
    if (exitCode === 22 && /429/.test(text)) return "Rate limited"
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

  function buildWindows(total, granted, topped) {
    var breakdown = []
    if (granted > 0) breakdown.push({ name: "granted", value: granted })
    return [{
      id: "balance",
      kind: "balance",
      title: "Balance",
      percent: -1,
      resetAtMs: 0,
      used: total,
      limit: -1,
      unit: "CNY",
      valueText: Util.formatMoney(total),
      available: serviceAvailable,
      details: breakdown
    }, {
      id: "spent-today",
      kind: "balance",
      title: "Spent Today",
      percent: -1,
      resetAtMs: 0,
      used: spentToday,
      limit: -1,
      unit: "CNY",
      valueText: Util.formatMoney(spentToday),
      available: true,
      details: []
    }]
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
    command: ["bash", "-c",
      "umask 077; f=$0; [[ -s $f ]] || exit 1; mkdir -p \"$(dirname \"$f\")\"; printf 'Authorization: Bearer %s\\n' \"$(cat \"$f\")\" > \"$f.headers\"",
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
      root.balanceUrl]
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

  // Startup sequence: wait until the ledger and key are fully loaded, then
  // give the shell a grace period before the first network fetch. Trading a
  // little freshness for a faster, steadier boot — and guaranteeing the
  // ledger is never written before it has been read.
  Timer {
    id: startupDelay
    interval: root.startupFetchDelaySec * 1000
    running: root.ledgerReady && root.headersReady && !root.cycleStarted
    repeat: false
    onTriggered: {
      root.cycleStarted = true
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.cycleStarted
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 15000
    running: root.state === "no-key"
    repeat: true
    onTriggered: root.keyFile.reload()
  }

  // Midnight crossed without a fetch: "today" is a new day, so the spend
  // display zeroes out; the ledger rebases on the next successful fetch.
  Timer {
    interval: 60000
    running: root.state === "ok"
    repeat: true
    onTriggered: {
      var day = Model.todayString()
      if (root.dailyState && day !== root.dailyState.baselineDate) root.spentToday = 0
    }
  }
}
