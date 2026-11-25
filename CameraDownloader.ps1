# Requires Windows PowerShell 5.1 and reolink-downloader installed for this user.

# Camera inventory: edit these addresses to match your environment.
$CameraIPs = @('192.168.1.101','192.168.1.102','192.168.1.103')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$f = New-Object Windows.Forms.Form
$f.Text = 'Reolink Camera Bulk Downloader v3'
$f.AutoScaleMode = 'None'
$f.Font = New-Object Drawing.Font('Segoe UI',10)
$f.StartPosition = 'CenterScreen'
$f.FormBorderStyle = 'Sizable'
$f.MaximizeBox = $true
$f.AutoScroll = $true
$f.ClientSize = New-Object Drawing.Size(850,790)
$f.MinimumSize = New-Object Drawing.Size(540,420)
$f.SuspendLayout()
$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Top'; $layout.AutoSize = $true; $layout.AutoSizeMode = 'GrowAndShrink'
$layout.ColumnCount = 2; $layout.RowCount = 0; $layout.Padding = New-Object Windows.Forms.Padding(12)
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50))) | Out-Null
$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',50))) | Out-Null
$f.Controls.Add($layout)
function New-Control($type,$text) {
    $c = New-Object "System.Windows.Forms.$type"
    $c.Text=$text; $c.AutoSize=$true
    $c.Margin=New-Object Windows.Forms.Padding(5)
    return $c
}
function Add-Row($left,$right=$null) {
    $index=$layout.RowCount; $layout.RowCount++
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) | Out-Null
    $left.Dock='Fill'; $layout.Controls.Add($left,0,$index)
    if ($null -eq $right) { $layout.SetColumnSpan($left,2) }
    else { $right.Dock='Fill'; $layout.Controls.Add($right,1,$index) }
}
function New-Flow {
    $panel=New-Object Windows.Forms.FlowLayoutPanel
    $panel.AutoSize=$true; $panel.AutoSizeMode='GrowAndShrink'; $panel.WrapContents=$true
    return $panel
}
function New-Button($text) {
    $b=New-Control Button $text; $b.MinimumSize=New-Object Drawing.Size(115,34); return $b
}
Add-Row (New-Control Label 'Select cameras')
$cameraPanel=New-Flow; $checks=@()
foreach ($ip in $CameraIPs) {
    $c=New-Control CheckBox $ip; $c.Checked=$true; $cameraPanel.Controls.Add($c); $checks += $c
}
Add-Row $cameraPanel
Add-Row (New-Control Label 'Start date') (New-Control Label 'End date (inclusive)')
$start=New-Control DateTimePicker ''; $end=New-Control DateTimePicker ''
foreach ($d in @($start,$end)) { $d.Format='Custom'; $d.CustomFormat='yyyy-MM-dd' }
$start.Value=(Get-Date).Date.AddDays(-1); $end.Value=(Get-Date).Date
Add-Row $start $end
Add-Row (New-Control Label 'Username') (New-Control Label 'Password')
$user=New-Control TextBox ''; $pass=New-Control TextBox ''; $pass.UseSystemPasswordChar=$true
Add-Row $user $pass
Add-Row (New-Control Label 'Destination (separate folder per camera)')
$dest=New-Control TextBox 'C:\CameraFTP'; $browse=New-Button 'Browse...'
Add-Row $dest $browse
$buttons=New-Flow; $go=New-Button 'Download'; $open=New-Button 'Open folder'; $cancel=New-Button 'Cancel All'; $cancel.Enabled=$false
foreach ($button in @($go,$open,$cancel)) { $buttons.Controls.Add($button) }
Add-Row $buttons
$status=New-Control Label 'Ready'; Add-Row $status
$bar=New-Object Windows.Forms.ProgressBar; $bar.Height=18; Add-Row $bar
$script:rows=@()
foreach ($ip in $CameraIPs) {
    $label=New-Control Label "$ip - Ready"; $folderButton=New-Button 'Open folder'; $folderButton.Tag=$ip
    $folderButton.Add_Click({ param($sender,$e)
        $path=Join-Path $dest.Text $sender.Tag
        if (Test-Path -LiteralPath $path -PathType Container) { Invoke-Item -LiteralPath $path }
        else { [Windows.Forms.MessageBox]::Show('Folder does not exist yet.') | Out-Null }
    })
    Add-Row $label $folderButton
    $activity=New-Object Windows.Forms.ProgressBar; $activity.Height=16; Add-Row $activity
    $detail=New-Control Label 'No files counted yet'; Add-Row $detail
    $script:rows += [pscustomobject]@{IP=$ip; Label=$label; Bar=$activity; Detail=$detail; Folder=''; Proc=$null; OutTask=$null; ErrTask=$null; OutClosed=$false; ErrClosed=$false; State='Ready'; Count=0; Bytes=0; CancelRequested=$false}
}
Add-Row (New-Control Label 'Download activity')
$log=New-Object Windows.Forms.TextBox
$log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Both'; $log.WordWrap=$false
$log.Font=New-Object Drawing.Font('Consolas',10); $log.Height=150; $log.MinimumSize=New-Object Drawing.Size(0,150)
Add-Row $log
$f.ResumeLayout($true)
$script:busy=$false; $script:ticks=0; $script:selected=@()
$timer=New-Object Windows.Forms.Timer; $timer.Interval=150
function Log-Line($s) {
    if ($log.TextLength -gt 100000) { $log.Clear() }
    $log.AppendText("$s`r`n")
}
function Quote-Argument([string]$s) {
    return '"' + [regex]::Replace([regex]::Replace($s,'(\\*)"','$1$1\"'),'(\\+)$','$1$1') + '"'
}

