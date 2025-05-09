# Check if the script is being run as administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  This script must be run as Administrator." -ForegroundColor Red
    exit
}

# Logging function (display logs in console with 2 spaces indentation)
function Log {
    param($message)
    Write-Host "  $message" -ForegroundColor Gray
}

# Menu
Write-Host " "
Write-Host "  FIREWALL BLOCKER Script" -ForegroundColor Green
Write-Host "  v1.0 - By IdraDev" -ForegroundColor Green
Write-Host " "
Write-Host "  You can easily block or unblock all .exe files" 
Write-Host "  in a specific directory and its subdirectories."
Write-Host " "
Write-Host "  ================================" -ForegroundColor DarkGray
Write-Host " "
Write-Host "  Menu:"
Write-Host " "
Write-Host "  (1) Block Firewall for all .exe files" -ForegroundColor Green
Write-Host "  (2) Remove Firewall rules for all .exe files" -ForegroundColor Red
Write-Host "  (3) List all .exe files in the directory and subdirectories" -ForegroundColor DarkGray
Write-Host " "
$choice = Read-Host "  Select your choice"

# Directory input
$directory = Read-Host "  Full Directory Path"

# Validate directory path
if (-not (Test-Path $directory)) {
    Write-Host "  (ERROR) The specified directory does not exist." -ForegroundColor Red
    exit
}

# Get all .exe files in the directory and subdirectories
$exeFiles = Get-ChildItem -Recurse -Path $directory -Filter *.exe -ErrorAction SilentlyContinue

# If no .exe files are found
if ($exeFiles.Count -eq 0) {
    Write-Host "  (WARNING) No .exe files found in the specified directory." -ForegroundColor Yellow
    exit
}

# Switch case for the actions based on the user's choice
switch ($choice) {
    "1" {
        # Block Firewall for all .exe files
        foreach ($file in $exeFiles) {
            $name = $file.Name
            $path = $file.FullName

            # Block all EXE files (even those with invalid signatures)
            $inboundRule = Get-NetFirewallRule -DisplayName "Block $name Inbound" -ErrorAction SilentlyContinue
            $outboundRule = Get-NetFirewallRule -DisplayName "Block $name Outbound" -ErrorAction SilentlyContinue

            if (-not $inboundRule) {
                New-NetFirewallRule -DisplayName "Block $name Inbound" -Direction Inbound -Program $path -Action Block -Profile Any -ErrorAction SilentlyContinue
                Write-Host "  Blocked INBOUND: $name" -ForegroundColor Green
                Write-Host " "
            }

            if (-not $outboundRule) {
                New-NetFirewallRule -DisplayName "Block $name Outbound" -Direction Outbound -Program $path -Action Block -Profile Any -ErrorAction SilentlyContinue
                Write-Host "  Blocked OUTBOUND: $name" -ForegroundColor Green
                Write-Host " "
            }
        }
    }

    "2" {
        # Remove Firewall rules for all .exe files
        foreach ($file in $exeFiles) {
            $name = $file.Name

            # Remove existing firewall rules
            Remove-NetFirewallRule -DisplayName "Block $name Inbound" -ErrorAction SilentlyContinue | Out-Null
            Remove-NetFirewallRule -DisplayName "Block $name Outbound" -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  Removed firewall rules for: $name" -ForegroundColor Yellow
        }
    }

    "3" {
        # List all .exe files in the directory and subdirectories
        Write-Host "  `n=== List of all .exe files ===" -ForegroundColor Green
        Write-Host " "
        foreach ($file in $exeFiles) {
            Write-Host "  Path: $($file.FullName)" -ForegroundColor White
        }
    }

    default {
        Write-Host "  Invalid choice." -ForegroundColor Red
    }
}

