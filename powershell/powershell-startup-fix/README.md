# PowerShell Startup Optimization

Part of the **[Nexus](../../README.md)** toolkit — `powershell/powershell-startup-fix/`.

Field notes and measurement tooling from cutting PowerShell 7 cold-start latency on this
machine: **7889 ms → 873 ms (≈89 % reduction)**.

The full write-up lives in **[POWERSHELL_STARTUP_OPTIMIZATION.md](POWERSHELL_STARTUP_OPTIMIZATION.md)**
— what the delay actually was, which components paid for it, and the changes that removed it.

## Files

| File | Purpose |
| --- | --- |
| `POWERSHELL_STARTUP_OPTIMIZATION.md` | analysis, before/after numbers, applied fixes |
| `test_latency.ps1` | repeatable cold-start timing harness used for those numbers |

## Usage

```powershell
# measure current startup cost
powershell -ExecutionPolicy Bypass -File .\test_latency.ps1
```

Run it with a fresh shell each time (a warm session measures nothing useful), and keep the same
profile/module set between runs so the comparison is honest.

## Notes

- Latency numbers are machine-specific; re-measure after driver or module changes rather than
  trusting the historical figures.
- The document records each change with its rollback, so anything here can be reverted.
