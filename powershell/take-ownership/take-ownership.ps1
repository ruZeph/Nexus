# take-ownership.ps1 - take ownership of a file or folder and hand it to the interactive user
# account, then grant full control to that account and to Administrators.
# Self-elevates via UAC. Files: takeown /f + icacls /setowner + icacls /grant /c /l
#                           Folders: takeown /r /d y + icacls /setowner + /grant /t /c /l /q
# Installed as the "Take ownership" context menu entry (HKCU\Software\Classes\*\shell\TakeOwnership).
# Remove with: remove-take-ownership.ps1 (in the same folder)

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    # account to grant full control to; passed in by the launcher as the interactive user
    [string]$User
)

$ErrorActionPreference = 'Continue'
$AdminSid = '*S-1-5-32-544'

# ---- argument quoting for CreateProcess / CRT parsing ----------------------
function Quote-Arg([string]$s) {
    if ($s -eq '') { return '""' }
    if ($s -notmatch '[\s"]') { return $s }
    # double backslashes that precede a quote or end the string, then wrap in quotes
    $s = $s -replace '(\\+)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

# ---- self-elevate ----------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Host 'No path was passed in.'
        Start-Sleep -Seconds 3
        exit 1
    }
    # remember who launched us - the elevated process may be a different admin account
    $whoAmI = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -Path {1} -User {2}' -f (Quote-Arg $PSCommandPath), (Quote-Arg $Path), (Quote-Arg $whoAmI)
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine | Out-Null
    }
    catch {
        # user declined the UAC prompt
    }
    exit 0
}

# ---- resolve target --------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Path)) {
    Write-Host 'No path was passed in.'
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
}
catch {
    Write-Host ('Cannot access: ' + $Path)
    Write-Host $_.Exception.Message
    Read-Host 'Press Enter to close' | Out-Null
    exit 1
}

$target = $item.FullName
if ($target -match '^[A-Za-z]:$') { $target = $target + '\' }

Write-Host ''
Write-Host ('Take ownership: ' + $target) -ForegroundColor Cyan
Write-Host ''

# a drive root means recursing the whole volume - make sure that is intended
if ($target -match '^[A-Za-z]:\\$') {
    Write-Host 'This is a drive root. Everything on the volume will be processed.' -ForegroundColor Yellow
    $answer = Read-Host 'Type YES to continue'
    if ($answer -ne 'YES') {
        Write-Host 'Cancelled.'
        Start-Sleep -Milliseconds 800
        exit 1
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()

# owner becomes the interactive user account; both it and Administrators get full control
if ([string]::IsNullOrWhiteSpace($User)) {
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
}
$grantAdmins = $AdminSid + ':F'
$grantUser = $User + ':F'
Write-Host ('New owner: ' + $User)
Write-Host 'Full control: that account + Administrators'
Write-Host ''

if ($item.PSIsContainer) {
    Write-Host 'Folder - recursing (takeown /r, icacls /t). This can take a while...'
    takeown /f $target /r /d y 2>&1 | Out-Null
    $code1 = $LASTEXITCODE
    $scope = @('/t', '/c', '/l', '/q')
}
else {
    Write-Host 'File'
    takeown /f $target 2>&1 | Out-Null
    $code1 = $LASTEXITCODE
    $scope = @('/c', '/l')
}

# takeown gives ownership to Administrators - hand it to the user instead
icacls $target /setowner $User @scope 2>&1 | Out-Null
$code2 = $LASTEXITCODE

# explicit full control for Administrators and for the user account
icacls $target /grant $grantAdmins $grantUser @scope 2>&1 | Out-Null
$code3 = $LASTEXITCODE

$sw.Stop()
Write-Host ''
Write-Host ('Finished in {0:N1}s  (takeown {1}, setowner {2}, grant {3})' -f $sw.Elapsed.TotalSeconds, $code1, $code2, $code3)

if ($code1 -eq 0 -and $code2 -eq 0 -and $code3 -eq 0) {
    Write-Host ('Owner: ' + $User + '. Full control: ' + $User + ' + Administrators') -ForegroundColor Green
    Start-Sleep -Milliseconds 2000
    exit 0
}

Write-Host 'Completed with errors - see messages above.' -ForegroundColor Yellow
Read-Host 'Press Enter to close' | Out-Null
exit 1
