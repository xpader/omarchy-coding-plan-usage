// DeepSeek (api.deepseek.com) balance parsing.
//
// Endpoint: GET https://api.deepseek.com/user/balance with an
// `Authorization: Bearer <apiKey>` header (same call the VSCode extension
// "DeepSeek Balance Display" makes). Response:
//   { is_available: boolean,
//     balance_infos: [{ currency: "CNY", total_balance: "110.00",
//                       granted_balance: "10.00", topped_up_balance: "100.00" }] }
// Auth failures come back as HTTP 401 with
//   { error: { message, type: "authentication_error", ... } }
// but curl -f discards that body, so the provider maps it from the exit
// code instead.

// Amounts travel as integer 分 (cents) end to end — parsing goes through
// string math so a "40.51" never becomes a float, and the daily ledger
// accumulates with exact integer arithmetic.

// "40.51" / 40.51 / "40" → 4051. Truncates beyond two decimals (the API
// only ever sends two).
function toCents(value) {
  var text = String(value == null ? "" : value).trim()
  if (!/^-?\d+(\.\d+)?$/.test(text)) return NaN
  var negative = text.charAt(0) === "-"
  if (negative) text = text.slice(1)
  var parts = text.split(".")
  var yuan = parts[0]
  var fen = (parts[1] || "").slice(0, 2)
  while (fen.length < 2) fen += "0"
  var cents = parseInt(yuan, 10) * 100 + parseInt(fen, 10)
  return negative ? -cents : cents
}

function sumCny(list, field) {
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    if (entry.currency !== "CNY") continue
    var cents = toCents(entry[field])
    if (isFinite(cents) && cents > 0) total += cents
  }
  return total
}

// raw: parsed JSON body. Returns { ok: true, available, total, granted,
// topped } — all integer cents — or { ok: false, error }.
function parseBalance(raw) {
  if (!raw || typeof raw !== "object") return { ok: false, error: "Empty response" }
  if (raw.error) {
    var message = String(raw.error.message || raw.error.type || "API error")
    if (/authentication|invalid/i.test(raw.error.type + " " + message))
      message = "Invalid API key"
    return { ok: false, error: message }
  }
  if (!Array.isArray(raw.balance_infos)) return { ok: false, error: "No balance data" }

  return {
    ok: true,
    available: raw.is_available === true,
    total: sumCny(raw.balance_infos, "total_balance"),
    granted: sumCny(raw.balance_infos, "granted_balance"),
    topped: sumCny(raw.balance_infos, "topped_up_balance")
  }
}

// ---------------------------------------------------------------------------
// Daily spend tracking (mirrors the VSCode extension's storage.js), all in
// integer 分:
//   state = { baselineBalance, baselineDate ("YYYY-MM-DD"), accumulatedCost }
// - new day (or first ever sample) → baseline := balance, cost := 0
// - balance dropped → cost += baseline - balance, baseline := balance
// - balance rose (top-up) → baseline := balance only, cost untouched
// Pure function so it stays node-testable; the provider persists the state.

function todayString(nowMs) {
  var d = new Date(nowMs === undefined ? Date.now() : nowMs)
  var mm = String(d.getMonth() + 1).padStart(2, "0")
  var dd = String(d.getDate()).padStart(2, "0")
  return d.getFullYear() + "-" + mm + "-" + dd
}

// Accepts the current fen-based ledger, or a legacy yuan-float one (no
// "unit": "fen" marker) which gets converted once at load time.
function normalizeDailyState(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var scale = s.unit === "fen" ? 1 : 100
  var toInt = function(v) {
    var n = Number(v)
    return isFinite(n) ? Math.round(n * scale) : NaN
  }
  var balance = toInt(s.baselineBalance)
  var cost = toInt(s.accumulatedCost)
  return {
    unit: "fen",
    baselineBalance: isFinite(balance) && balance > 0 ? balance : null,
    baselineDate: typeof s.baselineDate === "string" ? s.baselineDate : null,
    accumulatedCost: isFinite(cost) && cost > 0 ? cost : 0
  }
}

// Returns { state: <new persisted state>, spentToday: number } — every
// amount an integer in 分.
function applyDailyState(prevState, balanceCents, today) {
  var s = normalizeDailyState(prevState)
  var current = Number(balanceCents)
  if (!isFinite(current) || current < 0) return { state: s, spentToday: s.accumulatedCost }

  if (s.baselineDate !== today || s.baselineBalance === null) {
    return { state: { unit: "fen", baselineBalance: current, baselineDate: today, accumulatedCost: 0 }, spentToday: 0 }
  }
  if (current < s.baselineBalance) {
    var cost = s.accumulatedCost + (s.baselineBalance - current)
    return { state: { unit: "fen", baselineBalance: current, baselineDate: today, accumulatedCost: cost }, spentToday: cost }
  }
  return { state: { unit: "fen", baselineBalance: current, baselineDate: today, accumulatedCost: s.accumulatedCost },
           spentToday: s.accumulatedCost }
}

if (typeof module !== "undefined") {
  module.exports = { parseBalance: parseBalance, applyDailyState: applyDailyState,
                     todayString: todayString, toCents: toCents }
}
