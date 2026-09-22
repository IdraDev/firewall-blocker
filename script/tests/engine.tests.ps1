# Engine self-check, no admin needed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File script\tests\engine.tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\engine.ps1')

$script:Fails = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "[ OK ] $Name" -ForegroundColor Green }
    else { Write-Host "[FAIL] $Name" -ForegroundColor Red; $script:Fails++ }
}
function Names($Targets) { ($Targets | ForEach-Object { $_.Rule.Name }) -join ',' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "fwb-test-$PID"
New-Item -ItemType Directory -Force (Join-Path $tmp 'sub') | Out-Null
try {
    Check 'empty path rejected' (-not (Resolve-FolderInput '  ').Ok)
    Check 'relative path rejected' (-not (Resolve-FolderInput 'games').Ok)
    Check 'drive-relative path rejected' (-not (Resolve-FolderInput 'C:').Ok)
    $r = Resolve-FolderInput "`"$tmp\`""
    Check 'quotes and trailing backslash stripped' ($r.Ok -and $r.Path -eq $tmp)
    Check 'drive root kept' ((Resolve-FolderInput 'C:\').Path -eq 'C:\')
    Check 'missing folder rejected' (-not (Resolve-FolderInput "$tmp\nope").Ok)
    Check 'missing folder allowed for unblock' ((Resolve-FolderInput "$tmp\nope" -AllowMissing).Ok)

    $a = Get-RuleNames 'C:\Games\Setup.exe'
    Check 'rule names ignore case' ($a.In -eq (Get-RuleNames 'c:\games\SETUP.EXE').In)
    Check 'rule name format' ($a.In -match '^FWB_[0-9a-f]{16}_In$' -and $a.Out -eq ($a.In -replace '_In$', '_Out'))
    Check 'same exe name in two folders never collides' ($a.In -ne (Get-RuleNames 'C:\Other\Setup.exe').In)

    foreach ($f in 'a.exe', 'sub\B.EXE', 'c.exe_disabled') { Set-Content -LiteralPath (Join-Path $tmp $f) 'x' }
    $found = @((Get-ExeFiles $tmp).Files | ForEach-Object Name | Sort-Object)
    Check 'scan: .exe only, recursive, any case' (($found -join ',') -eq 'a.exe,B.EXE')

    # stub the two firewall reads to exercise unblock matching and status
    function Get-RuleProgramMap {
        [pscustomobject]@{
            Rules    = @(
                [pscustomobject]@{ Name = 'r1'; Group = 'FirewallBlocker'; Direction = 'Inbound' }
                [pscustomobject]@{ Name = 'r2'; Group = 'FirewallBlocker'; Direction = 'Outbound' }
                [pscustomobject]@{ Name = 'r3'; Group = 'FirewallBlocker'; Direction = 'Inbound' })
            Programs = @{ r1 = 'C:\Games\a.exe'; r2 = 'C:\Games\a.exe'; r3 = 'C:\Gamesx\b.exe'; l1 = 'C:\Games\sub\c.exe' }
        }
    }
    function Get-LegacyRules { [pscustomobject]@{ Name = 'l1'; Group = ''; Direction = 'Outbound' } }

    $t = @(Get-UnblockTargets -Scope Directory -Directory 'C:\Games\')
    Check 'directory scope: subtree + legacy, sibling folder spared' ((Names $t) -eq 'r1,r2,l1')
    Check 'directory scope: legacy flagged' ((Names @($t | Where-Object Legacy)) -eq 'l1')
    Check 'files scope: exact path, any case' ((Names @(Get-UnblockTargets -Scope Files -Files 'c:\games\A.EXE')) -eq 'r1,r2')
    Check 'all scope: group rules only' ((Names @(Get-UnblockTargets -Scope All)) -eq 'r1,r2,r3')

    $d = Get-BlockedDirections
    Check 'status: both directions blocked' ($d['C:\GAMES\A.EXE'].Inbound -and $d['C:\GAMES\A.EXE'].Outbound)
    Check 'status: legacy rule counts' (-not $d['C:\Games\sub\c.exe'].Inbound -and $d['C:\Games\sub\c.exe'].Outbound)
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
if ($script:Fails) { exit 1 }
