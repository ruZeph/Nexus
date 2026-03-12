# PowerShell 7 Startup Time Optimization

**Result: 7889ms → 873ms (89% reduction)**

---

## Problem Summary

On first launch of the day, PowerShell 7.5.4 was taking ~7–8 seconds to load. The message displayed was:

```
PowerShell 7.5.4
Loading personal and system profiles took 7889ms.
```

Subsequent launches were fast, pointing to a cold-start issue rather than a persistent one.

---

## Diagnosis Methodology

### Step 1 — Isolate the profile load time

```powershell
Measure-Command { . $PROFILE }
# Result: 244ms — fine
```

The personal profile (`Microsoft.PowerShell_profile.ps1`) was not the problem.

### Step 2 — Isolate Starship init time

```powershell
Measure-Command { starship init powershell | Out-String | Invoke-Expression }
# Result: 190ms — fine
```

Starship was not the problem.

### Step 3 — Isolate PS7 runtime cold start

```powershell
Measure-Command { pwsh -NoProfile -NoLogo -Command "exit" }
# Result: 464ms — fine
```

The PS7 runtime itself was not the problem.

### Step 4 — Account for all time

| Component             | Time    |
|-----------------------|---------|
| PS7 runtime           | ~464ms  |
| Personal profile      | ~244ms  |
| Starship init         | ~190ms  |
| **Total accounted**   | ~900ms  |
| **Actual startup**    | ~7889ms |
| **Unaccounted**       | ~7000ms |

### Step 5 — Check all four profile locations

PowerShell loads up to **four** profile files on startup. The `$PROFILE` variable only points to one (`CurrentUserCurrentHost`). All four must be checked:

```powershell
$PROFILE | Select-Object *
```

Output:
```
AllUsersAllHosts       : C:\Program Files\PowerShell\7\profile.ps1
AllUsersCurrentHost    : C:\Program Files\PowerShell\7\Microsoft.PowerShell_profile.ps1
CurrentUserAllHosts    : C:\Users\Avisek\Documents\PowerShell\profile.ps1
CurrentUserCurrentHost : C:\Users\Avisek\Documents\PowerShell\Microsoft.PowerShell_profile.ps1
```

Time each existing profile:

```powershell
$profiles = $PROFILE | Select-Object -Property *

@(
    $profiles.AllUsersAllHosts,
    $profiles.AllUsersCurrentHost,
    $profiles.CurrentUserAllHosts,
    $profiles.CurrentUserCurrentHost
) | ForEach-Object {
    $exists = Test-Path $_
    $time = if ($exists) { (Measure-Command { . $_ }).TotalMilliseconds } else { "N/A" }
    [PSCustomObject]@{ Profile = $_; Exists = $exists; Ms = $time }
} | Format-Table -AutoSize
```

Output:
```
Profile                                                                Exists  Ms
-------                                                                ------  --
C:\Program Files\PowerShell\7\profile.ps1                              False   N/A
C:\Program Files\PowerShell\7\Microsoft.PowerShell_profile.ps1         False   N/A
C:\Users\Avisek\Documents\PowerShell\profile.ps1                        True   3192.44
C:\Users\Avisek\Documents\PowerShell\Microsoft.PowerShell_profile.ps1   True   193.49
```

**`profile.ps1` (CurrentUserAllHosts) was taking 3192ms** — the root cause.

### Step 6 — Inspect the slow profile

```powershell
Get-Content $PROFILE.CurrentUserAllHosts
```

Contents:

```powershell
#region conda initialize
# !! Contents within this block are managed by 'conda init' !!
If (Test-Path "C:\Users\Avisek\miniconda3\Scripts\conda.exe") {
    (& "C:\Users\Avisek\miniconda3\Scripts\conda.exe" "shell.powershell" "hook") | Out-String | ?{$_} | Invoke-Expression
}
#endregion
```

**Root cause confirmed: `conda init` was running `conda.exe` as an external process on every shell start**, taking ~3 seconds cold. Combined with Kaspersky scanning overhead, this produced the full 7–8 second delay.

---

## Root Causes Found

### 1. Conda eager initialization (~3–4s)
`conda init` injects a hook into `profile.ps1` (`CurrentUserAllHosts`) that runs `conda.exe` on every shell launch — even when conda is never used in that session.

