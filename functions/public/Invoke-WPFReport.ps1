function Write-WinUtilReportLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Report tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFReportLog
    if (-not $logBox) {
        Write-Host $line
        return
    }

    $action = {
        if ([string]::IsNullOrWhiteSpace($logBox.Text) -or $logBox.Text -like "Pronto.*") {
            $logBox.Text = $line
        } else {
            $logBox.AppendText("`r`n$line")
        }
        $logBox.ScrollToEnd()
    }

    if ($logBox.Dispatcher.CheckAccess()) {
        & $action
    } else {
        $logBox.Dispatcher.Invoke($action)
    }
}

function Get-WinUtilReportSettings {
    <#
        .SYNOPSIS
            Returns the technician and the header saved with the last intervention report, or $null.
    #>
    $path = Join-Path $winutildir "rapporto.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    try {
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Write-Debug "Unable to read the report settings: $($_.Exception.Message)"
        $null
    }
}

function Save-WinUtilReportSettings {
    <#
        .SYNOPSIS
            Saves the technician and the header, so that the next intervention reports start with them.
    #>
    param(
        [string]$Technician,
        [string]$Header
    )

    try {
        $json = [pscustomobject]@{ Technician = $Technician; Header = $Header } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $winutildir "rapporto.json"), $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Debug "Unable to save the report settings: $($_.Exception.Message)"
    }
}

function Update-WinUtilReportView {
    <#
        .SYNOPSIS
            Lists the operations recorded in this session in the Report tab and, the first time,
            fills in the technician and the header saved with the last report.
    #>
    $actions = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() })
    $sync.WPFReportActions.ItemsSource = $actions
    $hasActions = $actions.Count -gt 0
    $sync.WPFReportActionsTable.Visibility = if ($hasActions) { "Visible" } else { "Collapsed" }
    $sync.WPFReportActionsEmpty.Visibility = if ($hasActions) { "Collapsed" } else { "Visible" }

    if (-not $sync.ReportSettingsLoaded) {
        $sync.ReportSettingsLoaded = $true
        $settings = Get-WinUtilReportSettings
        if ($settings) {
            $sync.WPFReportTechnician.Text = [string]$settings.Technician
            $sync.WPFReportHeader.Text = [string]$settings.Header
        }
    }
}

