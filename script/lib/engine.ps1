# Firewall rule engine, no UI. Dot-sourced by script.ps1 and by the desktop app.

$script:Group = 'FirewallBlocker'

#region Helpers

# Shared path sanitation pipeline (also used by CLI mode). -AllowMissing
# skips the folder-exists check so Unblock can target deleted directories
# (orphaned rules match by the rule's stored program path, not the disk).
function Resolve-FolderInput {
    param([string]$Raw, [switch]$AllowMissing)
    $p = $Raw.Trim().Trim('"').Trim("'")
    if ($p -eq '') {
        return [pscustomobject]@{ Ok = $false; Path = $null; Error = 'empty path' }
    }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    $rooted = $false
    try { $rooted = [System.IO.Path]::IsPathRooted($p) } catch { }
    # IsPathRooted alone also accepts drive-relative 'C:' and root-relative
    # '\foo', which resolve against the current directory/drive; require a
    # fully qualified drive path or UNC path.
    if (-not $rooted -or $p -notmatch '^([A-Za-z]:\\|\\\\)') {
        return [pscustomobject]@{ Ok = $false; Path = $null
            Error = "not an absolute path: $p (relative paths are unsafe after elevation; use e.g. C:\folder)" }
    }
    if ($p.Length -gt 3 -and $p.EndsWith('\')) { $p = $p.TrimEnd('\') }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) {
        if (Test-Path -LiteralPath $p) {
            return [pscustomobject]@{ Ok = $false; Path = $null; Error = "not a folder: $p" }
        }
        if (-not $AllowMissing) {
            return [pscustomobject]@{ Ok = $false; Path = $null; Error = "folder not found: $p" }
        }
    }
    return [pscustomobject]@{ Ok = $true; Path = $p; Error = $null }
}

function Get-PathHash {
    param([string]$FullPath)
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($FullPath.ToLowerInvariant()))
    # 8 bytes (16 hex chars): 4 bytes gave ~1% collision odds at ~9k files
    -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
}

function Get-RuleNames {
    param([string]$FullPath)
    $h = Get-PathHash $FullPath
    [pscustomobject]@{ Hash = $h; In = "FWB_${h}_In"; Out = "FWB_${h}_Out" }
}

function Get-RuleKey {
    param([string]$Program, [string]$Direction)
    "$Program|$Direction"
}

# 'active' | 'paused' (group rule disabled) | 'none', against Get-FwbRules
function Get-RuleState {
    param([hashtable]$Existing, [string]$Program, [string]$Direction)
    $r = $Existing[(Get-RuleKey $Program $Direction)]
    if (-not $r) { return 'none' }
    if ([string]$r.Enabled -eq 'True') { return 'active' }
    return 'paused'
}

#endregion

#region Engine (no UI in this region)

# Enumerate .exe files. -File excludes directories named *.exe; the extension
# post-filter kills 8.3 short-name false matches (e.g. app.exe_disabled).
function Get-ExeFiles {
    param([string]$Directory, [scriptblock]$OnTick)
    $errs = @()
    $files = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -Filter *.exe `
                 -ErrorAction SilentlyContinue -ErrorVariable +errs |
               ForEach-Object { if ($OnTick) { & $OnTick $_ }; $_ } |
               Where-Object { $_.Extension -eq '.exe' })
    return [pscustomobject]@{ Files = $files; ErrorCount = $errs.Count }
}

# All rules created by this tool, keyed on Get-RuleKey (program + direction,
# case-insensitive), not on the rule name: the desktop app creates rules over
# COM, which assigns GUID names.
function Get-FwbRules {
    $map = Get-RuleProgramMap
    $index = @{}
    foreach ($r in $map.Rules) {
        $prog = $map.Programs[$r.Name]
        $k = Get-RuleKey $prog ([string]$r.Direction)
        # an enabled duplicate wins, so the direction reads as active
        if ($prog -and (-not $index.ContainsKey($k) -or [string]$r.Enabled -eq 'True')) { $index[$k] = $r }
    }
    return $index
}

function Get-GroupRuleCount {
    return @(Get-NetFirewallRule -Group $script:Group -ErrorAction SilentlyContinue).Count
}

# Group rules plus a Name -> program index over every application filter.
# One -All query: piping rules into Get-NetFirewallApplicationFilter costs
# ~140 ms per rule.
function Get-RuleProgramMap {
    $rules = @(Get-NetFirewallRule -Group $script:Group -ErrorAction SilentlyContinue)
    $programs = @{}
    foreach ($f in @(Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue)) {
        $programs[$f.InstanceID] = $f.Program
    }
    return [pscustomobject]@{ Rules = $rules; Programs = $programs }
}

# Creates block rules. Progress unit = one rule op (files x 2).
# OnProgress is called for every op as: & $OnProgress $op $total $resultObject
function Invoke-BlockRules {
    param(
        [object[]]$Files,
        [hashtable]$Existing,
        [bool]$DryRun,
        [scriptblock]$OnProgress
    )
    $results = New-Object System.Collections.ArrayList
    $total = $Files.Count * 2
    $op = 0
    foreach ($file in $Files) {
        $hash = Get-PathHash $file.FullName
        foreach ($direction in @('Inbound', 'Outbound')) {
            $op++
            if ($direction -eq 'Inbound') { $dirShort = 'In' } else { $dirShort = 'Out' }
            $name = "FWB_${hash}_$dirShort"
            $state = Get-RuleState $Existing $file.FullName $direction
            if ($state -eq 'active') {
                $outcome = 'Skipped'; $detail = 'already exists'
            } elseif ($state -eq 'paused' -and $DryRun) {
                $outcome = 'DryRun'; $detail = 'would enable'
            } elseif ($state -eq 'paused') {
                try {
                    $Existing[(Get-RuleKey $file.FullName $direction)] | Enable-NetFirewallRule -ErrorAction Stop
                    $outcome = 'Enabled'; $detail = ''
                } catch {
                    $outcome = 'Failed'; $detail = $_.Exception.Message
                }
            } elseif ($DryRun) {
                $outcome = 'DryRun'; $detail = 'would create'
            } else {
                try {
                    New-NetFirewallRule -Name $name `
                        -DisplayName "FirewallBlocker: $($file.Name) [$hash] $dirShort" `
                        -Description $file.FullName -Group $script:Group `
                        -Direction $direction -Program $file.FullName `
                        -Action Block -Profile Any -Enabled True `
                        -ErrorAction Stop | Out-Null
                    $outcome = 'Created'; $detail = ''
                } catch {
                    $outcome = 'Failed'; $detail = $_.Exception.Message
                }
            }
            $r = [pscustomobject]@{
                File = $file.FullName; Name = $file.Name
                Direction = $direction; Outcome = $outcome; Detail = $detail
            }
            [void]$results.Add($r)
            if ($OnProgress) { & $OnProgress $op $total $r }
        }
    }
    # emit items into the output stream; callers collect with @(...)
    return $results.ToArray()
}

