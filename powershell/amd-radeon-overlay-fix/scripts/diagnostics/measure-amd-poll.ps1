# measure-amd-poll.ps1 - 60s: how often does AMD Software spawn visible-console processes?
$ErrorActionPreference = 'SilentlyContinue'
$seen = @{}
foreach ($p in Get-Process) { $seen[[int]$p.Id] = $true }

$rows = New-Object System.Collections.Generic.List[object]
$t0 = Get-Date
while (((Get-Date) - $t0).TotalSeconds -lt 60) {
    foreach ($p in Get-Process) {
        $id = [int]$p.Id
        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
            $ppid = 0; $cmd = ''
            if ($ci) { $ppid = [int]$ci.ParentProcessId; $cmd = [string]$ci.CommandLine }
            $pn = (Get-Process -Id $ppid -ErrorAction SilentlyContinue).ProcessName
            # only care about things that can own a console window
            if ($p.ProcessName -match '^(powershell|pwsh|cmd|conhost|clinfo|wscript|cscript|bash|wsl)$') {
                $rows.Add([PSCustomObject]@{ T=(Get-Date).ToString('HH:mm:ss'); N=$p.ProcessName; P=$id; Par=$pn; Cmd=($cmd -replace '\s+',' ') })
            }
        }
    }
    Start-Sleep -Milliseconds 200
}

Write-Host ("console-capable process births in 60s: " + $rows.Count)
Write-Host ""
Write-Host "===== grouped by name + parent ====="
$rows | Group-Object N,Par | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,-40} {1,4}" -f $_.Name, $_.Count) }
Write-Host ""
Write-Host "===== chronological ====="
$rows | ForEach-Object { Write-Host ("  {0}  {1,-12} pid={2,-6} parent={3,-18} {4}" -f $_.T,$_.N,$_.P,$_.Par,$_.Cmd.Substring(0,[Math]::Min(110,$_.Cmd.Length))) }
