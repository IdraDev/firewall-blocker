# 🔥 Firewall Blocker (v2.0)

A single-file PowerShell tool to block or unblock every `.exe` in a directory tree using Windows Firewall rules. Interactive terminal UI by default, scriptable CLI mode for automation. Built for sysadmins and power users who need control without the bloat.

---

## 🛠️ Features

- 🔐 Block all `.exe` files (inbound and outbound) in a target directory and its subdirectories.
- ♻️ Unblock by directory or remove everything the tool created — works even after the folder was deleted (orphaned rules are cleaned up too).
- 🖥️ Terminal UI: arrow-key menus, live progress bar, per-file audit view (`blocked / partial / none`), rules browser with pagination.
- 🤖 CLI mode for scripts and scheduled tasks: `-Action Block|Unblock|List|Rules` with `-Path`, `-NoConfirm`, `-DryRun`.
- 🔍 Dry-run everywhere: preview exactly what would be created or removed without touching the firewall (no admin needed).
- 🏷️ Rules are tagged with the `FirewallBlocker` group and named from a hash of the full path — two `setup.exe` in different folders never collide, and cleanup is exact.
- 🛡️ Safe by default: confirmation with file count before any change, real per-rule error reporting, meaningful exit codes.
- ✅ No third-party dependencies. Pure Windows PowerShell 5.1, works in Windows Terminal and legacy conhost.

---

## ⚙️ Requirements

- Windows 10/11 with Windows PowerShell 5.1 (preinstalled).
- Administrator privileges for blocking/unblocking (the script offers self-elevation; `List`, `Rules` and `-DryRun` work without).
- Sane judgment — this can break stuff.

---

## 🚀 Usage

### Option 1 — start.bat (recommended)

Double-click `start.bat`. It requests administrator rights and launches the interactive TUI.

### Option 2 — PowerShell (interactive TUI)

```powershell
powershell -ExecutionPolicy Bypass -File .\script\script.ps1
```

### Option 3 — CLI mode (automation)

```powershell
# Preview what would be blocked (no admin required)
.\script\script.ps1 -Action Block -Path "C:\Games" -DryRun

# Block everything under a directory (admin required)
.\script\script.ps1 -Action Block -Path "C:\Games"

# Show block status of every .exe under a directory
.\script\script.ps1 -Action List -Path "C:\Games"

# List all rules created by this tool
.\script\script.ps1 -Action Rules

# Remove rules for one directory (works even if the folder was deleted)
.\script\script.ps1 -Action Unblock -Path "C:\Games"

# Remove ALL rules created by this tool, no prompt
.\script\script.ps1 -Action Unblock -NoConfirm
```

**Exit codes:** `0` ok · `1` some operations failed · `2` not administrator · `3` bad arguments/path · `4` nothing to do · `5` firewall service not running.

> ℹ️ Rules created by v1.0 are recognized and removed by the directory-scoped Unblock.

---

## Contacts

www.idragraphics.com - info@idragraphics.com

- Idra: @idragraphics (Discord), idra.arts@gmail.com (Email) - **Code & UX Design**
