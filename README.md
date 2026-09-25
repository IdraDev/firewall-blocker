# 🔥 Firewall Blocker (v2.0)

Block or unblock every `.exe` in a directory tree with Windows Firewall rules. Use the desktop app, the interactive terminal UI, or the scriptable CLI: all three work on the same rules. Built for sysadmins and power users who need control without the bloat.

---

## 🛠️ Features

- 🔐 Block all `.exe` files (inbound and outbound) in a target directory and its subdirectories.
- ♻️ Unblock by file, by directory, or remove everything the tool created. Works even after the folder was deleted (orphaned rules are cleaned up too).
- 🪟 Desktop app in the Windows 11 style (Fluent, Mica, light/dark, English/Italian): scan a folder and see each exe's status, block or unblock with a preview of the exact rule count, browse every rule, spot orphans of deleted programs, stop a long run halfway, activity log. Reopens the last folder.
- 🖥️ Terminal UI: arrow-key menus, live progress bar, per-file audit view (`blocked / partial / none`), rules browser with pagination.
- 🤖 CLI mode for scripts and scheduled tasks: `-Action Block|Unblock|List|Rules` with `-Path`, `-NoConfirm`, `-DryRun`.
- 🔍 Dry-run everywhere in the script: preview exactly what would be created or removed without touching the firewall (no admin needed).
- 🏷️ Rules are tagged with the `FirewallBlocker` group and named from a hash of the full path: two `setup.exe` in different folders never collide, and cleanup is exact.
- 🕰️ Rules created by v1.0 (`Block <name> Inbound/Outbound`) count as blocked and are removed by Unblock.
- 🛡️ Safe by default: confirmation with file count before any bulk change, real per-rule error reporting, meaningful exit codes.
- ✅ The script has no third-party dependencies: pure Windows PowerShell 5.1, works in Windows Terminal and legacy conhost.

---

## ⚙️ Requirements

- Windows 10/11 with Windows PowerShell 5.1 (preinstalled). The app also needs WebView2, preinstalled on Windows 11.
- Administrator privileges for blocking/unblocking (the app and `start.bat` ask for them; `List`, `Rules` and `-DryRun` work without).
- Sane judgment: this can break stuff.

---

## 📦 Download

Grab the latest build from [Releases](https://github.com/IdraDev/Simple-Firewall-Blocker/releases):

- `FirewallBlocker-<version>-portable.exe`: desktop app, no install.
- `FirewallBlocker-<version>-script.zip`: `start.bat` plus the PowerShell script (TUI and CLI).

---

## 🚀 Usage

### Option 1: desktop app

Run `FirewallBlocker-<version>-portable.exe` and accept the administrator prompt. With nothing selected, Block, Unblock and Remove apply to everything the filter shows: filter the Rules page by a deleted folder's path to clean up its orphans.

### Option 2: start.bat

Double-click `start.bat`. It requests administrator rights and launches the interactive TUI.

### Option 3: PowerShell (interactive TUI)

```powershell
powershell -ExecutionPolicy Bypass -File .\script\script.ps1
```

### Option 4: CLI mode (automation)

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

---

## 🧱 Build from source

```powershell
# engine self-check, no admin needed
powershell -NoProfile -ExecutionPolicy Bypass -File .\script\tests\engine.tests.ps1

# desktop app (needs Bun, Rust and the Visual Studio C++ Build Tools): output in app\release
cd app
bun install
bun run typecheck
bun run test
bun run dist

# live development window (runs unelevated: blocking is disabled)
bun run dev
```

The app (Tauri) talks to Windows Firewall over COM (`app\src-tauri\src\fw.rs`). It names and matches rules exactly like `script\lib\engine.ps1`, by program path and direction, so the app and the script see each other's rules. The elevated round trip test needs an admin shell: `cargo test -- --ignored` in `app\src-tauri`.

---

## Contacts

www.idragraphics.com - info@idragraphics.com

- Idra: @idragraphics (Discord), idra.arts@gmail.com (Email) - **Code & UX Design**
