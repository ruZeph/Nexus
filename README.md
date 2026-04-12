# Nexus

<p align="center">
  <img src="assets/nexus_transparent_hq.png" alt="NEXUS" />
</p>

A collection of personal automation scripts, utilities, and system tools for Windows.

[![License: PolyForm Noncommercial](https://img.shields.io/badge/License-NonCommercial-brightgreen)](#-license)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-0078D4)](#️-system-requirements)
[![Source Code](https://img.shields.io/badge/Source-Available_to_All-green)](#-license)
[![Python](https://img.shields.io/badge/Python-3.7+-3776ab)](https://python.org)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.0+-005a9e)](https://microsoft.com/powershell)

---

## 📋 Table of Contents

- [🛠️ Tools & Scripts](#️-tools--scripts)
- [📦 Installation](#-installation)
- [🚀 Usage](#-usage)
- [⚙️ System Requirements](#️-system-requirements)
- [❓ FAQ](#-faq)
- [📄 License](#-license)

---

## 🛠️ Tools & Scripts

### 🔧 Python Utilities (`/Python/`)

- **[Achievement Watcher Fix](Python/ACHWatcher_Cleanup_Fix/)**: Cleans and restores Achievement Watcher files.
- **[Cyberpunk DLC Copy](Python/Cyberpunk%20DLC%20Copy/)**: Batch copy and organize Cyberpunk 2077 DLCs.
- **[Excel Batch Delete](Python/Excel%20Batch%20Delete/)**: Bulk row removal for Excel spreadsheets.
- **[GDrive Image Hosting](Python/GDrive%20ImageHosting/)**: Batch convert Google Drive file links to direct, markdown-ready URLs.
- **[Ping Test](Python/Ping%20Test/)**: Multi-target network connectivity checker.

---

### 🔌 PowerShell Scripts (`/Powershell Scripts/`)

- **[Adobe Firewall Blocker](Powershell%20Scripts/Adobe%20Firewall%20Blocker/)**: Block Adobe telemetry via firewall rules. *(Note: These scripts are included for utility and are not original creations)*.
- **[PowerShell Startup Optimization](Powershell%20Scripts/powershell_startup_fix/)**: Latency testing and startup profiling tools.

---

### 📁 Sync Scripts (`/Sync Scripts/`)

- **[Run-RcloneJobs](Sync%20Scripts/)**: Automated backup orchestration with rate-limiting, job locking, and logging.

### Commands

```powershell
.\Run-RcloneJobs.ps1                      # Run all enabled jobs
.\Run-RcloneJobs.ps1 -JobName "office"    # Run specific job
.\Run-RcloneJobs.ps1 -DryRun              # Test without writing
```

---

## 📦 Installation

### Requirements

- **Windows 10/11**
- **Python 3.7+**
- **PowerShell 5.0+**
- **[rclone](https://rclone.org/install/)** (for backups)
- **[restic](https://restic.net/)** (for backups)

### Instructions

1. Clone the repository:

   ```bash
   git clone https://github.com/ruZeph/Nexus.git
   cd Nexus
   ```

2. Install Python dependencies:

   ```bash
   pip install pandas openpyxl
   ```

3. Set PowerShell Execution Policy (if needed):

   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

---

## 🚀 Usage

### Ping Test

```bash
python "Python/Ping Test/net_check.py"
```

### Convert Google Drive Links

```bash
python "Python/GDrive ImageHosting/get_hq_links.py"
```

### Run Backups

```powershell
cd "Sync Scripts"
.\Run-RcloneJobs.ps1
```

### Block Adobe Telemetry

```batch
"Powershell Scripts\Adobe Firewall Blocker\WinMasterBlocker.bat"
```

---

## ⚙️ System Requirements

| Component | Requirement |
| --------- | ----------- |
| OS | Windows 10/11 |
| Python | 3.7+ |
| PowerShell | 5.0+ |
| rclone | Latest (for backup scripts) |
| restic | Latest (for backup scripts) |
| Disk Space | ~500MB |
| RAM | 512MB+ (minimal) |

---

## ❓ FAQ

**Q: Can I use these scripts on macOS/Linux?**

A: Most tools are Windows-specific due to firewall, registry, and system dependencies. PowerShell 7.x scripts may work on Linux/macOS with modifications.

**Q: Is it safe to run these scripts?**

A: All scripts are tested in production. However, always run in dry-run mode first (`-DryRun`) especially for backup scripts.

**Q: How do I update the backup job configuration?**

A: Edit `Sync Scripts/backup-jobs.json` with your backup job specifications.

**Q: Can I contribute improvements?**

A: This is a personal toolkit, but if you create awesome improvements, you're welcome to share them back! Contributions remain under the same Noncommercial license.

---

## 📄 License

This project is licensed under the **PolyForm Noncommercial License 1.0.0**.

**Summary**:

- ✅ **Use for any non-commercial purpose** — personal projects, learning,
  non-profit work
- ✅ **Modify and improve** — adapt the code to your needs
- ✅ **Share and distribute** — pass it along to others
- ✅ **Attribution encouraged** — give credit to ruZeph if you'd like
- ❌ **No commercial use** — selling, monetizing, or using in commercial business
  products is prohibited

See [LICENSE](LICENSE) for complete terms.

---

## 🤝 Support

For questions or issues with individual tools, refer to their respective README files in each directory.

---

Made with ❤️ by ruZeph

Last Updated: April 2026
