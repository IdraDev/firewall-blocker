@echo off

set "SCRIPT_PATH=%~dp0/script/script.ps1"

net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo [!] Starting Firewall Blocker...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
pause