function Set-Busy([bool]$busy) {
    $script:busy=$busy
    foreach ($c in ($checks + @($start,$end,$user,$pass,$dest,$browse,$go))) { $c.Enabled=(!$busy) }
    $cancel.Enabled=$busy
}
function Set-State($r,[string]$state) {
    $r.State=$state; $r.Label.Text="$($r.IP) - $state"
    if ($state -eq 'Downloading') { $r.Bar.Style='Marquee'; $r.Bar.MarqueeAnimationSpeed=30 }
    else { $r.Bar.Style='Blocks'; if ($state -eq 'Completed') { $r.Bar.Value=100 } else { $r.Bar.Value=0 } }
}
function Update-Counts($r) {
    if (!$r.Folder -or !(Test-Path -LiteralPath $r.Folder)) { return }
    try {
        $m=Get-ChildItem -LiteralPath $r.Folder -File -Recurse -ErrorAction Stop | Measure-Object -Property Length -Sum
        $r.Count=$m.Count; $r.Bytes=[long]$m.Sum
        $r.Detail.Text=('{0:N0} files in folder | {1:N2} GB on disk' -f $r.Count,($r.Bytes / 1GB))
    } catch { $r.Detail.Text='Folder totals temporarily unavailable' }
}
function Start-Camera($r,$exe,$root,$username,$password,$from,$to) {
    try {
        $r.Folder=Join-Path $root $r.IP
        New-Item -ItemType Directory -Path $r.Folder -Force -ErrorAction Stop | Out-Null
        $argsList=@('--ip',$r.IP,'--username',$username,'--password',$password,'--start-time',$from,'--end-time',$to,'--output',$r.Folder)
        $psi=New-Object Diagnostics.ProcessStartInfo
        $psi.FileName=$exe; $psi.Arguments=(($argsList | ForEach-Object { Quote-Argument $_ }) -join ' ')
        $psi.WorkingDirectory=$r.Folder
        $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
        $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
        $psi.EnvironmentVariables['PYTHONUNBUFFERED']='1'
        $r.Proc=New-Object Diagnostics.Process; $r.Proc.StartInfo=$psi
        if (!$r.Proc.Start()) { throw 'Could not start downloader.' }
        $r.OutClosed=$false; $r.ErrClosed=$false
        $r.OutTask=$r.Proc.StandardOutput.ReadLineAsync(); $r.ErrTask=$r.Proc.StandardError.ReadLineAsync()
        Set-State $r 'Downloading'; Log-Line "[$($r.IP)] Started -> $($r.Folder)"
    } catch {
        if ($r.Proc) { try { if (!$r.Proc.HasExited) { $r.Proc.Kill() } } catch {}; $r.Proc.Dispose(); $r.Proc=$null }
        Set-State $r 'Failed'; Log-Line "[$($r.IP)] Could not start downloader or create folder."
    }
}
function Stop-Downloads {
    foreach ($r in $script:selected) {
        if ($r.Proc -and !$r.Proc.HasExited) {
            $r.CancelRequested=$true
            try {
                # uv launchers may spawn a child Python process; terminate the tree.
                & "$env:SystemRoot\System32\taskkill.exe" /PID $r.Proc.Id /T /F 2>&1 | Out-Null
                if (!$r.Proc.HasExited) { $r.Proc.Kill() }
            } catch { Log-Line "[$($r.IP)] Cancellation failed; waiting for process to exit." }
        }
    }
    $cancel.Enabled=$false
}
$cancel.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('Stop all active downloads? Partial files may remain.','Cancel downloads','YesNo','Warning') -eq 'Yes') { Stop-Downloads }
})
$timer.Add_Tick({
    $script:ticks++
    foreach ($r in $script:selected) {
        if (!$r.Proc) { continue }
        for ($n=0; $n -lt 60 -and !$r.OutClosed -and $r.OutTask.IsCompleted; $n++) {
            try { $line=$r.OutTask.GetAwaiter().GetResult(); if ($null -eq $line) { $r.OutClosed=$true } else { Log-Line "[$($r.IP)] $line"; $r.OutTask=$r.Proc.StandardOutput.ReadLineAsync() } } catch { $r.OutClosed=$true }
        }
        for ($n=0; $n -lt 60 -and !$r.ErrClosed -and $r.ErrTask.IsCompleted; $n++) {
            try { $line=$r.ErrTask.GetAwaiter().GetResult(); if ($null -eq $line) { $r.ErrClosed=$true } else { Log-Line "[$($r.IP)] $line"; $r.ErrTask=$r.Proc.StandardError.ReadLineAsync() } } catch { $r.ErrClosed=$true }
        }
        if ($script:ticks % 40 -eq 0) { Update-Counts $r }
        if ($r.Proc.HasExited -and $r.OutClosed -and $r.ErrClosed) {
            $code=$r.Proc.ExitCode; $r.Proc.Dispose(); $r.Proc=$null
            if ($r.CancelRequested) { Set-State $r 'Cancelled' }
            elseif ($code -eq 0) { Set-State $r 'Completed' }
            else { Set-State $r "Failed ($code)" }
            Update-Counts $r; Log-Line "[$($r.IP)] $($r.State)"
        }
    }
    $running=@($script:selected | Where-Object { $_.Proc }).Count
    $bar.Value=$script:selected.Count-$running
    $status.Text="Active downloads: $running of $($script:selected.Count)"
    if ($running -eq 0) {
        $timer.Stop(); Set-Busy $false
        $ok=@($script:selected | Where-Object State -eq 'Completed').Count
        $stopped=@($script:selected | Where-Object State -eq 'Cancelled').Count
        $failed=$script:selected.Count-$ok-$stopped
        $status.Text="Finished: $ok completed, $failed failed, $stopped cancelled"
        Log-Line $status.Text
    }
})
$browse.Add_Click({
    $dlg=New-Object Windows.Forms.FolderBrowserDialog
    if (Test-Path -LiteralPath $dest.Text -PathType Container) { $dlg.SelectedPath=$dest.Text }
    if ($dlg.ShowDialog($f) -eq 'OK') { $dest.Text=$dlg.SelectedPath }; $dlg.Dispose()
})
$open.Add_Click({
    if (Test-Path -LiteralPath $dest.Text -PathType Container) { Invoke-Item -LiteralPath $dest.Text } else { [Windows.Forms.MessageBox]::Show('The destination does not exist yet.') | Out-Null }
})

