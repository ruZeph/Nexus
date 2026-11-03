# Adobe Firewall Blocker

Part of the **[Nexus](../../README.md)** toolkit — `powershell/adobe-firewall-blocker/`.

Blocks Adobe telemetry/phone-home traffic with Windows Firewall rules, and can remove them
again. Batch files, no dependencies.

> **Credits:** these scripts are **not original work** — author
> [ph33nx](https://github.com/ph33nx). Included for utility; see the header of each file.

## Files

| File | Purpose |
| --- | --- |
| `block_adobe.bat` | adds outbound block rules for Adobe executables |
| `WinMasterBlocker.bat` | 🔥 WinMasterBlocker — broader Adobe blocking helper |

## Usage

Run **as Administrator** (firewall rule changes need it):

```bat
block_adobe.bat             :: block
block_adobe.bat -delete     :: unblock (removes the rules again)
```

## Notes

- Rules are outbound-block only; they do not stop local licensing/genuine-check services from
  starting, only from reaching the internet.
- Blocking too broadly can break Creative Cloud sign-in, updates and font sync. If an app starts
  failing to authenticate, run with `-delete` and re-add narrower rules.
- Review the `netsh advfirewall` lines in the batch files before running so you know exactly
  which executables and paths are targeted.
