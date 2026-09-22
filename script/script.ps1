<#
    FIREWALL BLOCKER v2.0 - By IdraDev

    Blocks or unblocks every .exe under a chosen directory via Windows
    Firewall rules. Runs under Windows PowerShell 5.1, launched elevated
    by start.bat:  powershell -ExecutionPolicy Bypass -File script.ps1

    Interactive TUI by default; non-interactive CLI mode when -Action is
    passed. Switches: -Action -Path -NoConfirm -DryRun -Plain
#>
[CmdletBinding()]
param(
    [ValidateSet('Block','Unblock','List','Rules')]
    [string]$Action,
    [string]$Path,
    [switch]$NoConfirm,
    [switch]$DryRun,
    [switch]$Plain
)

#region Constants & capability probe

$script:AppTitle = 'FIREWALL BLOCKER v2.0 - By IdraDev'
$script:Group    = 'FirewallBlocker'
$script:Spinner  = @('|','/','-','\')
$script:LastPath = $null
$script:Exec     = @{ Active = $false; Done = 0; Total = 0 }

$script:Tui = [pscustomobject]@{ Interactive = $false; Width = 78 }
try {
    if (-not $Plain -and $Host.Name -eq 'ConsoleHost' -and
        -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected) {
        $null = $Host.UI.RawUI.KeyAvailable   # throws in ISE / exotic hosts
        $script:Tui.Interactive = $true
    }
} catch { }

# Glyphs: CP437-safe set for the interactive console, ASCII everywhere else.
# Built from codepoints so this source file stays pure ASCII.
if ($script:Tui.Interactive) {
    $script:G = @{
        Ok       = [string][char]0x221A   # square-root check mark
        Err      = 'x'
        Warn     = '!'
        Bullet   = [string][char]0x00B7
        Pointer  = [string][char]0x00BB
        Rule     = [string][char]0x2500
        Rail     = [string][char]0x2502
        BarFull  = [string][char]0x2588
        BarEmpty = [string][char]0x2591
        Up       = [string][char]0x2191
        Down     = [string][char]0x2193
    }
} else {
    $script:G = @{
        Ok = '+'; Err = 'x'; Warn = '!'; Bullet = '-'; Pointer = '>'
        Rule = '-'; Rail = '|'; BarFull = '#'; BarEmpty = '.'
        Up = 'up'; Down = 'dn'
    }
}

# Color palette: tokens only, never hardcode a color at a call site.
$script:Pal = @{
    Accent = 'Cyan'; Text = 'Gray'; Strong = 'White'; Muted = 'DarkGray'
    Ok = 'Green'; Warn = 'Yellow'; Err = 'Red'
}

function Update-Width {
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        # never exceed the real window width: padding past it hard-wraps and
        # corrupts every in-place repaint (menus, progress bar)
        $script:Tui.Width = [Math]::Max(20, [Math]::Min(100, $w - 2))
    } catch {
        $script:Tui.Width = 78
        $script:Tui.Interactive = $false
    }
}

#endregion

#region Rendering primitives

function Set-CursorVisible {
    param([bool]$Visible)
    try { [Console]::CursorVisible = $Visible } catch { }
}

# Write-Seg: one physical line from colored segments. Each segment is a
# two-element array @('text','PaletteToken'). -PadTo right-pads with spaces
# so rewritten lines never leave residue.
function Write-Seg {
    param(
        [object[]]$Segments,
        [int]$PadTo = 0,
        [switch]$NoNewline
    )
    if ($Segments.Count -gt 0 -and ($Segments[0] -is [string])) {
        $Segments = ,$Segments   # single segment passed unwrapped
    }
    $len = 0
    foreach ($seg in $Segments) {
        $text = [string]$seg[0]
        $tok  = [string]$seg[1]
        Write-Host $text -ForegroundColor $script:Pal[$tok] -NoNewline
        $len += $text.Length
    }
    if ($PadTo -gt $len) { Write-Host (' ' * ($PadTo - $len)) -NoNewline }
    if (-not $NoNewline) { Write-Host '' }
}

# Write-Status: rewrite one line in place, always padded to full width.
function Write-Status {
    param([int]$Row, [object[]]$Segments)
    [Console]::SetCursorPosition(0, $Row)
    Write-Seg -Segments $Segments -PadTo $script:Tui.Width -NoNewline
}

function Show-Card {
    param([string]$GlyphToken, [string]$ColorToken, [string[]]$Lines)
    $g = $script:G[$GlyphToken]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -eq 0) {
            Write-Seg @(@("  $g  ", $ColorToken), @($Lines[0], 'Text'))
        } else {
            Write-Seg @(@("  $($script:G.Rail)  ", 'Muted'), @($Lines[$i], 'Text'))
        }
    }
}

function Write-Breadcrumb {
    param([string[]]$Parts)
    $segs = @(,@('  ', 'Muted'))
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if ($i -gt 0) { $segs += ,@(" $($script:G.Pointer) ", 'Muted') }
        if ($i -eq $Parts.Count - 1) { $tok = 'Accent' } else { $tok = 'Muted' }
        $segs += ,@($Parts[$i], $tok)
    }
    Write-Seg $segs
    Write-Host ''
}

function Show-Header {
    Update-Width
    if ($script:Tui.Interactive) { Clear-Host }
    $w = $script:Tui.Width
    $b = $script:G.Bullet
    if ($script:IsAdmin) { $aG = $script:G.Ok; $aTok = 'Ok' } else { $aG = $script:G.Err; $aTok = 'Err' }
    if ($script:SvcOk)   { $sG = $script:G.Ok; $sTok = 'Ok' } else { $sG = $script:G.Err; $sTok = 'Err' }
    $statusLen = ('admin ' + $aG + ' ' + $b + ' mpssvc ' + $sG).Length
    if ($DryRun) { $statusLen += (' ' + $b + ' DRY RUN').Length }
    $title = '  ' + $script:AppTitle
    $pad = $w - $title.Length - $statusLen
    if ($pad -lt 2) { $pad = 2 }
    $segs = @(
        @($title, 'Strong'),
        @((' ' * $pad), 'Text'),
        @('admin ', 'Muted'), @($aG, $aTok),
        @(" $b ", 'Muted'),
        @('mpssvc ', 'Muted'), @($sG, $sTok)
    )
    if ($DryRun) {
        $segs += ,@(" $b ", 'Muted')
        $segs += ,@('DRY RUN', 'Warn')
    }
    Write-Seg $segs
    Write-Seg @(('  ' + ($script:G.Rule * ($w - 2))), 'Muted')
    Write-Host ''
    if (-not $script:Tui.Interactive) {
        Write-Seg @('  (plain mode - limited console)', 'Muted')
        Write-Host ''
    }
}

