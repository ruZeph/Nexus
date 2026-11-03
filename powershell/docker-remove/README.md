# Docker Remove

Part of the **[Nexus](../../README.md)** toolkit — `powershell/docker-remove/`.

Full teardown of Docker Desktop on Windows when the uninstaller leaves pieces behind and a
reinstall fails with "Docker Desktop is already installed" or a stale service entry.

## What it removes

1. Stops `com.docker.service` and force-kills `Docker Desktop`.
2. Deletes the install and data directories:

| Path |
| --- |
| `C:\Program Files\Docker` |
| `%PROGRAMDATA%\DockerDesktop` |
| `%APPDATA%\Docker` |
| `%LOCALAPPDATA%\Docker` |
| `%LOCALAPPDATA%\DockerDesktopInstallers` |

3. Deletes the leftover `com.docker.service` service entry (`sc.exe delete`).

## Usage

```powershell
# run as Administrator
powershell -ExecutionPolicy Bypass -File .\docker_remove.ps1
```

Reboot before reinstalling.

## Notes

- **Destructive and unrecoverable.** Images, containers, volumes, settings and WSL distro data
  tied to Docker go with those folders. Back up anything you need first.
- Hyper-V / WSL features and the `docker` CLI on `PATH` are left alone; this only removes
  Docker Desktop itself.
