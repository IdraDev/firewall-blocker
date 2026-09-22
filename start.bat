@echo off
set "SCRIPT_PATH=%~dp0script\script.ps1"

net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo [!] Requesting administrator rights...
    powershell -NoProfile -Command "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Elevation declined.'; exit 1 }"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
if errorlevel 1 echo [!] Exited with error code %errorlevel%.
pause