function Invoke-WPFReportClear {
    <#
        .SYNOPSIS
            Empties the list of the operations recorded in this session, after a confirmation.
    #>
    if (-not $sync.SessionActions -or $sync.SessionActions.Count -eq 0) {
        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Vuoi svuotare l'elenco delle operazioni eseguite? Le operazioni tolte non compariranno nel rapporto.",
        "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    $sync.SessionActions.Clear()
    Update-WinUtilReportView
    Write-WinUtilReportLog "Elenco delle operazioni svuotato."
}

function ConvertTo-WinUtilInterventionReportHtml {
    <#
        .SYNOPSIS
            Formats the intervention report for the customer as a standalone, printable HTML page.
        .PARAMETER Details
            Customer, Technician, Reference, Header, Notes, Date and Actions (the operations recorded in this session).
        .PARAMETER Report
            The system report of the PC (see Get-WinUtilSystemReport).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Details,
        [Parameter(Mandatory)][hashtable]$Report
    )

    $r = $Report
    $enc = { param($value) [System.Net.WebUtility]::HtmlEncode([string]$value) }
    $lines = { param($value) (@(([string]$value) -split "\r?\n") | ForEach-Object { & $enc $_.TrimEnd() }) -join "<br>" }
    $row = { param($label, $value) "<tr><td class=""k"">$label</td><td>$value</td></tr>" }
    $dash = "&ndash;"
    $orDash = { param($value) if ([string]::IsNullOrWhiteSpace($value)) { $dash } else { & $enc $value } }
    $date = $Details.Date

    $css = @'
:root{--fg:#111827;--muted:#5b6475;--border:#dde2e8;--accent:#047857;--danger:#b91c1c;--soft:#f6f8fa}
*{box-sizing:border-box}
body{margin:0;background:#eef1f5;color:var(--fg);font:13.5px/1.5 "Segoe UI",system-ui,sans-serif}
.toolbar{max-width:840px;margin:24px auto 0;padding:0 16px;display:flex;justify-content:flex-end}
.toolbar button{font:inherit;font-weight:600;color:#fff;background:var(--accent);border:0;border-radius:8px;padding:9px 18px;cursor:pointer}
.page{max-width:840px;margin:12px auto 32px;background:#fff;border:1px solid var(--border);border-radius:12px;padding:40px 44px}
header{display:flex;justify-content:space-between;align-items:flex-start;gap:24px;padding-bottom:18px;border-bottom:2px solid var(--fg)}
.company{color:var(--muted);font-size:12.5px;overflow-wrap:anywhere}
.company strong{display:block;color:var(--fg);font-size:17px;margin-bottom:2px}
.title{text-align:right;margin-left:auto}
.title:only-child{text-align:left;margin-left:0}
.title h1{margin:0;font-size:19px;letter-spacing:.04em;text-transform:uppercase}
.title p{margin:3px 0 0;color:var(--muted)}
.parties{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:20px 0 4px}
.parties span{display:block;font-size:10.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.parties b{display:block;font-size:14px;overflow-wrap:anywhere}
h2{margin:28px 0 8px;font-size:11.5px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--accent)}
table{width:100%;border-collapse:collapse}
.facts td{padding:6px 0;border-bottom:1px solid var(--border);vertical-align:top;overflow-wrap:anywhere}
.facts td.k{width:30%;color:var(--muted);padding-right:16px}
.ops th{text-align:left;font-size:10.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);padding:6px 14px 6px 0;border-bottom:1px solid var(--fg)}
.ops td{padding:7px 14px 7px 0;border-bottom:1px solid var(--border);vertical-align:top}
.ops td:last-child,.ops th:last-child{padding-right:0}
.nw{white-space:nowrap}
.muted{color:var(--muted)}
.ok{color:var(--accent);font-weight:600}
.err{color:var(--danger);font-weight:600}
.info{color:var(--muted);font-weight:600}
.notes{border:1px solid var(--border);border-radius:8px;padding:12px 14px;background:var(--soft);overflow-wrap:anywhere}
.empty{color:var(--muted);font-style:italic;margin:4px 0}
.signs{display:grid;grid-template-columns:1fr 1fr;gap:56px;margin-top:56px}
.signs div{border-top:1px solid var(--fg);padding-top:6px;font-size:12px;color:var(--muted)}
footer{margin-top:32px;font-size:11px;color:var(--muted);text-align:center}
@page{size:A4;margin:14mm}
@media print{body{background:#fff}.toolbar{display:none}.page{max-width:none;margin:0;border:0;border-radius:0;padding:0}tr,.signs,.notes{break-inside:avoid}h2{break-after:avoid}}
@media (max-width:640px) {.page{margin:0;border-radius:0;padding:24px 18px}header{flex-direction:column}.title{text-align:left;margin-left:0}.parties{grid-template-columns:1fr 1fr}}
'@

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="it">')
    $null = $sb.AppendLine('<head>')
    $null = $sb.AppendLine('<meta charset="utf-8">')
    $null = $sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $titleName = if ($Details.Customer) { $Details.Customer } else { $r.Hostname }
    $null = $sb.AppendLine("<title>Rapporto di intervento - $(& $enc $titleName)</title>")
    $null = $sb.AppendLine("<style>`r`n$css</style>")
    $null = $sb.AppendLine('</head>')
    $null = $sb.AppendLine('<body>')
    $null = $sb.AppendLine('<div class="toolbar"><button type="button" onclick="window.print()">Stampa o salva in PDF</button></div>')
    $null = $sb.AppendLine('<main class="page">')

    # Header: the technician's company on the left, title, date and reference on the right
    $null = $sb.AppendLine('<header>')
    if (-not [string]::IsNullOrWhiteSpace($Details.Header)) {
        $headerLines = @(([string]$Details.Header).Trim() -split "\r?\n")
        $company = "<strong>$(& $enc $headerLines[0].Trim())</strong>"
        if ($headerLines.Count -gt 1) {
            $company += & $lines (($headerLines | Select-Object -Skip 1) -join "`n")
        }
        $null = $sb.AppendLine("<div class=""company"">$company</div>")
    }
    $titleMeta = $date.ToString("d MMMM yyyy", [System.Globalization.CultureInfo]::GetCultureInfo("it-IT"))
    if ($Details.Reference) {
        $titleMeta += " &middot; Rif. $(& $enc $Details.Reference)"
    }
    $null = $sb.AppendLine("<div class=""title""><h1>Rapporto di intervento</h1><p>$titleMeta</p></div>")
    $null = $sb.AppendLine('</header>')

    $null = $sb.AppendLine('<section class="parties">')
    $null = $sb.AppendLine("<div><span>Cliente</span><b>$(& $orDash $Details.Customer)</b></div>")
    $null = $sb.AppendLine("<div><span>Tecnico</span><b>$(& $orDash $Details.Technician)</b></div>")
    $null = $sb.AppendLine("<div><span>Data</span><b>$($date.ToString('dd/MM/yyyy'))</b></div>")
    $null = $sb.AppendLine("<div><span>Computer</span><b>$(& $orDash $r.Hostname)</b></div>")
    $null = $sb.AppendLine('</section>')

    # PC details, as they are at the end of the intervention
    $null = $sb.AppendLine('<h2>Dati del computer</h2>')
    $null = $sb.AppendLine('<table class="facts">')
    $null = $sb.AppendLine((& $row 'Sistema operativo' ("{0}<br><span class=""muted"">{1}</span>" -f (& $enc $r.OSCaption), (& $enc $r.OSBuild))))
    $null = $sb.AppendLine((& $row 'Attivazione di Windows' (& $enc $r.ActivationText)))
    # Many models already start with the manufacturer name (e.g. "HP" and "HP ProDesk 400 G5")
    $model = if ($r.Model -and $r.Manufacturer -and $r.Model.StartsWith($r.Manufacturer, [System.StringComparison]::OrdinalIgnoreCase)) {
        $r.Model
    } else {
        @($r.Manufacturer, $r.Model | Where-Object { $_ -and $_ -ne 'Non disponibile' }) -join ' '
    }
    $null = $sb.AppendLine((& $row 'Produttore e modello' (& $orDash $model)))
    $null = $sb.AppendLine((& $row 'Numero di serie' (& $enc $r.Serial)))
    $null = $sb.AppendLine((& $row 'Processore' ("{0}<br><span class=""muted"">{1}</span>" -f (& $enc $r.CpuName), (& $enc $r.CpuCores))))
    $memory = if ($r.RamTotalGB) { "{0:N1} GB" -f $r.RamTotalGB } else { $r.RamText }
    if ($r.RamModules) { $memory = "{0} ({1})" -f $memory, $r.RamModules }
    $null = $sb.AppendLine((& $row 'Memoria RAM' (& $enc $memory)))
    # Labels are the drive letter, followed by the volume name when there is one
    $disks = @($r.Disks | ForEach-Object {
        $drive, $volume = ([string]$_.Label).Trim() -split '\s+', 2
        & $enc $(if ($volume) { "{0} {1}, {2}" -f $drive, $volume, $_.Text } else { "{0} {1}" -f $drive, $_.Text })
    })
    $disks += "<span class=""muted"">$(& $enc $r.DiskHealthText)</span>"
    $null = $sb.AppendLine((& $row 'Archiviazione' ($disks -join "<br>")))
    $null = $sb.AppendLine((& $row 'Scheda grafica' (& $enc $r.GpuName)))
    $security = @("Secure Boot: $($r.SecureBoot)", "TPM: $($r.Tpm)", "BitLocker ($env:SystemDrive): $($r.BitLocker)") | ForEach-Object { & $enc $_ }
    $null = $sb.AppendLine((& $row 'Sicurezza' ($security -join " &middot; ")))
    if ($r.HasBattery) {
        $null = $sb.AppendLine((& $row 'Batteria' (& $enc ("Carica {0}, {1}" -f $r.BatteryCharge, $r.BatteryHealth))))
    }
    $null = $sb.AppendLine((& $row 'Aggiornamenti di Windows' (& $enc "Ultima installazione: $($r.UpdatesLastInstall)")))
    $null = $sb.AppendLine('</table>')

    # Operations performed with WinRUtil
    $null = $sb.AppendLine('<h2>Operazioni eseguite</h2>')
    $actions = @($Details.Actions)
    if ($actions.Count -gt 0) {
        $status = @{ Success = 'ok'; Error = 'err'; Info = 'info' }
        $null = $sb.AppendLine('<table class="ops"><thead><tr><th>Ora</th><th>Categoria</th><th>Operazione</th><th>Esito</th></tr></thead><tbody>')
        foreach ($action in $actions) {
            $null = $sb.AppendLine(("<tr><td class=""nw muted"">{0}</td><td class=""nw"">{1}</td><td>{2}</td><td class=""nw {3}"">{4}</td></tr>" -f
                (& $enc $action.Time), (& $enc $action.Area), (& $enc $action.Text), $status[[string]$action.Status], (& $enc $action.Result)))
        }
        $null = $sb.AppendLine('</tbody></table>')
    } else {
        $null = $sb.AppendLine('<p class="empty">Nessuna operazione registrata con WinRUtil in questa sessione.</p>')
    }

    if (-not [string]::IsNullOrWhiteSpace($Details.Notes)) {
        $null = $sb.AppendLine('<h2>Note</h2>')
        $null = $sb.AppendLine("<div class=""notes"">$(& $lines ([string]$Details.Notes).Trim())</div>")
    }

    $null = $sb.AppendLine('<section class="signs"><div>Firma del tecnico</div><div>Firma del cliente</div></section>')
    $null = $sb.AppendLine("<footer>Rapporto creato con WinRUtil $(& $enc $sync.version) il $($date.ToString('dd/MM/yyyy')) alle $($date.ToString('HH:mm'))</footer>")
    $null = $sb.AppendLine('</main>')
    $null = $sb.AppendLine('</body>')
    $null = $sb.AppendLine('</html>')
    $sb.ToString()
}

function Invoke-WPFReportCreate {
    <#
        .SYNOPSIS
            Asks where to save the intervention report, then writes it as an HTML page and opens it
            in the default browser, ready to print or save as PDF. The PC details are read again,
            so that the report shows the PC as it is at the end of the intervention.
    #>
    if ($sync.ReportCreating) {
        return
    }

    $details = @{
        Customer   = $sync.WPFReportCustomer.Text.Trim()
        Technician = $sync.WPFReportTechnician.Text.Trim()
        Reference  = $sync.WPFReportReference.Text.Trim()
        Header     = $sync.WPFReportHeader.Text.Trim()
        Notes      = $sync.WPFReportNotes.Text.Trim()
        Actions    = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() })
        Date       = Get-Date
    }
    Save-WinUtilReportSettings -Technician $details.Technician -Header $details.Header

    $name = if ($details.Customer) { $details.Customer } else { $env:COMPUTERNAME }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Salva il rapporto di intervento"
    $dialog.Filter = "Pagina HTML (*.html)|*.html"
    $dialog.FileName = "Rapporto_{0}_{1}" -f (($name -replace '[\\/:*?"<>|]', '' -replace '\s+', '-').Trim('-.')), $details.Date.ToString('yyyyMMdd-HHmm')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilReportLog "Creazione del rapporto annullata." -Level Warning
        return
    }
    $details.Path = $dialog.FileName

    $sync.ReportDetails = $details
    $sync.ReportCreating = $true
    $sync.WPFReportCreate.IsEnabled = $false
    Write-WinUtilReportLog "Lettura dei dati del computer e creazione del rapporto..."

    Invoke-WPFRunspace -ScriptBlock {
        try {
            $details = $sync.ReportDetails
            $html = ConvertTo-WinUtilInterventionReportHtml -Details $details -Report (Get-WinUtilSystemReport)
            [System.IO.File]::WriteAllText($details.Path, $html, [System.Text.UTF8Encoding]::new($true))
            Write-WinUtilReportLog "Rapporto salvato: $($details.Path)" -Level Success
            Start-Process -FilePath $details.Path
        } catch {
            Write-WinUtilReportLog "Impossibile creare il rapporto: $($_.Exception.Message)" -Level Error
        } finally {
            $sync.ReportCreating = $false
            Invoke-WPFUIThread -ScriptBlock { $sync.WPFReportCreate.IsEnabled = $true }
        }
    }
}
