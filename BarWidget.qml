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
  readonly property bool wantsVram: root.setting("vram", true) !== false
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

  // Each reading owns its warning state, so one saturated metric colours its
  // own pill without dragging the others along.
  readonly property bool cpuCritical: wantsCpu && Logic.isCritical(cpuPct)
  readonly property bool ramCritical: wantsRam && Logic.isCritical(ramPct)
  readonly property bool gpuCritical: wantsGpu && hasGpu && Logic.isCritical(gpuPct)
  readonly property bool vramCritical: wantsVram && hasVram && Logic.isCritical(vramPct)

  // ------------------------------------------------------------------ labels

  // One pill per reading, each carrying only its own value.
  readonly property string cpuText: "CPU " + Logic.percentText(cpuPct)
  readonly property string ramText: "RAM " + Logic.sizeText(Logic.kibToGib(ramUsedKb))
  readonly property string gpuText: hasGpu ? "GPU " + Logic.percentText(gpuPct) : ""
  readonly property string vramText: hasVram ? "VRAM " + Logic.sizeText(Logic.mibToGib(vramUsedMib)) : ""

  // The tooltips keep the fuller readings, where the total belongs.
  readonly property string cpuTip: "CPU  " + Logic.percentText(cpuPct)
  readonly property string ramTip: "RAM  " + Logic.detailText(Logic.kibToGib(ramUsedKb), Logic.kibToGib(ramTotalKb))
    + (ramPct >= 0 ? " (" + Math.round(ramPct) + "%)" : "")
  readonly property string gpuTip: "GPU  " + Logic.percentText(gpuPct)
  readonly property string vramTip: "VRAM  " + Logic.detailText(Logic.mibToGib(vramUsedMib), Logic.mibToGib(vramTotalMib))
    + (vramPct >= 0 ? " (" + Math.round(vramPct) + "%)" : "")

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

  implicitWidth: pills.implicitWidth
  implicitHeight: pills.implicitHeight

  // Each reading gets its own pill: a rounded, borderless capsule of
  // semi-transparent black under white text, so several of them read as
  // separate groups rather than one run of numbers. A reading past its limit
  // tints its own capsule red; the others stay neutral, and no pill touches
  // another's colour.
  Grid {
    id: pills
    anchors.centerIn: parent
    columns: root.vertical ? 1 : 4
    rowSpacing: 2
    columnSpacing: 3

    Pill { label: root.cpuText; tip: root.cpuTip; danger: root.cpuCritical; shown: root.wantsCpu }
    Pill { label: root.ramText; tip: root.ramTip; danger: root.ramCritical; shown: root.wantsRam }
    Pill { label: root.gpuText; tip: root.gpuTip; danger: root.gpuCritical; shown: root.wantsGpu && root.hasGpu }
    Pill { label: root.vramText; tip: root.vramTip; danger: root.vramCritical; shown: root.wantsVram && root.hasVram }
  }

  component Pill: Item {
    id: pill
    property string label: ""
    property string tip: ""
    property bool danger: false
    property bool shown: true

    visible: pill.shown && pill.label !== ""
    implicitWidth: pillButton.implicitWidth
    implicitHeight: pillButton.implicitHeight

    Rectangle {
      anchors.fill: parent
      anchors.topMargin: 3
      anchors.bottomMargin: 3
      radius: height / 2
      color: pill.danger ? Qt.rgba(0.78, 0.16, 0.16, 0.92) : Qt.rgba(0, 0, 0, 0.55)
      Behavior on color { ColorAnimation { duration: Style.duration(160) } }
    }

    WidgetButton {
      id: pillButton
      anchors.fill: parent
      bar: root.bar
      text: pill.label
      // A step above the smallest bar text, still under the bar's default body
      // size so the readings don't compete with the clock.
      fontSize: Style.font.bodySmall
      // White on the black capsule, in both states.
      foreground: "#ffffff"
      horizontalMargin: 5
      tooltipText: pill.tip
      onPressed: function(mouseButton) {
        if (mouseButton === Qt.LeftButton && root.bar)
          root.bar.run("omarchy-launch-floating-terminal-with-presentation btop")
      }
    }
  }
}
