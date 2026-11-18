function Get-WinUtilSecurityPaths {
    <#
    .SYNOPSIS
        Returns the data folder of the Sicurezza tab, creating config.json on first use
    #>

    $securityHome = Join-Path $env:LOCALAPPDATA "WinRUtil\Sicurezza"
    if (-not (Test-Path -LiteralPath $securityHome)) {
        New-Item -ItemType Directory -Path $securityHome -Force | Out-Null
    }

    $configPath = Join-Path $securityHome "config.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        # Keep the banks and the allowed items set up with the former standalone CyberRSecurityCheck
        $legacyConfig = Join-Path $env:LOCALAPPDATA "CyberRSecurityCheck\config.json"
        if (Test-Path -LiteralPath $legacyConfig) {
            Copy-Item -LiteralPath $legacyConfig -Destination $configPath -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $configPath) -and $sync.SecurityConfigDefault) {
            [System.IO.File]::WriteAllText($configPath, $sync.SecurityConfigDefault, [System.Text.UTF8Encoding]::new($false))
        }
    }

    return [pscustomobject]@{
        Home    = $securityHome
        Config  = $configPath
        Reports = Join-Path $securityHome "Report"
    }
}

function Write-WinUtilSecurityLog {
    <#
    .SYNOPSIS
        Appends lines to the log of the Sicurezza tab (UI thread only)
    #>
    param([string[]]$Lines)

    $logBox = $sync.WPFSecurityLog
    if (-not $logBox -or $Lines.Count -eq 0) { return }
    $text = $Lines -join "`r`n"
    if ($sync.SecurityLogFresh) {
        $logBox.Text = $text
        $sync.SecurityLogFresh = $false
    } else {
        $logBox.AppendText("`r`n$text")
    }
    $logBox.ScrollToEnd()
}

function Set-WinUtilSecurityBusy {
    <#
    .SYNOPSIS
        Enables or disables the controls that start an analysis
    #>
    param([bool]$Busy)

    foreach ($name in @("WPFSecurityFull", "WPFSecurityClipTest", "WPFSecurityMonitor", "WPFSecurityMonitorMinutes", "WPFSecurityFast")) {
        if ($sync[$name]) { $sync[$name].IsEnabled = -not $Busy }
    }
}

