import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Logic.js" as Logic

// Performance — CPU, RAM, GPU and VRAM in the bar.
//
// Readings come straight from procfs and sysfs: no subprocess runs on an AMD
// machine, and only nvidia-smi is spawned, once per tick, on NVIDIA ones. The
// bar is built per monitor, so each instance keeps its own FileViews and timer;
// the files are a few KiB and are read without forking, which keeps that cheap.
BarWidget {
  id: root
  moduleName: "nickmdrummer.perf"

  // ---------------------------------------------------------------- settings

  readonly property bool wantsCpu: root.setting("cpu", true) !== false
  readonly property bool wantsRam: root.setting("ram", true) !== false
  readonly property bool wantsGpu: root.setting("gpu", true) !== false
  readonly property bool wantsVram: root.setting("vram", false) === true
  // One second by default, the pace btop runs at on its default profile.
  readonly property int refreshMs: {
    var value = Number(root.setting("interval", 1000))
    if (!isFinite(value)) return 1000
    return Math.max(500, Math.min(5000, Math.round(value)))
  }

  // ------------------------------------------------------------------- state

  // First sample of /proc/stat only seeds this; a delta needs two.
  property var prevCpu: null
  property real cpuPct: -1
  property real ramUsedKb: -1
  property real ramTotalKb: -1

  // "" while probing, then the backend that answered: "amdgpu" or "nvidia".
  property string gpuBackend: ""
  property int amdCard: -1
  property real gpuPct: -1
  property real vramUsedMib: -1
  property real vramTotalMib: -1

  readonly property bool amd: gpuBackend === "amdgpu"
  readonly property string amdBase: amdCard < 0 ? "" : "/sys/class/drm/card" + amdCard + "/device"
  readonly property bool hasGpu: gpuBackend !== "" && gpuPct >= 0
  readonly property bool hasVram: hasGpu && vramTotalMib > 0 && vramUsedMib >= 0
  readonly property real ramPct: Logic.fraction(ramUsedKb, ramTotalKb)
  readonly property real vramPct: Logic.fraction(vramUsedMib, vramTotalMib)

  readonly property bool critical: (wantsCpu && Logic.isCritical(cpuPct))
    || (wantsRam && Logic.isCritical(ramPct))
    || (wantsGpu && hasGpu && Logic.isCritical(gpuPct))
    || (wantsVram && hasVram && Logic.isCritical(vramPct))

  // ------------------------------------------------------------------ labels

  readonly property string barLabel: {
    var parts = []
    if (wantsCpu) parts.push("CPU " + Logic.percentText(cpuPct))
    if (wantsRam) parts.push("RAM " + Logic.sizeText(Logic.kibToGib(ramUsedKb)))
    if (wantsGpu && hasGpu) parts.push("GPU " + Logic.percentText(gpuPct))
    if (wantsVram && hasVram) parts.push("VRAM " + Logic.sizeText(Logic.mibToGib(vramUsedMib)))
    return parts.join(" | ")
  }

  // A vertical bar is 28px wide, so the labels give way to bare values; the
  // tooltip still names every one of them.
  readonly property string verticalLabel: {
    var parts = []
    if (wantsCpu) parts.push(Logic.percentText(cpuPct))
    if (wantsRam) parts.push(Logic.sizeText(Logic.kibToGib(ramUsedKb)))
    if (wantsGpu && hasGpu) parts.push(Logic.percentText(gpuPct))
    if (wantsVram && hasVram) parts.push(Logic.sizeText(Logic.mibToGib(vramUsedMib)))
    return parts.join("\n")
  }

  readonly property string tooltip: {
    var lines = []
    if (wantsCpu) lines.push("CPU  " + Logic.percentText(cpuPct))
    if (wantsRam) lines.push("RAM  " + Logic.detailText(Logic.kibToGib(ramUsedKb), Logic.kibToGib(ramTotalKb))
                              + (ramPct >= 0 ? " (" + Math.round(ramPct) + "%)" : ""))
    if (wantsGpu && hasGpu) lines.push("GPU  " + Logic.percentText(gpuPct))
    if (wantsVram && hasVram) lines.push("VRAM  " + Logic.detailText(Logic.mibToGib(vramUsedMib), Logic.mibToGib(vramTotalMib))
                                          + (vramPct >= 0 ? " (" + Math.round(vramPct) + "%)" : ""))
    if (lines.length === 0) return ""
    return lines.join("\n")
  }

  // ------------------------------------------------------------------ reads

  function refresh() {
    if (wantsCpu) cpuFile.reload()
    if (wantsRam) memFile.reload()

    if (amd) {
      if (wantsGpu) gpuFile.reload()
      if (wantsVram) {
        vramUsedFile.reload()
        vramTotalFile.reload()
      }
    } else if (gpuBackend === "nvidia" && wantsGpu) {
      if (!nvidiaProc.running) nvidiaProc.running = true
    }
  }

  function applyCpu(text) {
    var reading = Logic.parseCpuStat(text)
    if (!reading) return
    var prev = root.prevCpu
    root.prevCpu = reading
    if (!prev) return
    var pct = Logic.cpuPercent(prev, reading)
    if (pct !== null) root.cpuPct = pct
  }

  function applyMem(text) {
    var reading = Logic.parseMeminfo(text)
    if (!reading) return
    root.ramUsedKb = reading.usedKb
    root.ramTotalKb = reading.totalKb
  }

  function applyAmdGpu(card, text) {
    if (root.gpuBackend === "amdgpu") return
    root.amdCard = card
    root.gpuBackend = "amdgpu"
    root.gpuPct = Logic.parsePercent(text)
  }

  function applyNvidiaPresent(text) {
    if (root.gpuBackend !== "") return
    if (String(text || "").indexOf("NVRM") === -1) return
    root.gpuBackend = "nvidia"
    refresh()
  }

  function applyNvidia(text) {
    var reading = Logic.parseNvidia(text)
    if (!reading) return
    root.gpuPct = reading.util
    root.vramUsedMib = reading.usedMib
    root.vramTotalMib = reading.totalMib
  }

  Component.onCompleted: {
    cpuFile.reload()
    memFile.reload()

    // The GPU cannot be listed from QML, so the four DRM cards that a machine
    // can plausibly carry are probed: gpu_busy_percent exists only on amdgpu.
    amdProbe0.reload()
    amdProbe1.reload()
    amdProbe2.reload()
    amdProbe3.reload()
    nvidiaProbe.reload()
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  FileView {
    id: cpuFile
    path: "/proc/stat"
    printErrors: false
    onLoaded: root.applyCpu(text())
  }

  FileView {
    id: memFile
    path: "/proc/meminfo"
    printErrors: false
    onLoaded: root.applyMem(text())
  }

  FileView {
    id: gpuFile
    path: root.amd ? root.amdBase + "/gpu_busy_percent" : "/dev/null"
    printErrors: false
    onLoaded: if (root.amd) root.gpuPct = Logic.parsePercent(text())
  }

  FileView {
    id: vramUsedFile
    path: root.amd && root.wantsVram ? root.amdBase + "/mem_info_vram_used" : "/dev/null"
    printErrors: false
    onLoaded: {
      if (!root.amd) return
      var bytes = Logic.parseBytes(text())
      root.vramUsedMib = bytes >= 0 ? bytes / 1048576 : -1
    }
  }

  FileView {
    id: vramTotalFile
    path: root.amd && root.wantsVram ? root.amdBase + "/mem_info_vram_total" : "/dev/null"
    printErrors: false
    onLoaded: {
      if (!root.amd) return
      var bytes = Logic.parseBytes(text())
      root.vramTotalMib = bytes > 0 ? bytes / 1048576 : -1
    }
  }

  // The first probe to answer decides. An AMD card keeps the lead over a
  // hybrid NVIDIA probe because its readings need no subprocess at all.
  FileView {
    id: amdProbe0
    path: "/sys/class/drm/card0/device/gpu_busy_percent"
    printErrors: false
    onLoaded: root.applyAmdGpu(0, text())
  }

  FileView {
    id: amdProbe1
    path: "/sys/class/drm/card1/device/gpu_busy_percent"
    printErrors: false
    onLoaded: root.applyAmdGpu(1, text())
  }

  FileView {
    id: amdProbe2
    path: "/sys/class/drm/card2/device/gpu_busy_percent"
    printErrors: false
    onLoaded: root.applyAmdGpu(2, text())
  }

  FileView {
    id: amdProbe3
    path: "/sys/class/drm/card3/device/gpu_busy_percent"
    printErrors: false
    onLoaded: root.applyAmdGpu(3, text())
  }

  FileView {
    id: nvidiaProbe
    path: "/proc/driver/nvidia/version"
    printErrors: false
    onLoaded: root.applyNvidiaPresent(text())
  }

  Process {
    id: nvidiaProc
    command: [
      "nvidia-smi",
      "--query-gpu=utilization.gpu,memory.used,memory.total",
      "--format=csv,noheader,nounits"
    ]
    onExited: function(exitCode) { if (exitCode !== 0) root.gpuPct = -1 }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyNvidia(text)
    }
    // nvidia-smi is the one thing here that can hang. A Process already
    // running can't be re-run, so give up on a stalled one and let the next
    // tick try again.
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: nvidiaStall
    interval: 5000
    running: nvidiaProc.running
    onTriggered: nvidiaProc.running = false
  }

  // --------------------------------------------------------------------- UI

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? root.verticalLabel : root.barLabel
    // A step above the smallest bar text, still under the bar's default body
    // size so the readings don't compete with the clock.
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    tooltipText: root.tooltip
    active: root.critical
    activeColor: root.bar ? root.bar.urgent : Commons.Color.urgent
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton && root.bar)
        root.bar.run("omarchy-launch-floating-terminal-with-presentation btop")
    }
  }
}