$go.Add_Click({
    $selectedIPs=@($checks | Where-Object Checked | ForEach-Object Text)
    if (!$selectedIPs.Count -or !$user.Text.Trim() -or !$pass.Text -or !$dest.Text.Trim() -or $start.Value.Date -gt $end.Value.Date) { [Windows.Forms.MessageBox]::Show('Select a camera, enter credentials and destination, and choose a valid date range.') | Out-Null; return }
    $cmd=Get-Command reolink-downloader.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$cmd) { [Windows.Forms.MessageBox]::Show('reolink-downloader.exe not found on PATH. Run as the user who installed it and restart PowerShell.') | Out-Null; return }
    try { $root=[IO.Path]::GetFullPath($dest.Text); New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null; $dest.Text=$root } catch { [Windows.Forms.MessageBox]::Show('Cannot create destination folder.') | Out-Null; return }
    $script:selected=@($script:rows | Where-Object { $_.IP -in $selectedIPs })
    foreach ($r in $script:rows) { Set-State $r 'Not selected'; $r.Detail.Text=''; $r.CancelRequested=$false }
    $from=$start.Value.ToString('yyyy-MM-dd')+' 00:00:00'; $to=$end.Value.ToString('yyyy-MM-dd')+' 23:59:59'
    $bar.Value=0; $bar.Maximum=$script:selected.Count; $log.Clear(); Set-Busy $true; $script:ticks=0
    foreach ($r in $script:selected) { Start-Camera $r $cmd.Source $root $user.Text.Trim() $pass.Text $from $to }
    $pass.Clear(); $timer.Start()
})
$f.Add_FormClosing({ param($sender,$e) if ($script:busy) { $e.Cancel=$true; [Windows.Forms.MessageBox]::Show('Cancel active downloads or wait for them to finish before closing.') | Out-Null } })
[void]$f.ShowDialog(); $timer.Dispose(); $f.Dispose()
