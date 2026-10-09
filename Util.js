// Shared helpers for coding-plan-usage. Pure functions only so the file can
// be exercised with node alongside the per-platform Model.js files.

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// 0-100 integer percent, -1 for unknown.
function normalizePercent(value) {
  var n = Number(value)
  if (!isFinite(n) || n < 0) return -1
  return Math.round(Math.min(100, n))
}

// "42%" or "--" for unknown percents.
function formatPercent(percent) {
  if (!(percent >= 0)) return "--"
  return Math.round(percent) + "%"
}

// Usage-ratio color banding shared by the bar and the meters:
// < 70 normal, >= 70 accent, >= 90 urgent.
function severity(percent) {
  if (!(percent >= 0)) return "none"
  if (percent >= 90) return "urgent"
  if (percent >= 70) return "accent"
  return "normal"
}

function pad2(n) {
  return String(n).padStart(2, "0")
}

// Reset time point: HH:mm for later today, otherwise MM/dd HH:mm.
function formatResetTime(timestampMs, nowMs) {
  if (!(Number(timestampMs) > 0)) return ""
  var date = new Date(timestampMs)
  if (isNaN(date.getTime())) return ""
  var now = new Date(nowMs === undefined ? Date.now() : nowMs)
  var time = pad2(date.getHours()) + ":" + pad2(date.getMinutes())
  if (date.toDateString() === now.toDateString()) return time
  return pad2(date.getMonth() + 1) + "/" + pad2(date.getDate()) + " " + time
}

// Remaining-time countdown: "3d 4h", "2h 15m", "5m", "now".
function formatDuration(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function formatCountdown(timestampMs, nowMs) {
  if (!(Number(timestampMs) > 0)) return ""
  var remaining = Number(timestampMs) - (nowMs === undefined ? Date.now() : nowMs)
  if (remaining <= 0) return ""
  return formatDuration(remaining)
}

// 1.2M / 340K / 51K token-style counts.
function formatCount(n) {
  var value = Number(n)
  if (!isFinite(value) || value <= 0) return "0"
  var rounded = function(scale, suffix) {
    var short = (value / scale).toFixed(1)
    if (short.slice(-2) === ".0") short = short.slice(0, -2)
    return short + suffix
  }
  if (value >= 1e9) return rounded(1e9, "B")
  if (value >= 1e6) return rounded(1e6, "M")
  if (value >= 1e3) return rounded(1e3, "K")
  return String(Math.round(value))
}

// Plain grouped integer for count-based stats (36 / 1,204) — K/M/B
// abbreviations read like token figures, so call counts never use them.
function formatCountPlain(n) {
  var value = Number(n)
  if (!isFinite(value) || value <= 0) return "0"
  return String(Math.round(value)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
}

function formatCountFor(n, unit) {
  if (unit === "CNY") return formatMoney(n)
  return unit === "calls" ? formatCountPlain(n) : formatCount(n)
}

// "¥110.00" — input is integer 分 (cents), formatted with pure string math
// so no float ever touches a money value.
function formatMoney(cents) {
  var n = Math.round(Number(cents))
  if (!isFinite(n) || n <= 0) return "¥0.00"
  var yuan = Math.floor(n / 100)
  var fen = n % 100
  return "¥" + String(yuan) + "." + (fen < 10 ? "0" : "") + String(fen)
}

// "36 / 1,000 calls" / "51K / 75K tokens" when both sides are known;
// "51K tokens used" for the used side alone; "" when neither is usable.
function formatUsedLimit(used, limit, unit) {
  var name = unit || "tokens"
  var hasUsed = Number(used) > 0
  var hasLimit = Number(limit) > 0
  if (hasUsed && hasLimit)
    return formatCountFor(used, unit) + " / " + formatCountFor(limit, unit) + " " + name
  if (hasUsed) return formatCountFor(used, unit) + " " + name + " used"
  return ""
}

function formatClock(timestampMs) {
  if (!(Number(timestampMs) > 0)) return ""
  var date = new Date(timestampMs)
  if (isNaN(date.getTime())) return ""
  return pad2(date.getHours()) + ":" + pad2(date.getMinutes())
}

// The window that decides how much room is left — the fullest one.
function bindingWindow(windows) {
  var list = Array.isArray(windows) ? windows : []
  var best = null
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    if (!w) continue
    if (!best || Number(w.percent) > Number(best.percent)) best = w
  }
  return best
}

function windowById(windows, id) {
  var list = Array.isArray(windows) ? windows : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].id === id) return list[i]
  }
  return null
}

// GET over QML XMLHttpRequest. QML's XHR ignores the standard `timeout`
// property (verified), so the caller owns a QML Timer watchdog and treats
// a null/replace activeXhr as "dropped" — the returned xhr enables the
// identity latch: `if (activeXhr !== xhr) return` in the callback.
function httpGet(url, authHeader, onDone) {
  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    onDone(xhr.status, xhr.responseText)
  }
  xhr.open("GET", url)
  if (authHeader !== "") xhr.setRequestHeader("Authorization", authHeader)
  xhr.setRequestHeader("Accept", "application/json")
  xhr.send()
  return xhr
}

// HTTP status code -> short user-facing message; status 0 means the
// request never completed (network error).
function httpStatusMessage(status) {
  if (status === 401) return "Invalid API key"
  if (status === 402) return "Payment required"
  if (status === 429) return "Rate limited"
  if (status > 0) return "HTTP " + status
  return "Network request failed"
}

if (typeof module !== "undefined") {
  module.exports = {
    clamp: clamp,
    normalizePercent: normalizePercent,
    formatPercent: formatPercent,
    severity: severity,
    formatResetTime: formatResetTime,
    formatDuration: formatDuration,
    formatCountdown: formatCountdown,
    formatCount: formatCount,
    formatCountPlain: formatCountPlain,
    formatCountFor: formatCountFor,
    formatMoney: formatMoney,
    formatUsedLimit: formatUsedLimit,
    formatClock: formatClock,
    bindingWindow: bindingWindow,
    windowById: windowById,
    httpStatusMessage: httpStatusMessage
  }
}
