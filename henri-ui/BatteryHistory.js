.pragma library
// Generic battery-history math: parse a day's CSV, cut a window, bucket it
// into bars, fit an axis, pick round tick marks. Shape-compatible with the
// akku-aufzeichnung logger's CSV (henri.power) and the Mac's
// mac-battery-log (control-center's Mac Battery page) -- same header:
//   zeit,status,prozent,energie_wh,leistung_w,spannung_v,strom_a,voll_wh,temperatur_c,zyklus_wh
// A gap longer than this means the machine slept, or the logger/daemon was
// stopped: the power draw during it is unknown, so it's marked, not summed.
var HISTORY_GAP_MS = 90 * 1000

function historyFileName(prefix, date) {
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return prefix + date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + ".csv"
}

// One day's CSV -> samples. `day` is any Date on that day (the file has no
// date in its rows, only HH:MM:SS).
function parseHistoryCsv(raw, day) {
  var out = []
  var lines = String(raw || "").split("\n")
  var y = day.getFullYear(), m = day.getMonth(), d = day.getDate()
  function num(v) {
    if (v === undefined || v === "") return null
    var n = Number(v)
    return isFinite(n) ? n : null
  }
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].trim().split(",")
    var hms = /^(\d\d):(\d\d):(\d\d)$/.exec(f[0])
    if (!hms) continue
    var t = new Date(y, m, d, Number(hms[1]), Number(hms[2]), Number(hms[3])).getTime()
    if (f[1] === "LUECKE") {
      out.push({ t: t, gap: true })
      continue
    }
    var pct = num(f[2])
    if (pct === null) continue
    out.push({
      t: t,
      gap: false,
      status: f[1],
      pct: pct,
      wh: num(f[3]),
      w: num(f[4]),
      v: num(f[5]),
      a: num(f[6]),
      fullWh: num(f[7]),
      temp: num(f[8]),
      cycleWh: num(f[9])
    })
  }
  return out
}

// Samples of every touched day (older first), cut to the window ending at
// `now`. A time jump longer than HISTORY_GAP_MS becomes a gap marker.
function historyWindow(samples, now, hours) {
  var from = now - hours * 3600 * 1000
  var out = []
  var prev = null
  for (var i = 0; i < samples.length; i++) {
    var s = samples[i]
    if (s.t < from || s.t > now) continue
    if (s.gap) {
      if (prev && !prev.gap) out.push(s)
      prev = s
      continue
    }
    if (prev && !prev.gap && s.t - prev.t > HISTORY_GAP_MS)
      out.push({ t: prev.t + 1, gap: true })
    out.push(s)
    prev = s
  }
  return out
}

// Figures for the stat tiles under the graph. Energy is integrated from the
// logged power over the time to the next sample, never across a gap.
function historyStats(points) {
  var onBatteryH = 0, usedWh = 0, chargedWh = 0, chargingH = 0
  var minPct = null, maxPct = null, maxTemp = null, last = null
  for (var i = 0; i < points.length; i++) {
    var a = points[i]
    if (a.gap) continue
    last = a
    if (minPct === null || a.pct < minPct) minPct = a.pct
    if (maxPct === null || a.pct > maxPct) maxPct = a.pct
    if (a.temp !== null && (maxTemp === null || a.temp > maxTemp)) maxTemp = a.temp
    var b = points[i + 1]
    if (!b || b.gap || a.w === null) continue
    var h = (b.t - a.t) / 3600000
    if (a.status === "Discharging") {
      onBatteryH += h
      usedWh += a.w * h
    } else if (a.status === "Charging") {
      chargingH += h
      chargedWh += a.w * h
    }
  }
  var avgDrawW = onBatteryH >= 1 / 6 ? usedWh / onBatteryH : null
  var fullWh = last ? last.fullWh : null
  var cycleStart = null
  if (last && last.status === "Discharging") {
    for (var j = points.length - 1; j >= 0; j--) {
      if (points[j].gap) continue
      if (points[j].status !== "Discharging") break
      cycleStart = points[j].t
    }
  }
  return {
    samples: last !== null,
    onBatteryH: onBatteryH,
    usedWh: usedWh,
    chargingH: chargingH,
    chargedWh: chargedWh,
    avgDrawW: avgDrawW,
    runtimeH: avgDrawW && fullWh ? fullWh / avgDrawW : null,
    fullWh: fullWh,
    minPct: minPct,
    maxPct: maxPct,
    maxTemp: maxTemp,
    discharging: !!last && last.status === "Discharging",
    cycleWh: last && last.status === "Discharging" ? last.cycleWh : null,
    cycleStart: cycleStart,
    lastW: last ? last.w : null,
    lastV: last ? last.v : null,
    lastA: last ? last.a : null,
    lastStatus: last ? last.status : null,
    lastPct: last ? last.pct : null
  }
}

// ---- What the bars can show ---------------------------------------------
var HISTORY_MEAN_FIELDS = ["w", "v", "a"]

