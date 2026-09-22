# Console rendering and input primitives for the interactive TUI.

#region Capability probe

$script:Spinner  = @('|','/','-','\')

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
