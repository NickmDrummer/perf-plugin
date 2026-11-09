// Parse and format the perf widget's readings.
//
// Everything here is pure: text in, value out. That keeps the QML layer to
// file plumbing and lets the parsers run under plain Node (tests/logic.test.mjs).

// /proc/stat, first "cpu " line:
//   cpu user nice system idle iowait irq softirq steal guest guest_nice
// guest and guest_nice are already counted in user and nice, so the total
// stops at steal to avoid counting them twice.
function parseCpuStat(text) {
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (!/^cpu\s/.test(line)) continue;
    var fields = line.trim().split(/\s+/);
    if (fields.length < 5) return null;
    var values = [];
    for (var j = 1; j < fields.length; j++) {
      var n = Number(fields[j]);
      values.push(isFinite(n) && n >= 0 ? n : 0);
    }
    var total = 0;
    var upto = Math.min(values.length, 8);
    for (var k = 0; k < upto; k++) total += values[k];
    return { idle: (values[3] || 0) + (values[4] || 0), total: total };
  }
  return null;
}

// Share of CPU time that was not idle between two samples.
// Returns null while there is no usable delta (first sample, counter reset).
function cpuPercent(prev, next) {
  if (!prev || !next) return null;
  var dTotal = next.total - prev.total;
  var dIdle = next.idle - prev.idle;
  if (!(dTotal > 0)) return null;
  var pct = (1 - dIdle / dTotal) * 100;
  if (!isFinite(pct)) return null;
  return clamp(pct, 0, 100);
}

// /proc/meminfo in kB. MemAvailable is the kernel's own estimate of what a new
// workload could claim, which counts reclaimable cache the way users expect;
// older kernels without it fall back to the free+buffers+cached sum.
function parseMeminfo(text) {
  var values = {};
  var lines = String(text || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var match = /^([A-Za-z_()]+):\s+(\d+)\s*kB/.exec(lines[i]);
    if (match) values[match[1]] = Number(match[2]);
  }
  var total = values.MemTotal;
  if (!(total > 0)) return null;
  var used;
  if (values.MemAvailable !== undefined) {
    used = total - values.MemAvailable;
  } else {
    used = total - (values.MemFree || 0) - (values.Buffers || 0)
         - (values.Cached || 0) - (values.SReclaimable || 0);
  }
  if (!(used >= 0)) used = 0;
  if (used > total) used = total;
  return { totalKb: total, usedKb: used };
}

// A single sysfs percentage, e.g. /sys/class/drm/card1/device/gpu_busy_percent.
function parsePercent(text) {
  var raw = String(text || "").trim();
  if (!raw) return -1;
  var value = Number(raw);
  if (!isFinite(value)) return -1;
  return clamp(value, 0, 100);
}

// A byte counter from sysfs (mem_info_vram_used, mem_info_vram_total).
// Returns -1 when the file is missing or unreadable.
function parseBytes(text) {
  var raw = String(text || "").trim();
  if (!raw) return -1;
  var value = Number(raw);
  if (!isFinite(value) || value < 0) return -1;
  return value;
}

// One line of:
//   nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
//              --format=csv,noheader,nounits
// Older drivers report "[N/A]" for a reading; that field becomes -1 rather
// than poisoning the whole sample.
function parseNvidia(text) {
  var line = String(text || "").trim().split("\n")[0];
  if (!line) return null;
  var fields = line.split(",");
  if (fields.length < 3) return null;
  var util = Number(fields[0].trim());
  var used = Number(fields[1].trim());
  var total = Number(fields[2].trim());
  return {
    util: isFinite(util) ? clamp(util, 0, 100) : -1,
    usedMib: isFinite(used) && used >= 0 ? used : -1,
    totalMib: isFinite(total) && total > 0 ? total : -1
  };
}

function clamp(value, min, max) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

// "12%", or an em dash while the first CPU sample is still pending.
function percentText(pct) {
  if (!isFinite(pct) || pct < 0) return "—";
  return Math.round(pct) + "%";
}

// "6.7/15G": used keeps one decimal, the total drops it once it is big
// enough that the digit would only add noise.
function pairText(used, total) {
  if (!isFinite(total) || total <= 0 || !isFinite(used) || used < 0) return "—";
  var totalText = total >= 10 ? String(Math.round(total)) : Number(total).toFixed(1);
  return Number(used).toFixed(1) + "/" + totalText + "G";
}

// Used fraction of a total, for threshold colours and tooltips.
function fraction(used, total) {
  if (!isFinite(total) || total <= 0 || !isFinite(used) || used < 0) return -1;
  return clamp(used / total * 100, 0, 100);
}

// A reading is worth flagging from 90% up, the point where the machine starts
// to feel it rather than merely working.
function isCritical(pct) {
  return isFinite(pct) && pct >= 90;
}

function kibToGib(kib) {
  return kib / 1048576;
}

function mibToGib(mib) {
  return mib / 1024;
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    parseCpuStat: parseCpuStat,
    cpuPercent: cpuPercent,
    parseMeminfo: parseMeminfo,
    parsePercent: parsePercent,
    parseBytes: parseBytes,
    parseNvidia: parseNvidia,
    clamp: clamp,
    percentText: percentText,
    pairText: pairText,
    fraction: fraction,
    isCritical: isCritical,
    kibToGib: kibToGib,
    mibToGib: mibToGib
  };
}