var HISTORY_METRICS = [
  { key: "percent", label: "Charge", unit: "%", field: "pct", decimals: 0, zero: true },
  { key: "watts", label: "Power", unit: "W", field: "w", decimals: 1, zero: true },
  { key: "volts", label: "Voltage", unit: "V", field: "v", decimals: 2, zero: false },
  { key: "amps", label: "Current", unit: "A", field: "a", decimals: 2, zero: true }
]
var HISTORY_DEFAULT_METRIC = "percent"

var HISTORY_METRIC_ALIASES = {
  charge: "percent", percentage: "percent", pct: "percent",
  power: "watts", watt: "watts", w: "watts",
  voltage: "volts", volt: "volts", v: "volts",
  current: "amps", amp: "amps", ampere: "amps", a: "amps"
}

function historyMetric(key) {
  var k = String(key === undefined || key === null ? "" : key).toLowerCase()
  if (HISTORY_METRIC_ALIASES[k]) k = HISTORY_METRIC_ALIASES[k]
  for (var i = 0; i < HISTORY_METRICS.length; i++)
    if (HISTORY_METRICS[i].key === k) return HISTORY_METRICS[i]
  return null
}

// The window cut into `count` equal slots for the bar chart. Each slot holds
// the charge at its last sample (the level it ended on), whether it was
// spent mostly on battery or plugged in, and the mean power/volts/amps; a
// slot without samples (sleep, machine off) is null. A slot that falls
// between two consecutive samples with no gap between them takes the
// earlier one's values instead of showing a hole.
function historyBuckets(points, now, hours, count) {
  var span = hours * 3600 * 1000
  var from = now - span
  var slot = span / count
  var acc = []
  for (var i = 0; i < count; i++) acc.push(null)
  function slotOf(t) { return Math.min(count - 1, Math.floor((t - from) / slot)) }
  function newSlot() {
    return { n: 0, battery: 0, sum: { w: 0, v: 0, a: 0 }, cnt: { w: 0, v: 0, a: 0 }, pct: 0, t: 0 }
  }
  function addSample(a, p) {
    a.n++
    if (p.status === "Discharging") a.battery++
    for (var i = 0; i < HISTORY_MEAN_FIELDS.length; i++) {
      var key = HISTORY_MEAN_FIELDS[i], v = p[key]
      if (v !== null && v !== undefined) { a.sum[key] += v; a.cnt[key]++ }
    }
    if (p.t >= a.t) { a.t = p.t; a.pct = p.pct }
  }
  function meanOf(a, key) { return a.cnt[key] > 0 ? a.sum[key] / a.cnt[key] : null }
  var prev = null
  var fill = []
  for (var j = 0; j < points.length; j++) {
    var p = points[j]
    if (p.gap) { prev = null; continue }
    if (p.t < from || p.t > now) continue
    var k = slotOf(p.t)
    if (prev && p.t - prev.t <= HISTORY_GAP_MS)
      for (var f = slotOf(prev.t) + 1; f < k; f++) fill.push({ k: f, p: prev })
    prev = p
    addSample(acc[k] || (acc[k] = newSlot()), p)
  }
  for (var q = 0; q < fill.length; q++) {
    var e = fill[q]
    if (acc[e.k]) continue
    addSample(acc[e.k] = newSlot(), e.p)
  }
  return acc.map(function (a, idx) {
    if (!a) return null
    return {
      t0: from + idx * slot,
      t1: from + (idx + 1) * slot,
      pct: a.pct,
      battery: a.battery * 2 > a.n,
      w: meanOf(a, "w"),
      v: meanOf(a, "v"),
      a: meanOf(a, "a")
    }
  })
}

// The ranges a History page can offer. `bars` keeps a slot at 30 s or more
// (the loggers' interval) on the short ranges and near 72-84 on the long ones.
var HISTORY_RANGES = [
  { key: "15m", hours: 0.25, bars: 30, label: "15 minutes", short: "15 min" },
  { key: "30m", hours: 0.5, bars: 60, label: "30 minutes", short: "30 min" },
  { key: "1h", hours: 1, bars: 60, label: "1 hour", short: "1 h" },
  { key: "3h", hours: 3, bars: 72, label: "3 hours", short: "3 h" },
  { key: "6h", hours: 6, bars: 72, label: "6 hours", short: "6 h" },
  { key: "12h", hours: 12, bars: 72, label: "12 hours", short: "12 h" },
  { key: "24h", hours: 24, bars: 72, label: "24 hours", short: "24 h" },
  { key: "3d", hours: 72, bars: 72, label: "3 days", short: "3 days" },
  { key: "7d", hours: 168, bars: 84, label: "7 days", short: "7 days" }
]
var HISTORY_DEFAULT_RANGE = "6h"

function historyRange(key) {
  var k = String(key)
  if (/^\d+$/.test(k)) k += "h"
  for (var i = 0; i < HISTORY_RANGES.length; i++)
    if (HISTORY_RANGES[i].key === k) return HISTORY_RANGES[i]
  return null
}

