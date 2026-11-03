# Take Ownership

Part of the **[Nexus](../../README.md)** toolkit — `powershell/take-ownership/`.

Adds a **Take ownership** entry to the right-click menu for files, folders, drives and folder
backgrounds. It works in **Directory Opus** and in **Explorer** alike, because the entry is a
per-user shell verb (`HKCU\Software\Classes\…`), not an app-specific bolt-on.

## What it does

1. Relaunches itself elevated through UAC (`powershell.exe -Verb RunAs`), passing along the
   identity of the account that clicked — so a borrowed admin account does not get the ACE.
2. `takeown` — takes ownership. Folders recurse (`/r /d y`), files do not.
3. `icacls /setowner` — hands ownership to **your account**. `takeown` gives it to
   *Administrators*, which would leave you needing elevation for every later write.
4. `icacls /grant` — explicit **Full control** for your account **and** Administrators.
   Existing ACEs and inheritance are left untouched.

Drive roots ask `Type YES to continue` first: `/r` over a whole volume is expensive.

## Usage

Right-click a file, folder or drive → **Take ownership**. No arguments, no console setup.
Multi-selection runs the entry once per item (`MultiSelectModel=Player`).

Console output:

```
Take ownership: Z:\
New owner: MACHINE\User
Full control: that account + Administrators
Folder - recursing (takeown /r, icacls /t). This can take a while...
Finished in 3.4s  (takeown 0, setowner 0, grant 0)
Owner: MACHINE\User. Full control: MACHINE\User + Administrators
```

Errors keep the window open (`Press Enter to close`); success closes after ~2 s.

## Install / uninstall

```powershell
# register the menu entries (per-user, no admin needed)
powershell -ExecutionPolicy Bypass -File .\install-take-ownership.ps1

# remove them again
powershell -ExecutionPolicy Bypass -File .\remove-take-ownership.ps1
```

Registered keys:

| Key | Shows on |
| --- | --- |
| `HKCU\Software\Classes\*\shell\TakeOwnership` | files |
| `HKCU\Software\Classes\Directory\shell\TakeOwnership` | folders |
| `HKCU\Software\Classes\Drive\shell\TakeOwnership` | drives |
| `HKCU\Software\Classes\Directory\Background\shell\TakeOwnership` | empty space inside a folder (`%V`) |

Restart Explorer (or the Lister) if the entry does not appear immediately.

## Files

| File | Purpose |
| --- | --- |
| `take-ownership.ps1` | worker: quoting, self-elevation, `takeown` + `icacls` |
| `install-take-ownership.ps1` | writes the four registry verbs |
| `remove-take-ownership.ps1` | deletes those four registry keys |

## Notes

- Path quoting is CRT-safe: drive roots (`Z:\`), spaces and apostrophes survive the elevation hop.
- Ownership is not a permission reset. To return a tree to inherited defaults use
  `Properties → Security → Advanced → Enable inheritance` afterwards.
