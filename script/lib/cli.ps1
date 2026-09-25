#region CLI mode

function Write-CliOp {
    param($r)
    $ds = ''
    if ([string]$r.Direction -eq 'Inbound') { $ds = 'In ' }
    elseif ([string]$r.Direction -eq 'Outbound') { $ds = 'Out' }
    switch ($r.Outcome) {
        'Created' { Write-Host "[ OK ] created  $ds  $($r.File)" -ForegroundColor Green }
        'Enabled' { Write-Host "[ OK ] enabled  $ds  $($r.File)  (was paused)" -ForegroundColor Green }
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
            } elseif ($r.Detail -eq 'would enable') {
                Write-Host "[ DRY] would enable  $ds  $($r.File)" -ForegroundColor Yellow
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
            $enabled = @($results | Where-Object { $_.Outcome -eq 'Enabled' }).Count
            $skipped = @($results | Where-Object { $_.Outcome -eq 'Skipped' }).Count
            $failed  = @($results | Where-Object { $_.Outcome -eq 'Failed' }).Count
            $dry     = @($results | Where-Object { $_.Outcome -eq 'DryRun' }).Count
            if ($DryRun) {
                Write-Host "[INFO] dry run: $dry rules would be created or re-enabled, $skipped already exist ($secs)"
                exit 0
            }
            Write-Host "[INFO] done: $created created, $enabled re-enabled, $skipped skipped, $failed failed ($secs)"
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
            $dirs = Get-BlockedDirections
            foreach ($f in $files) {
                $status = Get-FileStatus $dirs $f.FullName
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