// The daily files a window ending at `now` can touch, oldest first.
function historyDays(prefix, now, hours) {
  var n = Math.min(9, Math.ceil(hours / 24) + 1)
  var out = []
  for (var i = n - 1; i >= 0; i--) {
    var day = new Date(now.getFullYear(), now.getMonth(), now.getDate() - i, 12)
    out.push({ name: historyFileName(prefix, day), day: day })
  }
  return out
}

// The axis the bars of a metric are drawn against, as { min, max }. Charge is
// always 0-100; power and current round up to the next step above the
// highest bar; voltage fits the window instead of starting at zero, since
// the pack only swings about a volt.
var HISTORY_WATT_STEPS = [5, 10, 20, 30, 40, 60, 80, 100, 150, 200, 300]
var HISTORY_AMP_STEPS = [1, 2, 3, 4, 5, 6, 8, 10, 15, 20, 30]
var HISTORY_VOLT_STEPS = [0.1, 0.2, 0.5, 1, 2, 5]
var HISTORY_VOLT_FALLBACK = { min: 7, max: 9 }

function historyAxis(bars, metricKey) {
  var m = historyMetric(metricKey) || historyMetric(HISTORY_DEFAULT_METRIC)
  if (m.key === "percent") return { min: 0, max: 100 }
  var min = null, max = null
  for (var i = 0; i < bars.length; i++) {
    var b = bars[i]
    if (!b) continue
    var v = b[m.field]
    if (v === null || v === undefined || !isFinite(v)) continue
    if (min === null || v < min) min = v
    if (max === null || v > max) max = v
  }
  if (m.zero) {
    var steps = m.key === "amps" ? HISTORY_AMP_STEPS : HISTORY_WATT_STEPS
    var top = max === null ? 0 : max
    for (var j = 0; j < steps.length; j++) if (top <= steps[j]) return { min: 0, max: steps[j] }
    return { min: 0, max: Math.ceil(top / steps[steps.length - 1]) * steps[steps.length - 1] }
  }
  if (min === null) return { min: HISTORY_VOLT_FALLBACK.min, max: HISTORY_VOLT_FALLBACK.max }
  var step = HISTORY_VOLT_STEPS[HISTORY_VOLT_STEPS.length - 1]
  for (var k = 0; k < HISTORY_VOLT_STEPS.length; k++)
    if ((max - min) / HISTORY_VOLT_STEPS[k] <= 6) { step = HISTORY_VOLT_STEPS[k]; break }
  var lo = Math.floor(min / step) * step
  var hi = Math.ceil(max / step) * step
  if (hi <= lo) hi = lo + step
  if (Math.round((hi - lo) / step) % 2 === 1) {
    if (min - lo >= hi - max) hi += step
    else lo -= step
  }
  function round3(n) { return Math.round(n * 1000) / 1000 }
  return { min: round3(lo), max: round3(hi) }
}

// Time-axis marks inside [from, now]: the first round local step (5 min ...
// 1 day) that keeps it to `maxTicks` labels.
function historyTicks(from, now, maxTicks) {
  if (!(now > from) || !isFinite(from)) return { step: 0, ticks: [] }
  var minutes = (now - from) / 60000
  var steps = [5, 10, 15, 30, 60, 120, 180, 360, 720, 1440, 2880]
  var step = steps[steps.length - 1]
  for (var i = 0; i < steps.length; i++)
    if (minutes / steps[i] <= maxTicks) { step = steps[i]; break }
  var d = new Date(from)
  var mid = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
  var m = Math.ceil((from - mid) / 60000 / step) * step
  var out = []
  for (var t = mid + m * 60000; t <= now && out.length < 40; t += step * 60000) {
    if (step >= 1440) {
      var md = new Date(t)
      if (md.getHours() !== 0) t = new Date(md.getFullYear(), md.getMonth(), md.getDate() + (md.getHours() > 12 ? 1 : 0)).getTime()
    }
    if (t >= from) out.push(t)
  }
  return { step: step, ticks: out }
}

function durationText(hours) {
  if (hours === null || !isFinite(hours)) return "—"
  var mins = Math.round(hours * 60)
  if (mins < 60) return mins + " min"
  var h = Math.floor(mins / 60), m = mins % 60
  return h + " h" + (m > 0 ? " " + m + " min" : "")
}

if (typeof module !== "undefined") {
  module.exports = {
    HISTORY_GAP_MS: HISTORY_GAP_MS,
    historyFileName: historyFileName,
    parseHistoryCsv: parseHistoryCsv,
    historyWindow: historyWindow,
    historyStats: historyStats,
    historyBuckets: historyBuckets,
    HISTORY_RANGES: HISTORY_RANGES,
    HISTORY_DEFAULT_RANGE: HISTORY_DEFAULT_RANGE,
    historyRange: historyRange,
    historyDays: historyDays,
    HISTORY_METRICS: HISTORY_METRICS,
    HISTORY_DEFAULT_METRIC: HISTORY_DEFAULT_METRIC,
    historyMetric: historyMetric,
    historyAxis: historyAxis,
    historyTicks: historyTicks,
    durationText: durationText
  }
}
