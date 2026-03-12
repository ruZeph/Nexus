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
