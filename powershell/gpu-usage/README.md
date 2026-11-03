# GPU Usage

Part of the **[Nexus](../../README.md)** toolkit — `powershell/gpu-usage/`.

Per-process VRAM report built from Windows performance counters — the same numbers Task
Manager shows, but aggregated per process instead of per graphics context, and printed as a
plain table you can paste into a bug report.

## How it works

- Reads `\GPU Process Memory(*)\Dedicated Usage` via `Get-Counter`.
- Extracts the `pid_<n>` part of each counter instance, groups by process, sums MB.
- Prints processes sorted by total VRAM, descending; noise below 0 MB is filtered out.

```
ProcessName                    PID   Total_VRAM_MB
---------                      ---   -------------
Cyberpunk2077.exe              14288         9214.5
firefox.exe                     9124         1183.25
```

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\gpu_usage.ps1
```

## Notes

- Requires WDDM 2.x counters (`GPU Process Memory`); if the counter set is missing the script
  prints "No active VRAM footprint detected…" instead of failing.
- Dedicated memory only — shared system-memory allocations are not included.
- Handy for finding the app that pins VRAM after a game is closed.
