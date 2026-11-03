# Changelog

All notable changes to this repository are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project does not
publish versioned releases, so entries are grouped by date.

## Unreleased

### Added

- **`powershell/take-ownership/`** — right-click **Take ownership** entry for files, folders,
  drives and folder backgrounds (Directory Opus + Explorer). Self-elevates via UAC, then
  `takeown` → `icacls /setowner` (ownership to the interactive user) → `icacls /grant`
  (full control for that account and Administrators). Includes `install-` / `remove-` scripts,
  CRT-safe path quoting, and a drive-root "type YES" guard.
- `CONTRIBUTING.md` — layout, naming, README and commit conventions.
- `CHANGELOG.md` — this file.
- `.gitattributes` — pins line endings so PowerShell files cannot be mangled by a clone.
- Per-tool `README.md` for every tool folder that lacked one: `check-key`,
  `cleanup-env-paths`, `docker-remove`, `gpu-usage`, `sync-time`, `sys-info`,
  `restic-playnite-restore`, `adobe-firewall-blocker`, `powershell-startup-fix`,
  `take-ownership`, `achwatcher-cleanup-fix`, `cyberpunk-dlc-copy`, `excel-batch-delete`,
  `ping-test`, `base64-encoder`.

### Changed

- **Repository layout normalised** (breaking for bookmarks and any local scripts holding the old
  paths):

  | Before | After |
  | --- | --- |
  | `Powershell Scripts/` | `powershell/` |
  | `Python/` | `python/` |
  | `Sync Scripts/` | `sync/` |
  | `Powershell Scripts/AMD Radeon Overlay Fix/` | `powershell/amd-radeon-overlay-fix/` |
  | `Powershell Scripts/Take Ownership/` | `powershell/take-ownership/` |
  | `Powershell Scripts/Restic DB Restore/` | `powershell/restic-playnite-restore/` |
  | `Powershell Scripts/powershell_startup_fix/` | `powershell/powershell-startup-fix/` |
  | `Powershell Scripts/Adobe Firewall Blocker/` | `powershell/adobe-firewall-blocker/` |
  | `Python/ACHWatcher_Cleanup_Fix/` | `python/achwatcher-cleanup-fix/` |
  | `Python/Cyberpunk DLC Copy/` | `python/cyberpunk-dlc-copy/` |
  | `Python/Excel Batch Delete/` | `python/excel-batch-delete/` |
  | `Python/GDrive ImageHosting/` | `python/gdrive-image-hosting/` |
  | `Python/Ping Test/` | `python/ping-test/` |
  | `Sync Scripts/Backrest Trigger/` | `sync/backrest-trigger/` |
  | `Sync Scripts/RClone Sync/` | `sync/rclone-sync/` |
  | `node/base64encoder.js` | `node/base64-encoder/base64encoder.js` |

- Loose scripts at the PowerShell root now have their own folders (`check-key`,
  `cleanup-env-paths`, `docker-remove`, `gpu-usage`, `sync-time`, `sys-info`).
- `README.md` rewritten: layout tree, per-category tool tables, quick-start commands, honest
  requirement notes.
- `register-guard.ps1` (AMD overlay) resolves its tool root from `$PSScriptRoot` instead of a
  hardcoded `C:\Custom User\Nexus\...` path, so the repo can be cloned anywhere.
- All documentation, scripts and task-registration commands now reference the new paths.

### Fixed

- `Powershell Scripts/AMD Radeon Overlay Fix/scripts/overlay-guard.ps1` had been deleted from the
  working tree by accident; restored — it is the active guard referenced by `register-guard.ps1`,
  the RUNBOOK and the tool README.

### Security

- `node/base64-encoder/base64encoder.js` contained a live-looking credential block (client ID,
  client secret, token/API URLs) in a public repository. The values are replaced with
  placeholders and the README documents the environment-variable pattern. **The credential must
  be rotated — it remains in the git history.**

### Removed

- `powershell/gpu-usage/nvidia_vram_log.csv` — generated VRAM sample output, now git-ignored.
- `restore_config.json` — machine-specific paths; replaced by
  `powershell/restic-playnite-restore/restore_config.example.json` and git-ignored.