function Start-WinUtilSecurityScan {
    <#
    .SYNOPSIS
        Starts the security check in its own STA runspace and follows it from the Sicurezza tab

    .PARAMETER Mode
        Completo (full analysis with clipboard test), ClipTest or Monitor
    #>
    param(
        [ValidateSet("Completo", "Raccolta", "ClipTest", "Monitor")]
        [string]$Mode = "Completo"
    )

    if ($sync.SecurityRun -and $sync.SecurityRun.Phase -eq "running") { return }
    if (-not $sync.SecurityEngine) {
        Write-WinUtilSecurityLog @("Il motore dell'analisi non $([char]0x00E8) disponibile in questa copia di WinRUtil.")
        return
    }

    $paths = Get-WinUtilSecurityPaths
    $minutes = 30
    if ($Mode -eq "Monitor" -and $sync.WPFSecurityMonitorMinutes.SelectedItem) {
        $minutes = [int]$sync.WPFSecurityMonitorMinutes.SelectedItem.Tag
    }

    # Shared with the engine: it writes progress, log lines and the result here
    $progress = [hashtable]::Synchronized(@{
        Log = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        Step = 0; Total = 1; Name = ""; Percent = 0; Done = $false; Cancel = $false
        Result = $null; Error = $null; LastAlert = $null; Alerts = 0
    })

    # The clipboard test needs a single-threaded apartment
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    [void]$shell.AddScript($sync.SecurityEngine)
    [void]$shell.AddParameter("Mode", $Mode)
    [void]$shell.AddParameter("NoOpen", $true)
    [void]$shell.AddParameter("ProgressSync", $progress)
    [void]$shell.AddParameter("ExcludePids", [int[]]@($PID))
    [void]$shell.AddParameter("OutputPath", $paths.Reports)
    [void]$shell.AddParameter("ConfigPath", $paths.Config)
    [void]$shell.AddParameter("AppVersion", [string]$sync.version)
    if ($Mode -eq "Monitor") { [void]$shell.AddParameter("MonitorMinutes", $minutes) }
    if ($sync.WPFSecurityFast.IsChecked) { [void]$shell.AddParameter("SkipMemory", $true) }

    $sync.SecurityRun = @{
        Phase      = "running"
        Mode       = $Mode
        Minutes    = $minutes
        Progress   = $progress
        PowerShell = $shell
        Runspace   = $runspace
        Handle     = $shell.BeginInvoke()
        Started    = Get-Date
        LogIndex    = 0
        Cancelled   = $false
        AlertRaised = $false
    }

    $titles = @{
        Completo = "Analisi completa in corso"
        Raccolta = "Analisi in corso"
        ClipTest = "Test degli appunti in corso"
        Monitor  = "Monitor attivo: ora esegui il bonifico come al solito"
    }
    $sync.WPFSecurityRunTitle.Text = $titles[$Mode]
    $sync.WPFSecurityStep.Text = "Preparazione..."
    $sync.WPFSecurityPercent.Text = "0%"
    $sync.WPFSecurityProgress.Value = 0
    $sync.WPFSecurityElapsed.Text = "00:00"
    $sync.WPFSecurityCancel.Content = $(if ($Mode -eq "Monitor") { "Termina monitor" } else { "Interrompi" })
    $sync.WPFSecurityCancel.IsEnabled = $true
    $sync.WPFSecurityCancel.Visibility = "Visible"
    $sync.WPFSecurityRunPanel.Visibility = "Visible"
    $sync.WPFSecuritySummary.Visibility = "Collapsed"
    $sync.WPFSecurityFindingsPanel.Visibility = "Collapsed"
    $sync.WPFSecurityAlert.Visibility = "Collapsed"
    $sync.SecurityLogFresh = $true
    $sync.WPFSecurityLog.Text = ""
    Set-WinUtilSecurityBusy -Busy $true
    Set-WinUtilTaskbaritem -state "Normal" -value 0.01

    if (-not $sync.SecurityTimer) {
        $sync.SecurityTimer = New-Object System.Windows.Threading.DispatcherTimer
        $sync.SecurityTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $sync.SecurityTimer.Add_Tick({ Update-WinUtilSecurityView })
    }
    $sync.SecurityTimer.Start()
}

