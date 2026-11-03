# Sync Time

Part of the **[Nexus](../../README.md)** toolkit — `powershell/sync-time/`.

Rebuilds the Windows Time service from scratch and forces a resync against public NTP
servers. Use it when the clock drifts, `w32tm /resync` refuses to run, or the service is stuck
in `Start Pending` after a hardware change.

## What it does

```bat
net stop w32time
w32tm /unregister      # wipe the service registration
w32tm /register        # recreate it
net start w32time
w32tm /config /manualpeerlist:"time.google.com,time.cloudflare.com,in.pool.ntp.org" /syncfromflags:manual /update
w32tm /resync /force
pause
```

## Usage

Run **as Administrator** (the stop/register calls need it):

```bat
sync_time.bat
```

Expect a short `The following error occurred: The service has not been started` window while
the service is rebuilt — that is normal for the first `net stop`.

## Notes

- Uses `time.google.com`, `time.cloudflare.com` and `in.pool.ntp.org`; edit the peer list in the
  file if you prefer your ISP's or a domain controller's NTP source.
- The `pause` at the end keeps the window open so you can read `w32tm /resync` output.
- Afterwards check with `w32tm /query /status`.
