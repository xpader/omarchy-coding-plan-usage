// GLM Coding Plan (Zhipu BigModel open platform) usage parsing.
//
// Endpoint: GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
// with an `Authorization: <apiKey>` header. Response shape (see
// github.com/xpader/glm-usage src/apiClient.ts):
//   { code: 200, data: { level: string, limits: TokenLimit[] } }
// where TokenLimit = {
//   type: "TOKENS_LIMIT" | "TIME_LIMIT",
//   percentage: number,            // 0-100
//   nextResetTime?: number,        // epoch ms, missing until new usage arrives
//   usage?: number, currentValue?: number,
//   usageDetails?: [{ modelCode: string, usage: number }]
// }
//
// TOKENS_LIMIT entries sorted by nextResetTime give the rolling 5-hour
// window first and the weekly window last; TIME_LIMIT is the monthly MCP
// allowance. Everything is normalized into the plugin-wide window shape so
// the panel never knows which platform it is reading.

var WINDOW_TITLES = {
  "five-hour": "5-Hour Window",
  "weekly": "Weekly Window",
  "mcp": "MCP (Monthly)"
}

function normalizeDetails(rawDetails) {
  var out = []
  var list = Array.isArray(rawDetails) ? rawDetails : []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    var value = Number(entry.usage)
    if (!isFinite(value) || value <= 0) continue
    out.push({ name: String(entry.modelCode || ""), value: value })
  }
  out.sort(function(a, b) { return b.value - a.value })
  return out
}

function windowFrom(id, limit) {
  var entry = limit || {}
  var percent = Number(entry.percentage)
  percent = isFinite(percent) && percent >= 0 ? Math.min(100, percent) : -1

  // The API reports the pair backwards from what the names suggest:
  // currentValue is the consumed amount (for MCP it equals the sum of
  // usageDetails) and usage is the window allowance. Only keep pairs that
  // are coherent with the reported percent, so an unexpected shape never
  // renders nonsense numbers.
  var used = Number(entry.currentValue) > 0 ? Number(entry.currentValue) : 0
  var total = Number(entry.usage) > 0 ? Number(entry.usage) : 0
  if (used > 0 && total > 0) {
    if (used > total || Math.abs((used / total) * 100 - percent) > 2) {
      used = 0
      total = 0
    }
  } else {
    used = 0
    total = 0
  }

  return {
    id: id,
    title: WINDOW_TITLES[id] || id,
    percent: percent >= 0 ? Math.round(percent) : -1,
    resetAtMs: Number(entry.nextResetTime) > 0 ? Number(entry.nextResetTime) : 0,
    used: used,
    limit: total,
    unit: id === "mcp" ? "calls" : "tokens",
    details: normalizeDetails(entry.usageDetails)
  }
}

// raw: parsed JSON body (or any value). Returns
//   { ok: true, level, windows } on success — windows carries only entries
//   with a usable percent — or { ok: false, error }.
function parseQuota(raw) {
  if (!raw || typeof raw !== "object") return { ok: false, error: "Empty response" }
  if (raw.code !== undefined && raw.code !== 200) {
    var message = String(raw.msg || "API error " + raw.code)
    if (/unauthorized|invalid|身份验证|鉴权/i.test(message)) message = "Invalid API key"
    return { ok: false, error: message }
  }
  var data = raw.data
  if (!data || !Array.isArray(data.limits)) return { ok: false, error: "No quota data" }

  var tokenLimits = data.limits.filter(function(l) { return l && l.type === "TOKENS_LIMIT" })
  tokenLimits.sort(function(a, b) { return (a.nextResetTime || 0) - (b.nextResetTime || 0) })

  var windows = []
  if (tokenLimits.length > 0) windows.push(windowFrom("five-hour", tokenLimits[0]))
  if (tokenLimits.length > 1) windows.push(windowFrom("weekly", tokenLimits[tokenLimits.length - 1]))

  var timeLimit = null
  for (var i = 0; i < data.limits.length; i++) {
    if (data.limits[i] && data.limits[i].type === "TIME_LIMIT") { timeLimit = data.limits[i]; break }
  }
  if (timeLimit) windows.push(windowFrom("mcp", timeLimit))

  var usable = windows.filter(function(w) { return w.percent >= 0 })
  if (usable.length === 0) return { ok: false, error: "No quota windows reported" }

  return { ok: true, level: String(data.level || ""), windows: usable }
}

if (typeof module !== "undefined") {
  module.exports = { parseQuota: parseQuota }
}