function Update-WinUtilSecurityView {
    <#
    .SYNOPSIS
        Shows the progress of the running analysis (called by a DispatcherTimer on the UI thread)
    #>

    $run = $sync.SecurityRun
    if (-not $run -or $run.Phase -ne "running") {
        if ($sync.SecurityTimer) { $sync.SecurityTimer.Stop() }
        return
    }
    $progress = $run.Progress

    $count = $progress.Log.Count
    if ($count -gt $run.LogIndex) {
        $lines = [System.Collections.Generic.List[string]]::new()
        for ($i = $run.LogIndex; $i -lt $count; $i++) {
            $entry = $progress.Log[$i]
            $lines.Add(("{0}  {1}" -f $entry.Ora, $entry.Testo))
        }
        $run.LogIndex = $count
        Write-WinUtilSecurityLog -Lines $lines.ToArray()
    }

    $total = [int]$progress["Total"]
    $name = [string]$progress["Name"]
    if ($name) {
        if ($total -gt 1) {
            $sync.WPFSecurityStep.Text = "Passo {0} di {1}: {2}" -f [int]$progress["Step"], $total, $name
        } else {
            $sync.WPFSecurityStep.Text = $name
        }
    }
    $elapsed = (Get-Date) - $run.Started
    $percent = [Math]::Max(0, [Math]::Min(100, [int]$progress["Percent"]))
    if ($run.Mode -eq "ClipTest") {
        # The clipboard test is a single step of about 30 seconds: show the time instead
        $percent = [int][Math]::Min(95, $elapsed.TotalSeconds * 100 / 32)
    }
    $sync.WPFSecurityProgress.Value = $percent
    $sync.WPFSecurityPercent.Text = "$percent%"
    $sync.WPFSecurityElapsed.Text = "{0:00}:{1:00}" -f [Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    if ($progress["LastAlert"]) {
        $sync.WPFSecurityAlertText.Text = "ATTENZIONE: {0}. NON confermare il bonifico." -f ([string]$progress["LastAlert"]).TrimEnd(".")
        $sync.WPFSecurityAlert.Visibility = "Visible"
        if (-not $run.AlertRaised) {
            # The customer is looking at the bank page: bring WinRUtil forward and make it noticed
            $run.AlertRaised = $true
            [System.Media.SystemSounds]::Exclamation.Play()
            if ($sync.Form.WindowState -eq [System.Windows.WindowState]::Minimized) {
                $sync.Form.WindowState = [System.Windows.WindowState]::Normal
            }
            $null = $sync.Form.Activate()
        }
    }
    if ($run.AlertRaised) {
        Set-WinUtilTaskbaritem -state "Error" -value 1
    } else {
        Set-WinUtilTaskbaritem -state "Normal" -value ([Math]::Max(0.01, $percent / 100))
    }

    # The engine sets Done just before its pipeline ends: wait for the pipeline itself
    if ($run.Handle.IsCompleted) {
        Complete-WinUtilSecurityScan
    }
}

function Stop-WinUtilSecurityRunspace {
    <#
    .SYNOPSIS
        Releases the runspace of the analysis without waiting for it
    #>

    $run = $sync.SecurityRun
    if (-not $run) { return }
    if (-not $run.Handle.IsCompleted) {
        # Stopping waits for the running native call: let it end on its own thread
        try {
            $null = $run.PowerShell.BeginStop($null, $null)
        } catch {
            Write-Debug "Security check could not be stopped: $($_.Exception.Message)"
        }
        return
    }
    try {
        $null = $run.PowerShell.EndInvoke($run.Handle)
    } catch {
        Write-Debug "Security check ended with an error: $($_.Exception.Message)"
    } finally {
        $run.PowerShell.Dispose()
        $run.Runspace.Dispose()
    }
}

function Complete-WinUtilSecurityScan {
    <#
    .SYNOPSIS
        Shows the result of the finished analysis and records it for the intervention report
    #>

    $run = $sync.SecurityRun
    $sync.SecurityTimer.Stop()
    $progress = $run.Progress

    # Log lines written after the last tick
    $count = $progress.Log.Count
    if ($count -gt $run.LogIndex) {
        $lines = [System.Collections.Generic.List[string]]::new()
        for ($i = $run.LogIndex; $i -lt $count; $i++) {
            $lines.Add(("{0}  {1}" -f $progress.Log[$i].Ora, $progress.Log[$i].Testo))
        }
        $run.LogIndex = $count
        Write-WinUtilSecurityLog -Lines $lines.ToArray()
    }

    $errorText = [string]$progress["Error"]
    if (-not $errorText -and $run.PowerShell.Streams.Error.Count -gt 0) {
        $errorText = [string]$run.PowerShell.Streams.Error[0]
    }
    Stop-WinUtilSecurityRunspace
    $run.Phase = "done"
    Set-WinUtilSecurityBusy -Busy $false
    Set-WinUtilTaskbaritem -state "None"

    $modeNames = @{
        Completo = "Analisi di sicurezza"
        Raccolta = "Analisi di sicurezza"
        ClipTest = "Test degli appunti (sostituzione dell'IBAN)"
        Monitor  = "Monitor durante il bonifico ($($run.Minutes) minuti)"
    }
    $modeName = $modeNames[$run.Mode]

    $result = $progress["Result"]
    if (-not $result) {
        if (-not $errorText) { $errorText = "analisi terminata senza risultati" }
        $sync.WPFSecurityRunTitle.Text = "Analisi non riuscita"
        $sync.WPFSecurityStep.Text = $errorText
        $sync.WPFSecurityCancel.Visibility = "Collapsed"
        Write-WinUtilSecurityLog @("Analisi non riuscita: $errorText")
        Add-WinUtilSessionAction -Area "Sicurezza" -Text $modeName -Status "Error"
        return
    }

    $sync.SecurityResult = $result
    $summary = $result.Summary
    $sync.WPFSecurityRunPanel.Visibility = "Collapsed"
    $sync.WPFSecuritySummary.Visibility = "Visible"

    $colorKey = "DangerColor"
    if ($summary.Punteggio -ge 85) { $colorKey = "SuccessColor" }
    elseif ($summary.Punteggio -ge 60) { $colorKey = "WarningColor" }
    if ($summary.Incompleta -and $summary.Alta -eq 0) { $colorKey = "MutedForegroundColor" }
    $sync.WPFSecurityScore.Text = [string]$summary.Punteggio
    $sync.WPFSecurityScore.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $colorKey)
    $sync.WPFSecurityVerdict.Text = [string]$summary.Giudizio
    $sync.WPFSecurityVerdict.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $colorKey)
    $sync.WPFSecurityMessage.Text = [string]$summary.Messaggio

    # One list for the tab: confirmed problems, items to check, settings to fix, technical details
    $items = [System.Collections.Generic.List[object]]::new()
    $labels = @{ ALTA = "CONFERMATO"; MEDIA = "DA CONTROLLARE"; BASSA = "DETTAGLIO" }
    foreach ($severity in @("ALTA", "MEDIA")) {
        foreach ($finding in @($result.Findings)) {
            if ($finding.Gravita -ne $severity) { continue }
            $items.Add([pscustomobject]@{
                Kind = $severity; Label = $labels[$severity]; Title = [string]$finding.Titolo
                Area = [string]$finding.Categoria; Detail = (Get-WinUtilSecurityShortText $finding.Dettaglio); Advice = [string]$finding.Consiglio
            })
        }
    }
    $toFix = 0
    foreach ($row in @($result.Hardening)) {
        if ($row.Stato -ne "CRITICO") { continue }
        $toFix++
        $items.Add([pscustomobject]@{
            Kind = "CRIT"; Label = "DA CORREGGERE"; Title = [string]$row.Controllo
            Area = [string]$row.Area; Detail = (Get-WinUtilSecurityShortText $row.Valore); Advice = [string]$row.Consiglio
        })
    }
    $details = 0
    foreach ($finding in @($result.Findings)) {
        if ($finding.Gravita -ne "BASSA") { continue }
        $details++
        $items.Add([pscustomobject]@{
            Kind = "BASSA"; Label = $labels["BASSA"]; Title = [string]$finding.Titolo
            Area = [string]$finding.Categoria; Detail = (Get-WinUtilSecurityShortText $finding.Dettaglio); Advice = [string]$finding.Consiglio
        })
    }
    $sync.SecurityItems = $items.ToArray()

    $sectionsOk = 0
    foreach ($section in @($result.Sections)) { if ($section.Stato -eq "OK") { $sectionsOk++ } }
    $sync.WPFSecurityCountConfirmed.Text = [string]$summary.Alta
    $sync.WPFSecurityCountCheck.Text = [string]$summary.Media
    $sync.WPFSecurityCountFix.Text = [string]$toFix
    $sync.WPFSecurityCountSections.Text = "{0}/{1}" -f $sectionsOk, @($result.Sections).Count

    $location = "Rapporto salvato in: $($result.OutDir)"
    if ($result.Zip) { $location += "`r`nArchivio da conservare come prova: $($result.Zip)" }
    $sync.WPFSecurityReportPath.Text = $location
    $sync.WPFSecurityOpenReport.IsEnabled = [bool]($result.Html -and (Test-Path -LiteralPath $result.Html))

    $sync.WPFSecurityShowDetails.Content = "Mostra dettagli tecnici ($details)"
    $sync.WPFSecurityShowDetails.Visibility = $(if ($details -gt 0) { "Visible" } else { "Collapsed" })
    $sync.WPFSecurityFindingsPanel.Visibility = "Visible"
    Update-WinUtilSecurityFindings

    $text = "{0}: {1}" -f $modeName, $summary.Messaggio
    if ($run.Mode -in @("Completo", "Raccolta")) {
        $text = "{0}: punteggio {1}/100 ({2}). {3}" -f $modeName, $summary.Punteggio, $summary.Giudizio, $summary.Messaggio
    }
    if ($run.Cancelled) { $text += " Interrotta prima della fine." }
    Add-WinUtilSessionAction -Area "Sicurezza" -Text $text
}