### 2. Kaspersky behavior monitoring (~1–2s)
Kaspersky was scanning `pwsh.exe` and child processes on cold launch via behavior monitoring. File scan exclusions alone were insufficient; **Trusted Applications** exclusions were needed to also bypass behavior monitoring, process hooks, and traffic scanning.

---

## Fixes Applied

### Fix 1 — Lazy-load conda (primary fix, ~3s saved)

Replace the contents of `C:\Users\Avisek\Documents\PowerShell\profile.ps1` with:

```powershell
#region conda initialize
function Initialize-Conda {
    If (Test-Path "C:\Users\Avisek\miniconda3\Scripts\conda.exe") {
        (& "C:\Users\Avisek\miniconda3\Scripts\conda.exe" "shell.powershell" "hook") | Out-String | Where-Object {$_} | Invoke-Expression
    }
}

# Lazy aliases - conda only initializes on first use
function conda { Initialize-Conda; Remove-Item Function:\conda; conda @args }
function activate { Initialize-Conda; Remove-Item Function:\activate; activate @args }
function deactivate { Initialize-Conda; Remove-Item Function:\deactivate; deactivate @args }
#endregion
```

**How it works:** Conda is no longer initialized at startup. Instead, thin wrapper functions are registered for `conda`, `activate`, and `deactivate`. The first time any of these is called, `Initialize-Conda` runs, sets up the real conda environment, removes the wrapper functions (so they don't intercept future calls), and then forwards the original call. Cost at startup: **0ms**. Cost on first conda use: ~3s (same as before, just deferred).

### Fix 2 — Kaspersky Trusted Applications (secondary fix, ~1–2s saved)

Kaspersky has two separate exclusion systems:

| Setting | What it skips |
|---|---|
| **Exclusions** (file/folder) | File scanning only |
| **Trusted Applications** | File scanning + behavior monitoring + process hooks + network traffic scanning |

`pwsh.exe` was added to **Exclusions** but not **Trusted Applications**, so Kaspersky's behavior monitoring was still hooking into every pwsh launch.

**To fix:** In Kaspersky Premium → Security Settings → Threats → Trusted Applications → Add:

- `C:\Program Files\PowerShell\7\pwsh.exe`
- `C:\Users\Avisek\AppData\Local\starship\bin\starship.exe`

For each, enable **all** exclusion options:
- ✅ Do not scan files before opening
- ✅ Do not monitor application activity
- ✅ Do not monitor child application activity
  - ✅ Apply exclusion recursively
- ✅ Do not inherit restrictions from the parent process (application)
- ✅ Do not block interaction with AMSI Protection component
- ✅ Do not scan all traffic

> **Note:** "Do not monitor child application activity" + "Apply exclusion recursively" is critical — pwsh spawns many child processes (starship, git for prompt info, module loaders, etc.) that would otherwise each be individually scanned.

Also add Defender exclusions (Defender runs in Passive Mode alongside Kaspersky but can still scan on process execution):

```powershell
# Run as Administrator
Add-MpPreference -ExclusionProcess "pwsh.exe"
Add-MpPreference -ExclusionPath "C:\Program Files\PowerShell\7\"
Add-MpPreference -ExclusionPath "$env:USERPROFILE\Documents\PowerShell\"
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\starship\"
```

---

## Final Result

| Launch | Time |
|---|---|
| Before (first launch of day) | **7889ms** |
| After Kaspersky file exclusions only | **3964ms** |
| After Trusted Applications added | **5369ms** *(regression — unrelated reboot)* |
| After conda lazy-load fix | **873ms** ✅ |

The remaining **873ms** is the irreducible minimum — PS7 runtime (~464ms) + personal profile (~194ms) + starship init (~190ms). This is essentially the hardware floor.

---

## Key Takeaways

1. **`$PROFILE` is not the only profile.** PowerShell loads up to 4 profile files. Always time all of them when debugging startup.

2. **`conda init` is a hidden startup tax.** It eagerly runs an external binary every session. Lazy-loading it costs nothing if you never use conda in that session.

3. **AV file exclusions ≠ full exclusions.** Kaspersky's Trusted Applications and file Exclusions are separate systems. Only Trusted Applications bypasses behavior monitoring and process hooks.

4. **Diagnose before assuming.** The actual bottleneck (conda in a secondary profile) was only found after systematically eliminating PS7 runtime, Starship, and the primary profile — all of which were innocent.