# Legacy v1 rules ("Block <name> Inbound/Outbound"), filtered literally, never
# via a wildcard -DisplayName query. Requiring Block + matching Direction
# spares third-party rules that merely share the name pattern.
function Get-LegacyRules {
    @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Block .+ (Inbound|Outbound)$' -and $_.Group -ne $script:Group -and
                       [string]$_.Action -eq 'Block' -and [string]$_.Direction -eq $Matches[1] })
}

# Blocked directions per program path, group and legacy rules alike:
# path -> @{ Inbound; Outbound; Paused }, case-insensitive keys. Disabled
# rules (paused in the desktop app) block nothing, they only set Paused.
function Get-BlockedDirections {
    $map = Get-RuleProgramMap
    $index = @{}
    foreach ($r in @($map.Rules) + @(Get-LegacyRules)) {
        $prog = $map.Programs[$r.Name]
        if (-not $prog) { continue }
        if (-not $index.ContainsKey($prog)) { $index[$prog] = @{ Inbound = $false; Outbound = $false; Paused = $false } }
        if ([string]$r.Enabled -eq 'True') { $index[$prog][[string]$r.Direction] = $true }
        else { $index[$prog].Paused = $true }
    }
    return $index
}

# 'blocked' | 'partial (in only)' | 'partial (out only)' | 'paused' | 'none'
function Get-FileStatus {
    param([hashtable]$Directions, [string]$Path)
    $d = $Directions[$Path]
    if (-not $d) { return 'none' }
    if ($d.Inbound -and $d.Outbound) { return 'blocked' }
    if ($d.Inbound) { return 'partial (in only)' }
    if ($d.Outbound) { return 'partial (out only)' }
    return 'paused'
}

# Select the rules an unblock will remove, matched on the rule's stored
# Program path, not the disk, so orphans of deleted folders are found too.
# Legacy rules are swept only for Directory/Files scopes.
function Get-UnblockTargets {
    param(
        [ValidateSet('All', 'Directory', 'Files')][string]$Scope,
        [string]$Directory,
        [string[]]$Files
    )
    $map = Get-RuleProgramMap
    if ($Scope -eq 'All') {
        return @(foreach ($r in $map.Rules) {
            [pscustomobject]@{ Rule = $r; Legacy = $false; Program = $map.Programs[$r.Name] }
        })
    }
    if ($Scope -eq 'Files') {
        $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $Files) { [void]$set.Add($f) }
        $isMatch = { param($p) $set.Contains($p) }
    } else {
        $dir = $Directory.TrimEnd('\')
        if ($dir -match '^[A-Za-z]:$') { $dir = $dir + '\' }
        if ($dir.EndsWith('\')) { $prefix = $dir } else { $prefix = $dir + '\' }
        $isMatch = { param($p) $p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                               [string]::Equals($p, $dir, [StringComparison]::OrdinalIgnoreCase) }
    }
    return @(foreach ($r in @($map.Rules) + @(Get-LegacyRules)) {
        $prog = $map.Programs[$r.Name]
        if ($prog -and (& $isMatch $prog)) {
            [pscustomobject]@{ Rule = $r; Legacy = ([string]$r.Group -ne $script:Group); Program = $prog }
        }
    })
}

# Removes rules one by one (never the bulk -Group call) so every failure is
# itemized. Progress unit = one rule.
function Invoke-UnblockRules {
    param(
        [object[]]$Targets,
        [bool]$DryRun,
        [scriptblock]$OnProgress
    )
    $results = New-Object System.Collections.ArrayList
    $total = $Targets.Count
    $op = 0
    foreach ($t in $Targets) {
        $op++
        $rule = $t.Rule
        if ($t.Program) { $label = $t.Program } else { $label = $rule.DisplayName }
        if ($t.Legacy) { $detail = 'legacy v1 rule' } else { $detail = '' }
        if ($DryRun) {
            $outcome = 'DryRun'
            if (-not $t.Legacy) { $detail = 'would remove' }
        } else {
            try {
                $rule | Remove-NetFirewallRule -ErrorAction Stop
                $outcome = 'Removed'
            } catch {
                $outcome = 'Failed'; $detail = $_.Exception.Message
            }
        }
        $r = [pscustomobject]@{
            File = $label; Name = $rule.DisplayName
            Direction = [string]$rule.Direction; Outcome = $outcome; Detail = $detail
        }
        [void]$results.Add($r)
        if ($OnProgress) { & $OnProgress $op $total $r }
    }
    # emit items into the output stream; callers collect with @(...)
    return $results.ToArray()
}

#endregion