function Get-WinUtilSecurityShortText {
    <#
    .SYNOPSIS
        Shortens a detail for the tab: the full text stays in the HTML report
    #>
    param([string]$Text)

    if ($Text.Length -le 500) { return $Text }
    return $Text.Substring(0, 500) + "... (testo completo nel rapporto)"
}

function Update-WinUtilSecurityFindings {
    <#
    .SYNOPSIS
        Fills the list of findings, with the technical details only when they are requested
    #>

    # The list is not virtualized: past this many technical details the report is the place to read them
    $detailLimit = 200
    $showDetails = [bool]$sync.WPFSecurityShowDetails.IsChecked
    $visible = [System.Collections.Generic.List[object]]::new()
    $problems = 0
    $details = 0
    foreach ($item in @($sync.SecurityItems)) {
        if ($null -eq $item) { continue }
        if ($item.Kind -ne "BASSA") {
            $problems++
            $visible.Add($item)
        } elseif ($showDetails) {
            $details++
            if ($details -le $detailLimit) { $visible.Add($item) }
        }
    }
    if ($details -gt $detailLimit) {
        $visible.Add([pscustomobject]@{
            Kind = "BASSA"; Label = "DETTAGLIO"; Area = ""; Advice = ""
            Title = "Altri {0} dettagli tecnici" -f ($details - $detailLimit)
            Detail = "Sono elencati tutti nel rapporto completo."
        })
    }
    $sync.WPFSecurityFindings.ItemsSource = $visible.ToArray()
    $sync.WPFSecurityNoFindings.Visibility = $(if ($problems -eq 0) { "Visible" } else { "Collapsed" })
}

