@echo off
set "SCRIPT_PATH=%~dp0script\script.ps1"

rem fltmc needs admin and, unlike net session, works with the Server service off
fltmc >nul 2>&1
if %errorlevel% NEQ 0 (
    echo [!] Requesting administrator rights...
    set "FWB_SELF=%~f0"
    powershell -NoProfile -Command "try { Start-Process -FilePath $env:FWB_SELF -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Elevation declined.'; exit 1 }"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
if errorlevel 1 echo [!] Exited with error code %errorlevel%.
pause
