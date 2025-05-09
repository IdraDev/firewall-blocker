@echo off
:: Avvia il prompt dei comandi come amministratore ed esegue lo script PowerShell

:: Imposta il percorso assoluto dello script PowerShell
set "SCRIPT_PATH=%~dp0/script/script.ps1"

:: Controlla se è amministratore
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo [!] Starting Firewall Blocker...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Esegui lo script PowerShell
powershell -ExecutionPolicy Bypass -File "%SCRIPT_PATH%"
pause
