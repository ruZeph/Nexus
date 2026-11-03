# Restic / Playnite Restore

Part of the **[Nexus](../../README.md)** toolkit — `powershell/restic-playnite-restore/`.

Restores Restic snapshots back onto a live Windows install where the backup contains paths
whose ACLs no longer resolve (different SID, reinstalled OS, moved profile). A plain
`robocopy` on top of such a restore often fails with `Access denied` even though the copy
"succeeded", because the files came back owned by whatever SID the backup was taken under.

## Pipeline

```
restic restore  ->  C:\ResticRestoreTemp      (staged, newest snapshot per plan)
Phase 1.5       ->  takeown + icacls on the staging tree   (so robocopy can read it)
robocopy        ->  real destination  (/COPY:DT /DCOPY:DT: data + timestamps, no ACLs)
Phase 1.5 again ->  takeown + icacls on the destination    (ownership back to you)
```

`robocopy` deliberately does **not** copy ACLs (`/COPY:DT`), which is exactly why the
destination needs its own unlock pass — otherwise apps can be blocked from opening restored
files even though the copy itself succeeded.

## Usage

```powershell
# self-elevates: asks "Relaunch script as Administrator now? (Y/N)"
powershell -ExecutionPolicy Bypass -File .\restore_and_copy.ps1

# plan the run without writing anything
powershell -ExecutionPolicy Bypass -File .\restore_and_copy.ps1 -DryRun

# non-interactive (CI / scheduled): password as a parameter
powershell -ExecutionPolicy Bypass -File .\restore_and_copy.ps1 -ResticPassword "<secret>"
```

The Restic password is prompted as a `SecureString` when not supplied and is only ever placed in
`$env:RESTIC_PASSWORD` for the child `restic` calls.

## Configuration

Edit the block near the top of `restore_and_copy.ps1`:

| Variable | Default |
| --- | --- |
| `$ResticExe` | `restic.exe` (must be on `PATH`) |
| `$Repository` | `D:\Backups\Restic` |
| `$RestoreRoot` | `C:\ResticRestoreTemp` |

Restore plans (which snapshot ID maps to which destination) are defined in the `$latestPlans`
hashtable in the same file. Transcript logs land in `$RestoreRoot\restore_log_<timestamp>.txt`.

`restore_config.example.json` is the companion config for the confirm-before-restore workflow
(`DataDir`, `LibraryDir`, `RestoreItems`, `BackupFile`, `CancelIfGameRunning`,
`ClosedWhenDone`). Copy it to `restore_config.json` and edit the paths — the real file is
git-ignored because it holds machine-specific absolute paths.

## Notes

- `takeown`/`icacls` on large trees is the slow part; the script prints both exit codes.
- Destination is validated before the robocopy pass; existing files are overwritten.
- Requires `restic.exe` and an unlocked repository; nothing here manages passwords for you.
