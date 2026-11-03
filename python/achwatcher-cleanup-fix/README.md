# Achievement Watcher Fix

Part of the **[Nexus](../../README.md)** toolkit — `python/achwatcher-cleanup-fix/`.

Cleans out the emulator/DRM save and cache folders that Achievement Watcher and its companion
tools leave behind, so a fresh restore or a new container starts from empty state instead of
inheriting stale achievements and dummy saves.

## Targets

`TARGET_FOLDERS` at the top of the script:

```python
%PUBLIC%\Documents\Steam\CODEX        %APPDATA%\GSE Saves
%PUBLIC%\Documents\Steam\RUNE         %APPDATA%\CreamAPI
%APPDATA%\Goldberg SteamEmu Saves     %APPDATA%\Steam\CODEX
%APPDATA%\EMPRESS                     %PROGRAMDATA%\Steam
%PUBLIC%\EMPRESS                      %DOCUMENTS%\SkidRow
%LOCALAPPDATA%\SKIDROW                %APPDATA%\SmartSteamEmu
```

`%DOCUMENTS%` is resolved manually (to `~\.Documents`), since `os.path.expandvars` does not
expand it.

## Usage

**Dry run is the default** — it prints what it would delete and writes a log without touching
the disk:

```bat
python ACHWatcher_Folder_Clean.py
```

Interactive prompts then decide the real behaviour:

```
Run in ACTUAL DELETE mode? (y/n - default is Dry Run): n
1. Delete entire folders
2. Delete only contents (keep main folder)
Enter choice [1/2]: 2
```

Non-interactive variant:

```bat
python ACHWatcher_Folder_Clean.py --force-delete
```

A `cleanup_log_<timestamp>.txt` is written next to the script in every mode.

## Notes

- `1` removes the folders themselves; `2` empties them and keeps the folder, optionally
  recreating it afterwards (the script asks).
- Missing targets are reported as `[NOT FOUND]`, not created.
- Only run this with the accompanying emulator/game closed.
