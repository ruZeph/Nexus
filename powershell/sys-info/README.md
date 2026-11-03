# Sys Info

Part of the **[Nexus](../../README.md)** toolkit — `powershell/sys-info/`.

One-shot hardware/software snapshot written to a timestamped text file on your Desktop. Built
for "attach your specs" forum posts and for comparing a machine before/after a BIOS or driver
change, without opening six different utilities.

## Output

`%USERPROFILE%\Desktop\sys_info_<yyyyMMdd_HHmmss>.txt`, captured through `Start-Transcript`:

| Section | Contents |
| --- | --- |
| `WINDOWS` | edition, build, install date, uptime |
| `SYSTEM` | manufacturer, model, system type |
| `CPU` | name, cores/threads, clock |
| `BIOS` / `MOTHERBOARD` | vendor, version, board model |
| `MEMORY` | installed modules, speed, per-slot layout |
| `GPU` | adapters and driver versions |
| `DISKS` | physical disks, partitions, free space |
| `ACTIVE POWER SCHEME`, `PROCESSOR POWER SETTINGS`, `POWER CAPABILITIES` | `powercfg` data |
| `VBS / HYPERVISOR` | virtualization-based security state |
| `WINDOWS FEATURES` | enabled optional features |
| `NETWORK ADAPTERS` | adapters, link speed, IPs |
| `RUNNING PROCESSES (Top 25 by CPU)` | busiest processes |
| `RUNNING SERVICES (Top 40)` | services and states |

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\sys_info.ps1
```

## Notes

- Read-only; nothing on the system is modified beyond writing the report file.
- Some sections (`powercfg`, VBS, MSInfo-style queries) report "not available" when the script
  is not elevated — run as Administrator for a complete file.
- The transcript header contains hostname/user; scrub before posting publicly.
