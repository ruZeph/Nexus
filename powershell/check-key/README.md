# Check Key — Alt+Space hotkey conflict finder

Part of the **[Nexus](../../README.md)** toolkit — `powershell/check-key/`.

Windows lets exactly one process own the **Alt+Space** system-menu hotkey. When some tray app
grabs it at startup, Alt+Space stops opening the window menu and nothing tells you why. This
script finds the culprit by elimination.

## How it works

1. `Add-Type` compiles a tiny P/Invoke wrapper around `RegisterHotKey` / `UnregisterHotKey`.
2. If Alt+Space can be registered right now, the hotkey is free — nothing to do.
3. Otherwise it walks the suspect list, **kills each candidate**, and re-tests the hotkey:
   the first kill that frees Alt+Space names the guilty process.

```
[FOUND] Rainmeter was holding Alt+Space!
```

If no suspect frees it, you get `[UNRESOLVED]` — the holder is a windowless/system process
that is not in the list.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\check_key.ps1
```

Edit the `$suspects` array at the top of the script to change the candidate list:

```powershell
$suspects = @("Rainmeter", "AutoHotkeyUX", "TwinkleTray", "HDSentinel",
              "MailClient", "HotKeysList", "avpui")
```

## Notes

- **It terminates processes** from that list. Save work in those apps first; close icons that
  are only running for the test (they restart from their own autostart).
- Re-run after each fix attempt: the result is only meaningful while you keep the same session.
- No admin rights required for the hotkey test; killing another user's process would be.
