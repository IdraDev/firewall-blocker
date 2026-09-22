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

# All rules created by this tool, keyed on internal name (FWB_<hash16>_<dir>).
# Loaded once per action: existence checks are O(1) lookups, never wildcard
# -DisplayName queries.
function Get-FwbRules {
    $map = @{}
    $rules = @(Get-NetFirewallRule -Group $script:Group -ErrorAction SilentlyContinue)
    foreach ($r in $rules) { $map[$r.Name] = $r }
    return $map
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
            if ($Existing.ContainsKey($name)) {
                $outcome = 'Skipped'; $detail = 'already exists'
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

# Select the rules an unblock will remove. Directory scope matches by the
# rule's Program path, independent of what is still on disk (orphan fix).
# Also sweeps legacy v1 rules ("Block <name> Inbound/Outbound") whose program
# is under the directory; legacy orphans whose exe path was never recorded
# cannot be found - documented limitation.
function Get-UnblockTargets {
    param(
        [ValidateSet('All', 'Directory')][string]$Scope,
        [string]$Directory
    )
    $map = Get-RuleProgramMap
    $targets = @()
    if ($Scope -eq 'All') {
        foreach ($r in $map.Rules) {
            $targets += [pscustomobject]@{ Rule = $r; Legacy = $false; Program = $map.Programs[$r.Name] }
        }
        return $targets
    }
    $dir = $Directory.TrimEnd('\')
    if ($dir -match '^[A-Za-z]:$') { $dir = $dir + '\' }
    if ($dir.EndsWith('\')) { $prefix = $dir } else { $prefix = $dir + '\' }
    foreach ($r in $map.Rules) {
        $prog = $map.Programs[$r.Name]
        if (-not $prog) { continue }
        if ($prog.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($prog, $dir, [StringComparison]::OrdinalIgnoreCase)) {
            $targets += [pscustomobject]@{ Rule = $r; Legacy = $false; Program = $prog }
        }
    }
    # Legacy v1 sweep: literal Where-Object over the full rule dump, never a
    # wildcard-interpreting -DisplayName query. v1 always created Block rules
    # whose Direction matches the DisplayName suffix; require both so we never
    # remove third-party rules (e.g. Allow rules) that merely share the name
    # pattern.
    $legacyRules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Block .+ (Inbound|Outbound)$' -and $_.Group -ne $script:Group -and
                       [string]$_.Action -eq 'Block' -and [string]$_.Direction -eq $Matches[1] })
    foreach ($r in $legacyRules) {
        $prog = $map.Programs[$r.Name]
        if ($prog -and $prog.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $targets += [pscustomobject]@{ Rule = $r; Legacy = $true; Program = $prog }
        }
    }
    return $targets
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
