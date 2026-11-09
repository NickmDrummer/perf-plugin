import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const Logic = require("../Logic.js");

const CPU_SAMPLE = [
  "cpu  100 2 50 800 20 5 3 4 0 0",
  "cpu0 50 1 25 400 10 2 1 2 0 0",
  "intr 12345"
].join("\n");

test("CPU samples parse into idle and total", () => {
  const sample = Logic.parseCpuStat(CPU_SAMPLE);
  assert.equal(sample.idle, 820);
  // user nice system idle iowait irq softirq steal; guest and guest_nice are
  // already inside user and nice.
  assert.equal(sample.total, 984);
});

test("CPU percentage needs two samples and survives counter resets", () => {
  const prev = { idle: 820, total: 984 };
  const next = { idle: 1370, total: 2084 };
  assert.equal(Logic.cpuPercent(prev, next), 50);
  assert.equal(Logic.cpuPercent(null, next), null);
  assert.equal(Logic.cpuPercent(next, next), null);
  assert.deepEqual(Logic.parseCpuStat("garbage"), null);
});

test("memory prefers MemAvailable and falls back on old kernels", () => {
  const modern = Logic.parseMeminfo("MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\n");
  assert.deepEqual(modern, { totalKb: 16000000, usedKb: 10000000 });

  const legacy = Logic.parseMeminfo([
    "MemTotal: 1000 kB",
    "MemFree: 100 kB",
    "Buffers: 50 kB",
    "Cached: 150 kB"
  ].join("\n"));
  assert.deepEqual(legacy, { totalKb: 1000, usedKb: 700 });

  assert.equal(Logic.parseMeminfo("nothing here"), null);
});

test("percentages, bytes and NVIDIA readings are bounded", () => {
  assert.equal(Logic.parsePercent("24\n"), 24);
  assert.equal(Logic.parsePercent(""), -1);
  assert.equal(Logic.parsePercent("999"), 100);

  assert.equal(Logic.parseBytes("1035075584"), 1035075584);
  assert.equal(Logic.parseBytes(""), -1);

  const nvidia = Logic.parseNvidia("7, 1234, 8188\n");
  assert.deepEqual(nvidia, { util: 7, usedMib: 1234, totalMib: 8188 });

  assert.deepEqual(Logic.parseNvidia("[N/A], [N/A], 8188"), {
    util: -1,
    usedMib: -1,
    totalMib: 8188
  });
});

test("formatting stays compact", () => {
  assert.equal(Logic.percentText(-1), "—");
  assert.equal(Logic.percentText(12.4), "12%");
  assert.equal(Logic.sizeText(7.64), "7.6GB");
  assert.equal(Logic.sizeText(-1), "—");
  assert.equal(Logic.detailText(7.64, 15.42), "7.6 / 15.4 GB");
  assert.equal(Logic.detailText(1, -1), "—");
  assert.equal(Math.round(Logic.fraction(50, 200)), 25);
  assert.equal(Logic.isCritical(90), true);
  assert.equal(Logic.isCritical(89.9), false);
  assert.equal(Logic.kibToGib(1048576), 1);
  assert.equal(Logic.mibToGib(1024), 1);
});
