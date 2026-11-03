# Cleanup User PATH

Part of the **[Nexus](../../README.md)** toolkit — `powershell/cleanup-env-paths/`.

Audits your **User** `PATH` variable, reports every redundant or dead entry with a reason, and
only writes the cleaned value after you explicitly confirm. Windows caps the User PATH at 2047
characters, so dead entries are not just untidy — they can silently truncate new ones.

## What it flags

| Type | Reason |
| --- | --- |
| `Duplicate` | path already appears earlier in the variable |
| `Dead/Invalid` | directory no longer exists (uninstalled or moved software) |
| `Dead/Invalid` | entry still contains unexpanded `%VARS%`, so it cannot be verified safely |

Blank entries (e.g. a trailing `;`) are dropped silently.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup_env_paths.ps1
```

Output:

```
=== PATH OPTIMIZATION REPORT ===
Original Length : 1893 characters
New Length      : 1244 characters (Limit is 2047)
--------------------------------
[-] Path  : C:\Program Files\OldApp\bin
    Type  : Dead/Invalid
    Reason: The directory does not exist on your hard drive. ...
--------------------------------
Do you want to apply these changes to your User PATH? (Y/N)
```

Anything other than `Y`/`y` aborts without touching the environment.

## Notes

- User scope only — the machine-wide `PATH` is not modified, so no admin rights are needed.
- Restart terminals/IDEs afterwards; running processes keep their inherited copy.
- Nothing is logged to disk, so copy the report before answering if you want a record.
