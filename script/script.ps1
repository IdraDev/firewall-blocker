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

$script:AppTitle = 'FIREWALL BLOCKER v2.0 - By IdraDev'
$script:LastPath = $null
$script:Exec     = @{ Active = $false; Done = 0; Total = 0 }

. (Join-Path $PSScriptRoot 'lib\engine.ps1')
. (Join-Path $PSScriptRoot 'lib\tui.ps1')
. (Join-Path $PSScriptRoot 'lib\cli.ps1')

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
    Write-Seg @('  checking firewall rules ...', 'Text')
    $dirs = Get-BlockedDirections
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
        $d = $dirs[$f.FullName]
        $hasIn = $d -and $d.Inbound
        $hasOut = $d -and $d.Outbound
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
                $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
                if ($DryRun) { $argStr += ' -DryRun' }
                if ($Plain)  { $argStr += ' -Plain' }
                # the space keeps "C:\" from escaping its closing quote; the path is trimmed on read
                if ($Path)   { $argStr += " -Path `"$Path `"" }
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