function Invoke-WPFSecurityCancel {
    <#
    .SYNOPSIS
        Asks the running analysis to stop: the report of what was checked is still written
    #>

    $run = $sync.SecurityRun
    if (-not $run -or $run.Phase -ne "running") { return }
    $run.Cancelled = $true
    $run.Progress["Cancel"] = $true
    $sync.WPFSecurityCancel.IsEnabled = $false
    $sync.WPFSecurityCancel.Content = "Interruzione in corso..."
}

function Confirm-WinUtilSecurityClose {
    <#
    .SYNOPSIS
        Returns $false when the user keeps WinRUtil open because an analysis is running
    #>

    $run = $sync.SecurityRun
    if (-not $run -or $run.Phase -ne "running") { return $true }
    $answer = [System.Windows.MessageBox]::Show(
        "$([char]0x00C8) in corso un'analisi di sicurezza. Chiudere WinRUtil e interromperla?",
        "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return $false }
    $run.Progress["Cancel"] = $true
    if ($sync.SecurityTimer) { $sync.SecurityTimer.Stop() }
    Stop-WinUtilSecurityRunspace
    $run.Phase = "done"
    return $true
}

function Find-WinUtilAppBrowser {
    <#
    .SYNOPSIS
        Returns the path of a correctly signed Edge or Chrome, or $null
    #>

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if ($base) { $candidates.Add((Join-Path $base "Microsoft\Edge\Application\msedge.exe")) }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($base) { $candidates.Add((Join-Path $base "Google\Chrome\Application\chrome.exe")) }
    }
    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        # Per-user installs are writable by any program: only the real Microsoft or Google binary is used
        if ($signature.Status -eq "Valid" -and $signature.SignerCertificate.Subject -match 'O="?(Microsoft Corporation|Google LLC)"?,') {
            return $path
        }
    }
    return $null
}

