# Performance — CPU, RAM, GPU and VRAM in the Omarchy bar

A small bar widget that shows system load at a glance:

```
CPU 7%  RAM 8.3/15G  GPU 16%
```

- **CPU** — busy share of all cores, sampled between refreshes (not the
  cumulative average since boot).
- **RAM** — used/total, with "used" taken from `MemAvailable` so reclaimable
  cache is not counted as pressure.
- **GPU** — utilisation from the card's own driver.
- **VRAM** — used/total video memory, off by default.

Hover for a labelled breakdown. The text turns to the theme's urgent colour at
90% or above. Left click opens `btop` in a floating terminal.

## How readings are taken

No helper scripts, no polling daemon: the widget reads the files the kernel
already maintains, every second.

| Metric | Source |
|---|---|
| CPU | `/proc/stat` (delta between samples) |
| RAM | `/proc/meminfo` (`MemTotal`, `MemAvailable`) |
| GPU (AMD) | `/sys/class/drm/card*/device/gpu_busy_percent` |
| VRAM (AMD) | `/sys/class/drm/card*/device/mem_info_vram_used` and `mem_info_vram_total` |
| GPU/VRAM (NVIDIA) | `nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total` |

The GPU backend is detected once at startup. AMD needs nothing installed; the
NVIDIA path only spawns `nvidia-smi` when the driver is loaded
(`/proc/driver/nvidia/version`). On a machine with no readable GPU the metric
is simply omitted.

## Settings

Configured per widget instance from the Omarchy bar settings (or inline in
`~/.config/omarchy/shell.json`):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `cpu` | boolean | `true` | Show CPU |
| `ram` | boolean | `true` | Show RAM |
| `gpu` | boolean | `true` | Show GPU |
| `vram` | boolean | `false` | Show VRAM |
| `interval` | integer (500–5000 ms) | `1000` | Refresh interval |

## Install and enable

```bash
omarchy plugin validate ~/.config/omarchy/plugins/nickmdrummer.perf
omarchy plugin enable nickmdrummer.perf --section right
```

Disable with `omarchy plugin disable nickmdrummer.perf`. Saving any file in the
plugin folder reloads it; `omarchy-shell shell rescanPlugins` forces a rescan if
a change does not apply.

## Notes

- The first CPU reading after the widget loads shows `—`: a percentage needs
  two samples.
- On a vertical bar the labels are dropped and the values stack, since the bar
  is only 28px wide; the tooltip still names each one.
- The bar is built per monitor, so each screen keeps its own timer. The reads
  are a few kilobytes from procfs and sysfs and never fork on AMD.

## Development

`Logic.js` holds the parsers and formatters and is free of QML, so it runs
under Node:

```bash
node --test tests/
```