#endregion

#region Input primitives

function Clear-KeyBuffer {
    if (-not $script:Tui.Interactive) { return }
    try {
        while ($Host.UI.RawUI.KeyAvailable) {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch { }
}

# Read-Host that treats stdin EOF ($null, e.g. piped input exhausted) as a
# graceful exit instead of letting a later .Trim() crash on null.
function Read-HostSafe {
    param([string]$Prompt)
    if ($Prompt) { $ans = Read-Host $Prompt } else { $ans = Read-Host }
    if ($null -eq $ans) {
        Write-Seg @('  input ended, exiting', 'Muted')
        exit 0
    }
    return $ans
}

# ReadKey that skips modifier-only presses (Shift/Ctrl/Alt = VK 16/17/18).
function Read-KeyPress {
    while ($true) {
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        if ($k.VirtualKeyCode -in 16, 17, 18) { continue }
        return $k
    }
}

function Wait-AnyKey {
    param([string]$Message = 'press any key to continue')
    if ($script:Tui.Interactive) {
        Write-Seg @("  $Message", 'Muted')
        Clear-KeyBuffer
        $null = Read-KeyPress
    } else {
        $null = Read-Host '  press Enter to continue'
    }
}

function Write-MenuRow {
    param([int]$Row, [object]$Item, [int]$VerbW, [bool]$Selected)
    if ($Selected) {
        $segs = @(
            @("  $($script:G.Pointer) ", 'Accent'),
            @("$($Item.Num) ", 'Strong'),
            @($Item.Verb.PadRight($VerbW), 'Strong'),
            @("  $($Item.Desc)", 'Text')
        )
    } else {
        $segs = @(
            @('    ', 'Muted'),
            @("$($Item.Num) ", 'Muted'),
            @($Item.Verb.PadRight($VerbW), 'Muted'),
            @("  $($Item.Desc)", 'Muted')
        )
    }
    if ($Row -ge 0) { Write-Status $Row $segs }
    else { Write-Seg $segs -PadTo $script:Tui.Width }
}

# Returns the 1-based item number, or -1 for Esc.
function Read-MenuChoice {
    param([object[]]$Items, [string]$ExitHint = 'esc back')
    $n = $Items.Count
    $verbW = 0
    foreach ($it in $Items) {
        if ($it.Verb.Length -gt $verbW) { $verbW = $it.Verb.Length }
    }
    if (-not $script:Tui.Interactive) {
        foreach ($it in $Items) {
            Write-Seg @(
                @('    ', 'Text'),
                @("$($it.Num) ", 'Strong'),
                @($it.Verb.PadRight($verbW), 'Strong'),
                @("  $($it.Desc)", 'Text')
            )
        }
        Write-Host ''
        while ($true) {
            $ans = (Read-HostSafe "  choice [1-$n]").Trim()
            if ($ans -match '^[0-9]+$') {
                $v = [int]$ans
                if ($v -ge 1 -and $v -le $n) { return $v }
            }
            Write-Seg @(@("  $($script:G.Err)  ", 'Err'), @('invalid choice, try again', 'Text'))
        }
    }
    $sel = 0
    $menuTop = [Console]::CursorTop
    Set-CursorVisible $false
    try {
        for ($i = 0; $i -lt $n; $i++) { Write-MenuRow -1 $Items[$i] $verbW ($i -eq $sel) }
        Write-Host ''
        $b = $script:G.Bullet
        Write-Seg @("  $($script:G.Up)$($script:G.Down) move $b enter select $b 1-$n jump $b $ExitHint", 'Muted')
        $endRow = [Console]::CursorTop
        Clear-KeyBuffer
        while ($true) {
            $k = Read-KeyPress
            $vk = $k.VirtualKeyCode
            $old = $sel
            if     ($vk -eq 38) { $sel = ($sel + $n - 1) % $n }
            elseif ($vk -eq 40) { $sel = ($sel + 1) % $n }
            elseif ($vk -eq 36) { $sel = 0 }
            elseif ($vk -eq 35) { $sel = $n - 1 }
            elseif ($vk -eq 13) { return $sel + 1 }
            elseif ($vk -eq 27) { return -1 }
            else {
                $c = $k.Character
                if ($c -ge [char]'1' -and $c -le [char]([int][char]'0' + $n)) {
                    return [int]$c.ToString()
                }
            }
            if ($sel -ne $old) {
                Write-MenuRow ($menuTop + $old) $Items[$old] $verbW $false
                Write-MenuRow ($menuTop + $sel) $Items[$sel] $verbW $true
                [Console]::SetCursorPosition(0, $endRow)
            }
        }
    } finally { Set-CursorVisible $true }
}

# Read-Confirm: single-key y/N (default No) or Y/n (default Yes).
# Esc always cancels. Plain mode falls back to a Read-Host loop.
function Read-Confirm {
    param([object[]]$QuestionSegs, [bool]$DefaultYes = $false)
    if ($DefaultYes) { $suffix = '  [Y/n]' } else { $suffix = '  [y/N]' }
    $segs = @(,@('  ? ', 'Accent')) + $QuestionSegs + @(,@($suffix, 'Strong'))
    Write-Seg $segs -NoNewline
    if ($script:Tui.Interactive) {
        Clear-KeyBuffer
        $k = Read-KeyPress
        Write-Host ''
        if ($k.VirtualKeyCode -eq 27) { return $false }
        $c = $k.Character
        if ($DefaultYes) { return -not ($c -eq 'n' -or $c -eq 'N') }
        return ($c -eq 'y' -or $c -eq 'Y')
    }
    Write-Host ''
    while ($true) {
        if ($DefaultYes) { $ans = (Read-HostSafe '  proceed? (Y/n)').Trim() }
        else             { $ans = (Read-HostSafe '  proceed? (y/N)').Trim() }
        if ($ans -eq '') { return $DefaultYes }
        if ($ans -match '^[yY]') { return $true }
        if ($ans -match '^[nN]') { return $false }
    }
}

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

# Returns a validated directory, or $null when the user cancels (empty input).
function Read-FolderPath {
    param([switch]$AllowMissing)
    $fails = 0
    $b = $script:G.Bullet
    while ($true) {
        Write-Seg @(@('  ? ', 'Accent'), @('Folder to scan (includes subfolders)', 'Text'))
        $hint = "$b enter on an empty line goes back $b paste from Explorer is fine, quotes are removed"
        if ($script:LastPath) { $hint = "$hint $b . = $($script:LastPath)" }
        Write-Seg @(('    ' + (Format-Ellipsis $hint ($script:Tui.Width - 5))), 'Muted')
        if ($fails -ge 5) {
            Write-Seg @('    tip: open the folder in Explorer and copy the address bar', 'Muted')
        }
        Write-Seg @('  > ', 'Accent') -NoNewline
        Set-CursorVisible $true
        $raw = Read-HostSafe
        $trimmed = $raw.Trim().Trim('"').Trim("'")
        if ($trimmed -eq '') { return $null }
        if ($trimmed -eq '.' -and $script:LastPath) { $trimmed = $script:LastPath }
        $res = Resolve-FolderInput $trimmed -AllowMissing:$AllowMissing
        if (-not $res.Ok) {
            $fails++
            Write-Seg @(@("  $($script:G.Err)  ", 'Err'),
                        @((Format-Ellipsis $res.Error ($script:Tui.Width - 6)), 'Err'))
            continue
        }
        $script:LastPath = $res.Path
        return $res.Path
    }
}

#endregion

#region Helpers

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

function Format-Ellipsis {
    param([string]$Text, [int]$Max, [switch]$Middle)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 3) { return $Text.Substring(0, [Math]::Max(1, $Max)) }
    if ($Middle) {
        $keep = $Max - 3
        $head = [int][Math]::Ceiling($keep / 2)
        $tail = $keep - $head
        return $Text.Substring(0, $head) + '...' + $Text.Substring($Text.Length - $tail)
    }
    return $Text.Substring(0, $Max - 3) + '...'
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

# One bulk join of group rules to their program paths. Each application
# filter's InstanceID equals the owning rule's Name.
function Get-RuleProgramMap {
    $rules = @(Get-NetFirewallRule -Group $script:Group -ErrorAction SilentlyContinue)
    $byName = @{}
    foreach ($r in $rules) { $byName[$r.Name] = $r }
    $programs = @{}
    if ($rules.Count -gt 0) {
        $filters = @($rules | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
        foreach ($f in $filters) { $programs[$f.InstanceID] = $f.Program }
    }
    return [pscustomobject]@{ Rules = $rules; ByName = $byName; Programs = $programs }
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
    if ($legacyRules.Count -gt 0) {
        $lp = @{}
        $lf = @($legacyRules | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
        foreach ($f in $lf) { $lp[$f.InstanceID] = $f.Program }
        foreach ($r in $legacyRules) {
            $prog = $lp[$r.Name]
            if ($prog -and $prog.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $targets += [pscustomobject]@{ Rule = $r; Legacy = $true; Program = $prog }
            }
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

#region Screens

function Show-MainMenu {
    Write-Seg @('  What do you want to do?', 'Text')
    Write-Host ''
    $items = @(
        [pscustomobject]@{ Num = 1; Verb = 'Block';   Desc = 'add In+Out block rules for every .exe under a folder' },
        [pscustomobject]@{ Num = 2; Verb = 'Unblock'; Desc = 'remove rules created by this tool' },
        [pscustomobject]@{ Num = 3; Verb = 'Files';   Desc = 'list .exe files under a folder, with block status' },
        [pscustomobject]@{ Num = 4; Verb = 'Rules';   Desc = 'list existing FirewallBlocker rules' },
        [pscustomobject]@{ Num = 5; Verb = 'Exit';    Desc = 'leave the tool' }
    )
    $c = Read-MenuChoice -Items $items -ExitHint 'esc exit'
    if ($c -eq -1) { return 5 }
    return $c
}

# Live scan line: spinner rewritten in place (>= 80 ms throttle), collapses
# to a result line. Ticks come from the enumeration pipeline, no jobs.
function Show-Scan {
    param([string]$Directory)
    $b = $script:G.Bullet
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $onTick = $null
    $row = -1
    if ($script:Tui.Interactive) {
        $row = [Console]::CursorTop
        $spinState = @{ Frame = 0; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
        $label = 'scanning ' + (Format-Ellipsis $Directory ($script:Tui.Width - 18) -Middle) + ' ...'
        Write-Status $row @(@('  ' + $script:Spinner[0] + ' ', 'Accent'), @($label, 'Text'))
        $onTick = {
            param($f)
            if ($spinState.Watch.ElapsedMilliseconds -lt 80) { return }
            $spinState.Watch.Restart()
            $spinState.Frame = ($spinState.Frame + 1) % 4
            Write-Status $row @(@('  ' + $script:Spinner[$spinState.Frame] + ' ', 'Accent'), @($label, 'Text'))
        }
    } else {
        Write-Seg @("  scanning $Directory ...", 'Text')
    }
    $res = Get-ExeFiles -Directory $Directory -OnTick $onTick
    $secs = '{0:0.0}s' -f $sw.Elapsed.TotalSeconds
    $doneSegs = @(
        @("  $($script:G.Ok) ", 'Ok'),
        @("$(@($res.Files).Count) .exe files", 'Strong'),
        @(" $b $secs", 'Muted')
    )
    if ($script:Tui.Interactive) { Write-Status $row $doneSegs; Write-Host '' }
    else { Write-Seg $doneSegs }
    if ($res.ErrorCount -gt 0) {
        Write-Seg @(@("  $($script:G.Warn) ", 'Warn'),
                    @("$($res.ErrorCount) folders unreadable (skipped)", 'Warn'))
    }
    return $res
}

# Load the group-rule hashtable once, with the same live-line treatment.
function Show-RuleLoad {
    $row = -1
    $segs = @(@('  ' + $script:Spinner[0] + ' ', 'Accent'), @('checking existing firewall rules ...', 'Text'))
    if ($script:Tui.Interactive) {
        $row = [Console]::CursorTop
        Write-Status $row $segs
    } else {
        Write-Seg @('  checking existing firewall rules ...', 'Text')
    }
    $existing = Get-FwbRules
    $doneSegs = @(
        @("  $($script:G.Ok) ", 'Ok'),
        @("$($existing.Count) existing FirewallBlocker rules", 'Strong')
    )
    if ($script:Tui.Interactive) { Write-Status $row $doneSegs; Write-Host '' }
    else { Write-Seg $doneSegs }
    return $existing
}

# Block preview: counts computed against the preloaded hashtable so the
# numbers equal exactly what execution will do.
function Show-BlockPreview {
    param([object[]]$Files, [hashtable]$Existing)
    $b = $script:G.Bullet
    $rail = "  $($script:G.Rail)  "
    $full = 0; $part = 0; $none = 0; $ops = 0
    foreach ($f in $Files) {
        $names = Get-RuleNames $f.FullName
        $hasIn = $Existing.ContainsKey($names.In)
        $hasOut = $Existing.ContainsKey($names.Out)
        if ($hasIn -and $hasOut) { $full++ }
        elseif ($hasIn -or $hasOut) { $part++; $ops++ }
        else { $none++; $ops += 2 }
    }
    Write-Seg @(@("  $($script:G.Ok) ", 'Ok'), @("$($Files.Count) .exe files found", 'Strong'))
    Write-Seg @(@($rail, 'Muted'), @(('{0,5}' -f $none), 'Strong'),
                @(' need new rules'.PadRight(26), 'Text'),
                @('2 rules each (inbound + outbound)', 'Muted'))
    Write-Seg @(@($rail, 'Muted'), @(('{0,5}' -f $full), 'Strong'),
                @(' already fully blocked'.PadRight(26), 'Text'),
                @('will skip', 'Muted'))
    Write-Seg @(@($rail, 'Muted'), @(('{0,5}' -f $part), 'Strong'),
                @(' partially blocked'.PadRight(26), 'Text'),
                @('missing direction will be added', 'Muted'))
    Write-Seg @(@($rail, 'Muted'), @('', 'Muted'))
    # one-line sample, ellipsized with +N more
    $maxLen = $script:Tui.Width - 10
    $sample = ''
    $shown = 0
    foreach ($f in $Files) {
        if ($shown -eq 0) { $cand = $f.Name } else { $cand = $sample + " $b " + $f.Name }
        if ($cand.Length -gt $maxLen -and $shown -gt 0) { break }
        $sample = $cand
        $shown++
    }
    $more = $Files.Count - $shown
    if ($more -gt 0) { $sample = $sample + "  +$more more" }
    Write-Seg @(@($rail, 'Muted'), @((Format-Ellipsis $sample ($script:Tui.Width - 6)), 'Muted'))
    return [pscustomobject]@{ Ops = $ops; Full = $full; Part = $part; None = $none }
}

function Show-UnblockPreview {
    param([object[]]$Targets, [string]$ScopeLabel)
    $b = $script:G.Bullet
    Write-Seg @(@("  $($script:G.Ok) ", 'Ok'),
                @("$($Targets.Count) rules", 'Strong'),
                @((' match ' + (Format-Ellipsis $ScopeLabel ($script:Tui.Width - 24) -Middle)), 'Text'))
    $legacy = @($Targets | Where-Object { $_.Legacy }).Count
    if ($legacy -gt 0) {
        Write-Seg @(@("  $($script:G.Rail)  ", 'Muted'),
                    @("$legacy legacy v1 rules", 'Strong'),
                    @(" $b will also be removed", 'Muted'))
    }
}

# Runs an engine call ($Runner receives the OnProgress callback) behind a
# single in-place progress line. Failures print above the bar as they happen.
# Repaint only when the integer percent changes or >= 80 ms elapsed.
function Show-Execute {
    param(
        [string]$Verb,
        [string]$FillTok,
        [int]$Total,
        [scriptblock]$Runner
    )
    $b = $script:G.Bullet
    $script:Exec.Active = $true
    $script:Exec.Done = 0
    $script:Exec.Total = $Total
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($script:Tui.Interactive) {
        Set-CursorVisible $false
        $st = @{ Row = [Console]::CursorTop; LastPct = -1; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
        $drawBar = {
            param($op, $total, $name)
            $pct = 0; $cells = 0
            if ($total -gt 0) {
                $pct = [int][Math]::Floor(100 * $op / $total)
                $cells = [int][Math]::Floor(20 * $op / $total)
            }
            $fill = $script:G.BarFull * $cells
            $empty = $script:G.BarEmpty * (20 - $cells)
            $tail = Format-Ellipsis $name ([Math]::Max(8, $script:Tui.Width - 48))
            Write-Status $st.Row @(
                @("  $($script:G.Pointer) ", 'Accent'), @("$Verb  ", 'Text'),
                @($fill, $FillTok), @($empty, 'Muted'),
                @(('  {0,3}%' -f $pct), 'Strong'), @("  $op/$total", 'Strong'),
                @(" $b ", 'Muted'), @($tail, 'Muted')
            )
        }
        $onProgress = {
            param($op, $total, $r)
            $script:Exec.Done = $op
            if ($r.Outcome -eq 'Failed') {
                Write-Status $st.Row @(,@('', 'Text'))    # blank the bar row
                [Console]::SetCursorPosition(0, $st.Row)
                $dtxt = ''
                if ($r.Direction) { $dtxt = '  (' + ([string]$r.Direction).ToLower() + ')' }
                Write-Seg -PadTo $script:Tui.Width @(
                    @("  $($script:G.Err)  ", 'Err'),
                    @((Format-Ellipsis "$($r.Name)$dtxt   $($r.Detail)" ($script:Tui.Width - 6)), 'Err'))
                Write-Host ''
                $st.Row = [Console]::CursorTop
                $st.LastPct = -1
            }
            $pct = 0
            if ($total -gt 0) { $pct = [int][Math]::Floor(100 * $op / $total) }
            if ($pct -ne $st.LastPct -or $st.Watch.ElapsedMilliseconds -ge 80) {
                & $drawBar $op $total $r.Name
                $st.LastPct = $pct
                $st.Watch.Restart()
            }
        }
        try {
            $results = & $Runner $onProgress
            & $drawBar $Total $Total 'done'
            Write-Host ''
        } finally { Set-CursorVisible $true }
    } else {
        $onProgress = {
            param($op, $total, $r)
            $script:Exec.Done = $op
            if ($r.Outcome -eq 'Failed') {
                Write-Seg @(@("  $($script:G.Err)  ", 'Err'),
                            @("$($r.Name) ($($r.Direction))  $($r.Detail)", 'Err'))
            }
            $pct = 0
            if ($total -gt 0) { $pct = [int](100 * $op / $total) }
            Write-Progress -Activity $Verb -Status "$op / $total" -PercentComplete $pct
            if (($op % 25) -eq 0 -or $op -eq $total) {
                Write-Seg @("  $op/$total $Verb ...", 'Text')
            }
        }
        $results = & $Runner $onProgress
        Write-Progress -Activity $Verb -Completed
    }
    $script:Exec.Active = $false
    return [pscustomobject]@{ Results = @($results); Seconds = $sw.Elapsed.TotalSeconds }
}

function Write-CountRow {
    param([int]$Count, [string]$Label, [string]$Note)
    if ($Count -eq 0) { $numTok = 'Muted'; $labTok = 'Muted' }
    else { $numTok = 'Strong'; $labTok = 'Text' }
    $segs = @(@(('  {0,5} ' -f $Count), $numTok), @($Label, $labTok))
    if ($Note) { $segs += ,@(" $($script:G.Bullet) $Note", 'Muted') }
    Write-Seg $segs
}

# Summary is built from the engine result objects only - single accounting.
function Show-Summary {
    param(
        [object[]]$Results,
        [double]$Seconds,
        [ValidateSet('Block', 'Unblock')][string]$Mode,
        [bool]$IsDryRun
    )
    $created = @($Results | Where-Object { $_.Outcome -eq 'Created' }).Count
    $removed = @($Results | Where-Object { $_.Outcome -eq 'Removed' }).Count
    $skipped = @($Results | Where-Object { $_.Outcome -eq 'Skipped' }).Count
    $dry     = @($Results | Where-Object { $_.Outcome -eq 'DryRun' }).Count
    $failed  = @($Results | Where-Object { $_.Outcome -eq 'Failed' })
    Write-Host ''
    Write-Seg @(('  ' + ($script:G.Rule * [Math]::Min(44, $script:Tui.Width - 2))), 'Muted')
    $secs = '{0:0.0}s' -f $Seconds
    if ($failed.Count -gt 0) {
        Write-Seg @(@("  $($script:G.Warn) ", 'Warn'), @("done with errors in $secs", 'Warn'))
    } else {
        Write-Seg @(@("  $($script:G.Ok) ", 'Ok'), @("done in $secs", 'Ok'))
    }
    Write-Host ''
    if ($IsDryRun) {
        if ($Mode -eq 'Block') {
            Write-CountRow $dry 'rules would be created' ''
            Write-CountRow $skipped 'already exist' 'would skip'
        } else {
            Write-CountRow $dry 'rules would be removed' ''
        }
    } else {
        if ($Mode -eq 'Block') {
            Write-CountRow $created 'rules created' ''
            Write-CountRow $skipped 'skipped' 'already existed'
        } else {
            Write-CountRow $removed 'rules removed' ''
            Write-CountRow $skipped 'skipped' ''
        }
    }
    Write-CountRow $failed.Count 'failed' ''
    if ($failed.Count -gt 0) {
        Write-Host ''
        $show = @($failed | Select-Object -First 10)
        foreach ($f in $show) {
            $dirTxt = ''
            if ($f.Direction) { $dirTxt = ([string]$f.Direction).ToLower() }
            $line = '{0,-24} {1,-9} {2}' -f (Format-Ellipsis $f.Name 24), $dirTxt, $f.Detail
            Write-Seg @(@("  $($script:G.Err)  ", 'Err'),
                        @((Format-Ellipsis $line ($script:Tui.Width - 6)), 'Err'))
        }
        if ($failed.Count -gt 10) {
            Write-Seg @("     +$($failed.Count - 10) more failures", 'Muted')
        }
        $denied = @($failed | Where-Object { $_.Detail -match 'denied' }).Count
        if ($denied -gt 0) {
            Write-Seg @('     hint: run start.bat as Administrator', 'Muted')
        }
    }
    Write-Host ''
}

# Generic pager. $RowSegs = one prebuilt segment list per row. Full repaint
# per key; page size recomputed every pass so a resize self-heals.
function Show-Pager {
    param([scriptblock]$DrawTop, [object[]]$RowSegs, [object[]]$FooterSegs)
    if (-not $script:Tui.Interactive) {
        foreach ($r in $RowSegs) { Write-Seg $r }
        Write-Host ''
        Write-Seg $FooterSegs
        Wait-AnyKey
        return
    }
    $top = 0
    Set-CursorVisible $false
    try {
        while ($true) {
            Show-Header
            & $DrawTop
            $h = 20
            try { $h = $Host.UI.RawUI.WindowSize.Height - 9 } catch { }
            if ($h -lt 5) { $h = 5 }
            $maxTop = $RowSegs.Count - $h
            if ($maxTop -lt 0) { $maxTop = 0 }
            if ($top -gt $maxTop) { $top = $maxTop }
            $end = [Math]::Min($RowSegs.Count, $top + $h)
            for ($i = $top; $i -lt $end; $i++) {
                Write-Seg $RowSegs[$i] -PadTo $script:Tui.Width
            }
            Write-Host ''
            $segs = @() + $FooterSegs
            if ($RowSegs.Count -gt $h) {
                $segs += ,@(" $($script:G.Bullet) $($top + 1)-$end of $($RowSegs.Count)", 'Muted')
            }
            Write-Seg $segs
            Clear-KeyBuffer
            $k = Read-KeyPress
            switch ($k.VirtualKeyCode) {
                38 { if ($top -gt 0) { $top-- } }
                40 { if ($top -lt $maxTop) { $top++ } }
                33 { $top = [Math]::Max(0, $top - $h) }
                34 { $top = [Math]::Min($maxTop, $top + $h) }
                32 { $top = [Math]::Min($maxTop, $top + $h) }
                36 { $top = 0 }
                35 { $top = $maxTop }
                27 { return }
                default { }
            }
        }
    } finally { Set-CursorVisible $true }
}

# Menu 3: dry-run-style audit of a folder, no confirm needed.
function Show-FileList {
    Show-Header
    Write-Breadcrumb @('files', 'target folder')
    Write-Host ''
    $dir = Read-FolderPath
    if (-not $dir) { return }
    Show-Header
    Write-Breadcrumb @('files', $dir)
    Write-Host ''
    $scan = Show-Scan $dir
    $files = @($scan.Files)
    if ($files.Count -eq 0) {
        Write-Seg @(@("  $($script:G.Warn)  ", 'Warn'), @("no .exe files under $dir", 'Warn'))
        Wait-AnyKey 'press any key to go back'
        return
    }
    $existing = Show-RuleLoad
    $b = $script:G.Bullet
    $w = $script:Tui.Width
    $statW = 12
    $fileW = [Math]::Min(34, $w - 42)
    if ($fileW -lt 16) { $fileW = 16 }
    $whereW = $w - $statW - $fileW - 16
    if ($whereW -lt 10) { $whereW = 10 }
    $blocked = 0; $none = 0; $part = 0
    $rows = @()
    foreach ($f in $files) {
        $names = Get-RuleNames $f.FullName
        $hasIn = $existing.ContainsKey($names.In)
        $hasOut = $existing.ContainsKey($names.Out)
        $extra = ''
        if ($hasIn -and $hasOut) {
            $lab = "$($script:G.Ok) blocked"; $tok = 'Ok'; $blocked++
        } elseif ($hasIn -or $hasOut) {
            $lab = "$($script:G.Warn) partial"; $tok = 'Warn'; $part++
            if ($hasIn) { $extra = 'in only' } else { $extra = 'out only' }
        } else {
            $lab = "$b none"; $tok = 'Muted'; $none++
        }
        $rel = $f.DirectoryName
        if ($rel.Length -ge $dir.Length) { $rel = $rel.Substring($dir.Length) }
        if ($rel -eq '') { $rel = '\' }
        if (-not $rel.StartsWith('\')) { $rel = '\' + $rel }
        $segs = @(
            @(('  ' + $lab.PadRight($statW)), $tok),
            @((' ' + (Format-Ellipsis $f.Name $fileW).PadRight($fileW + 2)), 'Strong'),
            @((Format-Ellipsis $rel $whereW -Middle), 'Muted')
        )
        if ($extra) { $segs += ,@("    $extra", 'Muted') }
        $rows += ,$segs
    }
    $drawTop = {
        Write-Breadcrumb @('files', "$dir $b $($files.Count) .exe")
        Write-Host ''
        Write-Seg @(('  ' + 'status'.PadRight($statW) + ' ' + 'file'.PadRight($fileW + 2) + 'where'), 'Muted')
        Write-Seg @(('  ' + ($script:G.Rule * ($statW - 1)) + '  ' + ($script:G.Rule * ($fileW + 1)) + ' ' + ($script:G.Rule * [Math]::Min($whereW, 20))), 'Muted')
    }
    $footer = @(
        @("  $($script:G.Ok) ", 'Ok'), @("$blocked blocked", 'Strong'),
        @(" $b ", 'Muted'), @("$none none", 'Strong'),
        @(" $b ", 'Muted'), @("$part partial", 'Strong'),
        @(("    $($script:G.Up)$($script:G.Down) line $b pgup/pgdn page $b esc back"), 'Muted')
    )
    Show-Pager -DrawTop $drawTop -RowSegs $rows -FooterSegs $footer
}

# Menu 4: list every rule in the FirewallBlocker group.
function Show-RuleList {
    Show-Header
    Write-Breadcrumb @('rules', 'FirewallBlocker group')
    Write-Host ''
    Write-Seg @('  loading rules ...', 'Text')
    $map = Get-RuleProgramMap
    $rules = @($map.Rules)
    if ($rules.Count -eq 0) {
        Write-Seg @("  $($script:G.Bullet) no FirewallBlocker rules exist", 'Muted')
        Wait-AnyKey 'press any key for menu'
        return
    }
    $b = $script:G.Bullet
    $w = $script:Tui.Width
    $dirW = 10
    $ruleW = [Math]::Min(34, $w - 44)
    if ($ruleW -lt 20) { $ruleW = 20 }
    $progW = $w - $dirW - $ruleW - 8
    if ($progW -lt 12) { $progW = 12 }
    $rows = @()
    $sorted = @($rules | Sort-Object -Property DisplayName)
    foreach ($r in $sorted) {
        if ([string]$r.Direction -eq 'Inbound') { $d = 'in' } else { $d = 'out' }
        $disp = $r.DisplayName
        if ($disp.StartsWith('FirewallBlocker: ')) { $disp = $disp.Substring(17) }
        $prog = $map.Programs[$r.Name]
        if (-not $prog) { $prog = '(unknown program)' }
        $rows += ,@(
            @(('  ' + $d.PadRight($dirW)), 'Text'),
            @(((Format-Ellipsis $disp $ruleW) + ' ').PadRight($ruleW + 2), 'Strong'),
            @((Format-Ellipsis $prog $progW -Middle), 'Muted')
        )
    }
    $drawTop = {
        Write-Breadcrumb @('rules', "FirewallBlocker group $b $($rules.Count) rules")
        Write-Host ''
        Write-Seg @(('  ' + 'direction'.PadRight($dirW) + 'rule'.PadRight($ruleW + 2) + 'program'), 'Muted')
        Write-Seg @(('  ' + ($script:G.Rule * ($dirW - 1)) + ' ' + ($script:G.Rule * ($ruleW + 1)) + ' ' + ($script:G.Rule * [Math]::Min($progW, 30))), 'Muted')
    }
    $footer = @(
        @(("  press esc for menu $b $($rules.Count) rules in group"), 'Muted')
    )
    Show-Pager -DrawTop $drawTop -RowSegs $rows -FooterSegs $footer
}

function Invoke-BlockFlow {
    Show-Header
    Write-Breadcrumb @('block', 'target folder')
    Write-Host ''
    $dir = Read-FolderPath
    if (-not $dir) { return }
    Show-Header
    Write-Breadcrumb @('block', $dir)
    Write-Host ''
    $scan = Show-Scan $dir
    $files = @($scan.Files)
    if ($files.Count -eq 0) {
        Write-Seg @(@("  $($script:G.Warn)  ", 'Warn'), @("no .exe files under $dir", 'Warn'))
        Wait-AnyKey 'press any key to go back'
        return
    }
    $existing = Show-RuleLoad
    Write-Host ''
    $pv = Show-BlockPreview -Files $files -Existing $existing
    Write-Host ''
    if ($pv.Ops -eq 0) {
        Write-Seg @(@("  $($script:G.Ok) ", 'Ok'), @('everything is already blocked - nothing to do', 'Text'))
        Wait-AnyKey 'press any key for menu'
        return
    }
    if ($DryRun) {
        $ok = Read-Confirm @(
            @("Preview $($pv.Ops) rule creations? ", 'Text'),
            @('(dry run - nothing will change)', 'Warn')) $true
    } else {
        $ok = Read-Confirm @(
            @('Create ', 'Text'), @("$($pv.Ops)", 'Strong'), @(' firewall rules?', 'Text')) $false
    }
    if (-not $ok) { return }
    Write-Host ''
    $verb = 'blocking'; $fill = 'Accent'
    if ($DryRun) { $verb = 'dry run'; $fill = 'Warn' }
    $run = Show-Execute -Verb $verb -FillTok $fill -Total ($files.Count * 2) -Runner {
        param($cb)
        Invoke-BlockRules -Files $files -Existing $existing -DryRun ([bool]$DryRun) -OnProgress $cb
    }
    Show-Summary -Results $run.Results -Seconds $run.Seconds -Mode 'Block' -IsDryRun ([bool]$DryRun)
    Wait-AnyKey 'press any key for menu'
}

function Show-UnblockScope {
    Write-Breadcrumb @('unblock', 'scope')
    Write-Host ''
    $count = Get-GroupRuleCount
    $items = @(
        [pscustomobject]@{ Num = 1; Verb = 'Everything'; Desc = "remove ALL FirewallBlocker rules (currently $count)" },
        [pscustomobject]@{ Num = 2; Verb = 'Directory';  Desc = 'remove only rules for exes under a chosen folder' },
        [pscustomobject]@{ Num = 3; Verb = 'Back';       Desc = 'return to the main menu' }
    )
    return Read-MenuChoice -Items $items -ExitHint 'esc back'
}

function Invoke-UnblockFlow {
    Show-Header
    $c = Show-UnblockScope
    if ($c -eq -1 -or $c -eq 3) { return }
    $scopeLabel = 'ALL FirewallBlocker rules'
    $dir = $null
    if ($c -eq 2) {
        Show-Header
        Write-Breadcrumb @('unblock', 'directory', 'target folder')
        Write-Host ''
        # -AllowMissing: unblock must work for deleted folders (orphaned rules)
        $dir = Read-FolderPath -AllowMissing
        if (-not $dir) { return }
        $scopeLabel = $dir
    }
    Show-Header
    Write-Breadcrumb @('unblock', $scopeLabel)
    Write-Host ''
    Write-Seg @('  matching rules ...', 'Text')
    if ($c -eq 1) { $targets = @(Get-UnblockTargets -Scope 'All') }
    else { $targets = @(Get-UnblockTargets -Scope 'Directory' -Directory $dir) }
    if ($targets.Count -eq 0) {
        Write-Seg @(@("  $($script:G.Warn) ", 'Warn'),
                    @("no FirewallBlocker rules found for $scopeLabel", 'Warn'))
        Wait-AnyKey 'press any key to go back'
        return
    }
    Write-Host ''
    Show-UnblockPreview -Targets $targets -ScopeLabel $scopeLabel
    Write-Host ''
    if ($DryRun) {
        $ok = Read-Confirm @(
            @("Preview $($targets.Count) rule removals? ", 'Text'),
            @('(dry run - nothing will change)', 'Warn')) $true
    } else {
        # destructive count is the only red outside errors/failures
        $ok = Read-Confirm @(
            @('Remove ', 'Text'), @("$($targets.Count)", 'Err'), @(' rules?', 'Text')) $false
    }
    if (-not $ok) { return }
    Write-Host ''
    $verb = 'unblocking'
    if ($DryRun) { $verb = 'dry run' }
    $run = Show-Execute -Verb $verb -FillTok 'Warn' -Total $targets.Count -Runner {
        param($cb)
        Invoke-UnblockRules -Targets $targets -DryRun ([bool]$DryRun) -OnProgress $cb
    }
    Show-Summary -Results $run.Results -Seconds $run.Seconds -Mode 'Unblock' -IsDryRun ([bool]$DryRun)
    Wait-AnyKey 'press any key for menu'
}

#endregion

#region CLI mode

function Write-CliOp {
    param($r)
    $ds = ''
    if ([string]$r.Direction -eq 'Inbound') { $ds = 'In ' }
    elseif ([string]$r.Direction -eq 'Outbound') { $ds = 'Out' }
    switch ($r.Outcome) {
        'Created' { Write-Host "[ OK ] created  $ds  $($r.File)" -ForegroundColor Green }
        'Removed' {
            $suffix = ''
            if ($r.Detail -eq 'legacy v1 rule') { $suffix = ' (legacy v1 rule)' }
            Write-Host "[ OK ] removed  $ds  $($r.File)$suffix" -ForegroundColor Green
        }
        'Skipped' { Write-Host "[SKIP] exists   $ds  $($r.File)" -ForegroundColor DarkGray }
        'Failed'  { Write-Host "[FAIL] $ds  $($r.File) : $($r.Detail)" -ForegroundColor Red }
        'DryRun'  {
            if ($r.Detail -eq 'would remove' -or $r.Detail -eq 'legacy v1 rule') {
                Write-Host "[ DRY] would remove  $ds  $($r.File)" -ForegroundColor Yellow
            } else {
                Write-Host "[ DRY] would create  $ds  $($r.File)" -ForegroundColor Yellow
            }
        }
    }
}

function Invoke-CliMode {
    # List/Rules/-DryRun only read firewall state: no elevation needed
    $mutates = ($Action -eq 'Block' -or $Action -eq 'Unblock') -and -not $DryRun
    if ($mutates -and -not $script:IsAdmin) {
        Write-Host '[FAIL] administrator required' -ForegroundColor Red
        exit 2
    }
    if (-not $script:SvcOk) {
        Write-Host '[FAIL] Windows Firewall service (mpssvc) is not running. fix: Start-Service mpssvc' -ForegroundColor Red
        exit 5
    }
    $dir = $null
    if ($Action -eq 'Block' -or $Action -eq 'List') {
        if (-not $Path) {
            Write-Host "[FAIL] -Path is required for -Action $Action" -ForegroundColor Red
            exit 3
        }
    }
    if ($Path -and $Action -ne 'Rules') {
        # Unblock must work for deleted folders (orphaned rules)
        $res = Resolve-FolderInput $Path -AllowMissing:($Action -eq 'Unblock')
        if (-not $res.Ok) {
            Write-Host "[FAIL] $($res.Error)" -ForegroundColor Red
            exit 3
        }
        $dir = $res.Path
    }
    $cliProgress = {
        param($op, $total, $r)
        Write-CliOp $r
        if (($op % 25) -eq 0 -and $op -lt $total) {
            Write-Host "[INFO] $op/$total ..."
        }
    }
    switch ($Action) {
        'Block' {
            Write-Host "[INFO] scanning $dir ..."
            $scan = Get-ExeFiles -Directory $dir
            $files = @($scan.Files)
            if ($scan.ErrorCount -gt 0) {
                Write-Host "[WARN] $($scan.ErrorCount) folders unreadable (skipped)" -ForegroundColor Yellow
            }
            if ($files.Count -eq 0) {
                Write-Host "[WARN] no .exe files under $dir" -ForegroundColor Yellow
                exit 4
            }
            $existing = Get-FwbRules
            Write-Host "[INFO] $($files.Count) .exe files, $($files.Count * 2) rule operations planned ($($existing.Count) rules already in group)"
            if (-not $NoConfirm -and -not $DryRun) {
                $ans = Read-Host 'Proceed? (y/N)'
                # Read-Host returns $null at stdin EOF (redirected input):
                # treat as No, never fall through to the destructive action
                if (-not $ans -or $ans.Trim() -notmatch '^[yY]') { Write-Host '[INFO] cancelled'; exit 0 }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $results = @(Invoke-BlockRules -Files $files -Existing $existing -DryRun ([bool]$DryRun) -OnProgress $cliProgress)
            $secs = '{0:0.0}s' -f $sw.Elapsed.TotalSeconds
            $created = @($results | Where-Object { $_.Outcome -eq 'Created' }).Count
            $skipped = @($results | Where-Object { $_.Outcome -eq 'Skipped' }).Count
            $failed  = @($results | Where-Object { $_.Outcome -eq 'Failed' }).Count
            $dry     = @($results | Where-Object { $_.Outcome -eq 'DryRun' }).Count
            if ($DryRun) {
                Write-Host "[INFO] dry run: $dry rules would be created, $skipped already exist ($secs)"
                exit 0
            }
            Write-Host "[INFO] done: $created created, $skipped skipped, $failed failed ($secs)"
            if ($failed -gt 0) { exit 1 }
            exit 0
        }
        'Unblock' {
            if ($dir) {
                $label = $dir
                $targets = @(Get-UnblockTargets -Scope 'Directory' -Directory $dir)
            } else {
                $label = 'ALL FirewallBlocker rules'
                $targets = @(Get-UnblockTargets -Scope 'All')
            }
            if ($targets.Count -eq 0) {
                Write-Host "[WARN] no FirewallBlocker rules found for $label" -ForegroundColor Yellow
                exit 4
            }
            $legacy = @($targets | Where-Object { $_.Legacy }).Count
            $msg = "[INFO] $($targets.Count) rules matched ($label)"
            if ($legacy -gt 0) { $msg = "$msg, $legacy legacy v1 rules included" }
            Write-Host $msg
            if (-not $NoConfirm -and -not $DryRun) {
                $ans = Read-Host 'Proceed? (y/N)'
                # Read-Host returns $null at stdin EOF (redirected input):
                # treat as No, never fall through to the destructive action
                if (-not $ans -or $ans.Trim() -notmatch '^[yY]') { Write-Host '[INFO] cancelled'; exit 0 }
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $results = @(Invoke-UnblockRules -Targets $targets -DryRun ([bool]$DryRun) -OnProgress $cliProgress)
            $secs = '{0:0.0}s' -f $sw.Elapsed.TotalSeconds
            $removed = @($results | Where-Object { $_.Outcome -eq 'Removed' }).Count
            $failed  = @($results | Where-Object { $_.Outcome -eq 'Failed' }).Count
            $dry     = @($results | Where-Object { $_.Outcome -eq 'DryRun' }).Count
            if ($DryRun) {
                Write-Host "[INFO] dry run: $dry rules would be removed ($secs)"
                exit 0
            }
            Write-Host "[INFO] done: $removed removed, $failed failed ($secs)"
            if ($failed -gt 0) { exit 1 }
            exit 0
        }
        'List' {
            Write-Host "[INFO] scanning $dir ..."
            $scan = Get-ExeFiles -Directory $dir
            $files = @($scan.Files)
            if ($scan.ErrorCount -gt 0) {
                Write-Host "[WARN] $($scan.ErrorCount) folders unreadable (skipped)" -ForegroundColor Yellow
            }
            if ($files.Count -eq 0) {
                Write-Host "[WARN] no .exe files under $dir" -ForegroundColor Yellow
                exit 4
            }
            $existing = Get-FwbRules
            foreach ($f in $files) {
                $names = Get-RuleNames $f.FullName
                $hasIn = $existing.ContainsKey($names.In)
                $hasOut = $existing.ContainsKey($names.Out)
                if ($hasIn -and $hasOut) { $status = 'blocked' }
                elseif ($hasIn) { $status = 'partial (in only)' }
                elseif ($hasOut) { $status = 'partial (out only)' }
                else { $status = 'none' }
                Write-Host ('[INFO] {0,-18} {1}' -f $status, $f.FullName)
            }
            Write-Host "[INFO] $($files.Count) .exe files under $dir"
            exit 0
        }
        'Rules' {
            $map = Get-RuleProgramMap
            $rules = @($map.Rules)
            if ($rules.Count -eq 0) {
                Write-Host '[WARN] no FirewallBlocker rules exist' -ForegroundColor Yellow
                exit 4
            }
            foreach ($r in @($rules | Sort-Object -Property DisplayName)) {
                if ([string]$r.Direction -eq 'Inbound') { $ds = 'In ' } else { $ds = 'Out' }
                $prog = $map.Programs[$r.Name]
                if (-not $prog) { $prog = '(unknown program)' }
                Write-Host "[INFO] $ds  $($r.DisplayName)  $prog"
            }
            Write-Host "[INFO] $($rules.Count) rules in group $($script:Group)"
            exit 0
        }
    }
}

#endregion

#region Main

$script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
try { $script:SvcOk = ((Get-Service mpssvc -ErrorAction Stop).Status -eq 'Running') }
catch { $script:SvcOk = $false }

# Non-interactive CLI mode dispatches before any TUI work.
if ($PSBoundParameters.ContainsKey('Action')) {
    Invoke-CliMode
    exit 0
}

# TUI mode: a -Path given without -Action seeds the '.' shortcut in the
# folder prompt instead of being silently discarded; -NoConfirm is CLI-only.
if ($Path) {
    $seed = Resolve-FolderInput $Path -AllowMissing
    if ($seed.Ok) { $script:LastPath = $seed.Path }
    else { Write-Host "[WARN] -Path ignored: $($seed.Error)" -ForegroundColor Yellow }
}
if ($NoConfirm) {
    Write-Host '[WARN] -NoConfirm has no effect without -Action' -ForegroundColor Yellow
}

try {
    if (-not $script:IsAdmin) {
        if (-not $script:Tui.Interactive) {
            Write-Host '[FAIL] administrator required' -ForegroundColor Red
            exit 2
        }
        Show-Header
        Show-Card 'Err' 'Err' @(
            'administrator required',
            'firewall rules can only be changed from an elevated shell')
        Write-Host ''
        $relaunch = Read-Confirm @(,@('Relaunch elevated now?', 'Text')) $true
        if ($relaunch) {
            try {
                # single pre-quoted argument string: PS 5.1 Start-Process does
                # not quote array elements that contain spaces. Forward the
                # bound switches so -DryRun survives elevation.
                $argStr = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
                if ($DryRun) { $argStr += ' -DryRun' }
                if ($Plain)  { $argStr += ' -Plain' }
                if ($Path)   { $argStr += " -Path `"$Path`"" }
                Start-Process powershell -Verb RunAs -ArgumentList $argStr
                exit 0
            } catch {
                Write-Host '  x  elevation was declined' -ForegroundColor Red
                exit 2
            }
        }
        exit 2
    }
    if (-not $script:SvcOk) {
        Show-Header
        Show-Card 'Err' 'Err' @(
            'Windows Firewall service (mpssvc) is not running',
            'fix: Start-Service mpssvc')
        Write-Host ''
        if ($script:Tui.Interactive) { Wait-AnyKey 'press any key to exit' }
        exit 5
    }
    while ($true) {
        Show-Header
        $choice = Show-MainMenu
        switch ($choice) {
            1 { Invoke-BlockFlow }
            2 { Invoke-UnblockFlow }
            3 { Show-FileList }
            4 { Show-RuleList }
            5 { exit 0 }
        }
    }
} catch {
    Write-Host ("  x  unexpected error: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($script:Exec.Active) {
        Write-Host ''
        Write-Host ("  x  aborted - $($script:Exec.Done) of $($script:Exec.Total) operations completed") -ForegroundColor Red
    }
    Set-CursorVisible $true
    try { [Console]::ResetColor() } catch { }
}

#endregion