function Invoke-WPFSecurityOpenReport {
    <#
    .SYNOPSIS
        Opens the HTML report in an Edge/Chrome window with a temporary profile and no extensions,
        so that a malicious extension on the PC cannot read or alter it
    #>

    $result = $sync.SecurityResult
    if (-not $result -or -not (Test-Path -LiteralPath $result.Html)) { return }
    $browser = Find-WinUtilAppBrowser
    if (-not $browser) {
        Start-Process -FilePath $result.Html
        return
    }
    # Profiles left by earlier sessions (a report window was still open when WinRUtil closed)
    $tempPath = [System.IO.Path]::GetTempPath()
    foreach ($oldProfile in @(Get-ChildItem -LiteralPath $tempPath -Directory -Filter "WinRUtilReport_*" -ErrorAction SilentlyContinue)) {
        if ($oldProfile.LastWriteTime -lt (Get-Date).AddDays(-1)) {
            Remove-Item -LiteralPath $oldProfile.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $profileDir = Join-Path $tempPath ("WinRUtilReport_" + [guid]::NewGuid().ToString("N").Substring(0, 12))
    if (-not $sync.SecurityBrowserProfiles) { $sync.SecurityBrowserProfiles = [System.Collections.Generic.List[string]]::new() }
    $sync.SecurityBrowserProfiles.Add($profileDir)
    $arguments = @(
        "--app=$(([Uri]$result.Html).AbsoluteUri)", "--user-data-dir=`"$profileDir`"", "--no-first-run",
        "--no-default-browser-check", "--disable-extensions", "--disable-sync", "--disable-background-networking",
        "--disable-component-update", "--window-size=1200,880"
    )
    Start-Process -FilePath $browser -ArgumentList $arguments
}

function Remove-WinUtilSecurityBrowserProfiles {
    <#
    .SYNOPSIS
        Deletes the temporary browser profiles used to show the reports
    #>

    foreach ($profileDir in @($sync.SecurityBrowserProfiles)) {
        if ($profileDir -and (Test-Path -LiteralPath $profileDir)) {
            Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WPFSecurityOpenFolder {
    <#
    .SYNOPSIS
        Opens the folder of the last report, or the folder with all the reports
    #>
    param([switch]$LastReport)

    $folder = (Get-WinUtilSecurityPaths).Reports
    if ($LastReport -and $sync.SecurityResult -and (Test-Path -LiteralPath $sync.SecurityResult.OutDir)) {
        $folder = $sync.SecurityResult.OutDir
    }
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$folder`""
}

function Invoke-WPFSecurityEditConfig {
    <#
    .SYNOPSIS
        Opens config.json of the Sicurezza tab (bank domains and allowed items) in Notepad
    #>

    $paths = Get-WinUtilSecurityPaths
    Start-Process -FilePath "notepad.exe" -ArgumentList "`"$($paths.Config)`""
}

function Invoke-WinUtilSecurityConsole {
    <#
    .SYNOPSIS
        Runs the full security check in the console (-Sicurezza -Noui)
    #>

    if (-not $sync.SecurityEngine) {
        Write-Host "The security check engine is not available in this copy of WinRUtil." -ForegroundColor Red
        return
    }
    $paths = Get-WinUtilSecurityPaths
    # Own runspace on this console: the engine's script-scoped variables (e.g. $script:Sync) must not
    # overwrite WinRUtil's $sync, and the clipboard test needs a single-threaded apartment
    $runspace = [runspacefactory]::CreateRunspace($Host)
    $runspace.ApartmentState = "STA"
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    try {
        [void]$shell.AddScript($sync.SecurityEngine)
        [void]$shell.AddParameter("Mode", "Completo")
        [void]$shell.AddParameter("NoOpen", $true)
        [void]$shell.AddParameter("OutputPath", $paths.Reports)
        [void]$shell.AddParameter("ConfigPath", $paths.Config)
        [void]$shell.AddParameter("AppVersion", [string]$sync.version)
        $null = $shell.Invoke()
        foreach ($record in $shell.Streams.Error) { Write-Host $record -ForegroundColor Red }
    } finally {
        $shell.Dispose()
        $runspace.Dispose()
    }
}
