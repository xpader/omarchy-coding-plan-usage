// Node tests: providers/deepseek/Model.js (balance + daily ledger, integer 分)
const M = require("/home/pader/.config/omarchy/plugins/pader.coding-plan-usage/providers/deepseek/Model.js")
const { parseBalance, applyDailyState, todayString, toCents } = M

let failed = 0
function check(name, got, want) {
  const same = JSON.stringify(got) === JSON.stringify(want)
  if (!same) failed++
  console.log((same ? "ok" : "FAIL") + "  " + name + (same ? "" : `  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`))
}

// ---- toCents: string math, never float ----
check("cents 40.51", toCents("40.51"), 4051)
check("cents int", toCents("110"), 11000)
check("cents 0.05", toCents("0.05"), 5)
check("cents 0.5 pad", toCents("0.5"), 50)
check("cents 1.005 truncates", toCents("1.005"), 100)
check("cents negative", toCents("-3.20"), -320)
check("cents garbage", Number.isNaN(toCents("abc")), true)
check("cents number input", toCents(40.51), 4051)

// ---- parseBalance → integer cents ----
check("happy path", parseBalance({
  is_available: true,
  balance_infos: [
    { currency: "CNY", total_balance: "110.00", granted_balance: "10.00", topped_up_balance: "100.00" }
  ]
}), { ok: true, available: true, total: 11000, granted: 1000, topped: 10000 })

check("sum & filter", parseBalance({
  is_available: true,
  balance_infos: [
    { currency: "CNY", total_balance: "5.50", granted_balance: "0", topped_up_balance: "5.50" },
    { currency: "USD", total_balance: "999", granted_balance: "999", topped_up_balance: "0" },
    { currency: "CNY", total_balance: "2.25", granted_balance: "2.25", topped_up_balance: "0" }
  ]
}), { ok: true, available: true, total: 775, granted: 225, topped: 550 })

check("auth error", parseBalance({
  error: { message: "Authentication Fails, Your api key: xx is invalid", type: "authentication_error", code: "invalid_request_error" }
}), { ok: false, error: "Invalid API key" })
check("no data", parseBalance({ is_available: true }), { ok: false, error: "No balance data" })
check("empty", parseBalance(null), { ok: false, error: "Empty response" })
check("garbage numbers", parseBalance({
  is_available: false,
  balance_infos: [{ currency: "CNY", total_balance: "abc", granted_balance: "-3", topped_up_balance: "" }]
}), { ok: true, available: false, total: 0, granted: 0, topped: 0 })

// ---- daily ledger (integer 分) ----
let r = applyDailyState(null, 11000, "2026-10-09")
check("bootstrap", r, { state: { unit: "fen", baselineBalance: 11000, baselineDate: "2026-10-09", accumulatedCost: 0 }, spentToday: 0 })

r = applyDailyState(r.state, 10850, "2026-10-09")
check("spend accumulates", r, { state: { unit: "fen", baselineBalance: 10850, baselineDate: "2026-10-09", accumulatedCost: 150 }, spentToday: 150 })

r = applyDailyState(r.state, 10700, "2026-10-09")
check("second drop adds up", r.spentToday, 300)

r = applyDailyState(r.state, 20000, "2026-10-09")
check("top-up not counted", r, { state: { unit: "fen", baselineBalance: 20000, baselineDate: "2026-10-09", accumulatedCost: 300 }, spentToday: 300 })

r = applyDailyState(r.state, 19990, "2026-10-09")
check("spend after top-up", r, { state: { unit: "fen", baselineBalance: 19990, baselineDate: "2026-10-09", accumulatedCost: 310 }, spentToday: 310 })

r = applyDailyState(r.state, 19000, "2026-10-10")
check("day rollover", r, { state: { unit: "fen", baselineBalance: 19000, baselineDate: "2026-10-10", accumulatedCost: 0 }, spentToday: 0 })

// Legacy yuan ledger (no unit marker) migrates to fen
check("legacy yuan ledger", applyDailyState({ baselineBalance: 40.51, baselineDate: "2026-10-09", accumulatedCost: 1.23 }, 4041, "2026-10-09"),
  { state: { unit: "fen", baselineBalance: 4041, baselineDate: "2026-10-09", accumulatedCost: 133 }, spentToday: 133 })

// Pure integer accumulation: 0.07 × 3 costs stay exact (0.21), no drift
let s = applyDailyState(null, 10000, "d").state
for (let i = 0; i < 3; i++) s = applyDailyState(s, s.baselineBalance - 7, "d").state
check("no float drift", s.accumulatedCost, 21)

check("garbage state", applyDailyState("junk", 5000, "d"),
  { state: { unit: "fen", baselineBalance: 5000, baselineDate: "d", accumulatedCost: 0 }, spentToday: 0 })
check("negative balance ignored", applyDailyState({ unit: "fen", baselineBalance: 5000, baselineDate: "d", accumulatedCost: 200 }, -1, "d"),
  { state: { unit: "fen", baselineBalance: 5000, baselineDate: "d", accumulatedCost: 200 }, spentToday: 200 })

check("todayString shape", /^\d{4}-\d{2}-\d{2}$/.test(todayString(new Date(2026, 9, 9).getTime())), true)

process.exit(failed ? 1 : 0)
