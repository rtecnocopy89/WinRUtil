# WinRUtil - variante con interfaccia HTML.
# Server locale (solo localhost, codice di accesso casuale a ogni avvio) che mostra web/index.html in una
# finestra Edge/Chrome in modalita' app e richiama le stesse funzioni della versione classica (WPF).
# Le funzioni della versione classica girano con $PARAM_NOUI = $true: niente chiamate alla finestra WPF.

$script:RWeb = [hashtable]::Synchronized(@{
        Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Label = ''; Percent = 0; Title = ''; Kind = ''
        # Esito di ogni applicazione nell'aggiornamento delle applicazioni scelte, letto dalla pagina
        Results = [hashtable]::Synchronized(@{})
    })
$script:RWebState = @{
    Phase = 'idle'; PS = $null; RS = $null; Handle = $null; Started = $null; Read = @{ I = 0; W = 0; E = 0 }
    Queries = @{}; LastActivity = (Get-Date).AddSeconds(40); Quit = $false; Browser = $null; BrowserProc = $null; ProfileDir = ''
    Token = ''; Port = 0; Iss = $null; Catalog = $null; Error = ''; ClassicFile = ''
}

# Icone delle applicazioni: le stesse della versione classica (servizio delle icone dei siti di Google)
$script:RWebIconSources = 'https://www.google.com https://*.gstatic.com'

function Add-RWebLog {
    param([string]$Text, [string]$Level = 'info')
    if ($null -eq $Text) { return }
    foreach ($l in ($Text -split "`r?`n")) {
        $t = $l.TrimEnd()
        if (-not $t -or $t -match '^[\s\-\\|/=]+$') { continue }
        [void]$script:RWeb.Log.Add(@{ t = (Get-Date).ToString('HH:mm:ss'); m = $t; c = $Level })
    }
}

function Show-WinRUtilWebFileDialog {
    # Finestra Apri/Salva di Windows sopra la finestra di WinRUtil (gira nel runspace STA dell'operazione)
    param([ValidateSet('Open', 'Save')][string]$Mode, [string]$Title, [string]$Filter, [string]$FileName = '', [switch]$Multi)
    Add-Type -AssemblyName System.Windows.Forms
    if ($Mode -eq 'Save') { $dlg = New-Object System.Windows.Forms.SaveFileDialog } else { $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect = [bool]$Multi }
    $dlg.Title = $Title; $dlg.Filter = $Filter; $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($FileName) { $dlg.FileName = $FileName }
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.FormBorderStyle = 'None'; $owner.Opacity = 0
    $owner.StartPosition = 'CenterScreen'; $owner.Size = New-Object System.Drawing.Size(1, 1)
    try {
        $owner.Show(); $owner.Activate()
        if ($dlg.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
        if ($Mode -eq 'Open' -and $Multi) { return @($dlg.FileNames) }
        return @($dlg.FileName)
    } finally { $owner.Close(); $owner.Dispose(); $dlg.Dispose() }
}

function New-RWebSessionState {
    # Stesse funzioni e variabili della versione classica, con la barra di avanzamento collegata alla pagina
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($v in @(@('sync', $sync), @('PARAM_NOUI', $true), @('PARAM_OFFLINE', $false), @('winutildir', $winutildir), @('RWeb', $script:RWeb), @('DebugPreference', 'SilentlyContinue'))) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $v[0], $v[1], $null))
    }
    foreach ($f in @(Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|winrutil|WPF' -and $_.Name -ne 'Set-WinUtilProgressbar' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $f.Name, $f.Definition))
    }
    $progress = 'param([string]$Label, [int]$Percent) $RWeb.Label = $Label; $RWeb.Percent = [math]::Max(0, [math]::Min(100, $Percent))'
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Set-WinUtilProgressbar', $progress))
    return $iss
}

function Get-RWebCatalog {
    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.applications.PSObject.Properties) {
        $a = $p.Value
        $apps.Add(@{ id = $p.Name; name = [string]$a.content; desc = [string]$a.description; cat = [string]$a.category; foss = [bool]$a.foss; link = [string]$a.link; winget = [string]$a.winget; choco = [string]$a.choco })
    }
    $tweaks = New-Object System.Collections.Generic.List[object]
    $combos = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        $t = $p.Value
        $type = [string]$t.Type
        if ($type -eq 'Combobox') {
            # Il DNS ha il suo menu; gli altri menu scrivono valori del registro (es. Multiplane Overlay)
            if ($t.registry) {
                $descs = @{}
                if ($t.ComboDescriptions) { foreach ($d in $t.ComboDescriptions.PSObject.Properties) { $descs[$d.Name] = [string]$d.Value } }
                $combos.Add(@{ id = $p.Name; name = [string]$t.Content; desc = [string]$t.Description; items = @(([string]$t.ComboItems) -split '\|' | Where-Object { $_ }); descs = $descs })
            }
            continue
        }
        $tweaks.Add(@{ id = $p.Name; name = [string]$t.Content; desc = [string]$t.Description; cat = ([string]$t.category -replace '^z__', ''); advanced = ([string]$t.category -like 'z__*'); type = $type })
    }
    $features = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.feature.PSObject.Properties) {
        $f = $p.Value
        if ($p.Name -eq 'WPFFeatureInstall') { continue }
        $features.Add(@{ id = $p.Name; name = [string]$f.Content; desc = [string]$f.Description; cat = ([string]$f.category -replace '^z__', ''); type = [string]$f.Type })
    }
    $appx = New-Object System.Collections.Generic.List[object]
    if ($sync.configs.appx) {
        foreach ($p in $sync.configs.appx.PSObject.Properties) {
            $x = $p.Value
            $appx.Add(@{ id = $p.Name; name = [string]$x.Content; desc = [string]$x.Description; cat = [string]$x.Category; pkg = [string]$x.PackageId })
        }
    }
    $presets = @{}
    foreach ($p in $sync.configs.preset.PSObject.Properties) { $presets[$p.Name] = @($p.Value) }
    # Stesse voci del menu DNS della versione classica (compreso "Fastest"), altrimenti quelle di dns.json
    $dns = @(([string]$sync.configs.tweaks.WPFchangedns.ComboItems) -split '\s+' | Where-Object { $_ })
    if ($dns.Count -eq 0) { $dns = @('Default', 'DHCP') + @($sync.configs.dns.PSObject.Properties.Name) }
    return @{ apps = $apps.ToArray(); tweaks = $tweaks.ToArray(); combos = $combos.ToArray(); features = $features.ToArray(); appx = $appx.ToArray(); presets = $presets; dns = $dns }
}

function Get-RWebButtonIds {
    $ids = @('WPFAddUltPerf', 'WPFRemoveUltPerf', 'WPFOOSUbutton', 'WPFUpdatesdefault', 'WPFUpdatessecurity', 'WPFUpdatesdisable', 'WPFInstallUpgrade')
    foreach ($p in $sync.configs.feature.PSObject.Properties) { if ($p.Value.Type -eq 'Button' -and $p.Name -ne 'WPFFeatureInstall') { $ids += $p.Name } }
    return $ids
}

$script:RWebTasks = @{
    apps = {
        param($Ids, $Manager, $Action)
        $pk = @($Ids | ForEach-Object { $sync.configs.applicationsHashtable[$_] } | Where-Object { $_ })
        if ($pk.Count -eq 0) { Write-Host 'Nessuna applicazione selezionata.'; return }
        $sorted = Get-WinUtilSelectedPackages -PackageList $pk -Preference $Manager
        $w = @($sorted[[PackageManagers]::Winget]); $c = @($sorted[[PackageManagers]::Choco])
        $failed = @()
        if ($w.Count -gt 0) { Install-WinUtilWinget; $failed += @(Install-WinUtilProgramWinget -Action $Action -Programs $w) }
        if ($c.Count -gt 0) { Install-WinUtilChoco; $failed += @(Install-WinUtilProgramChoco -Action $Action -Programs $c) }
        $failed = @($failed | Where-Object { $_ })
        if ($failed.Count -gt 0) { Write-Warning ("Non riuscite: " + ($failed -join ', ')) } else { Write-Host 'Operazione completata.' }
    }
    upgrade = {
        param($Manager)
        Set-WinUtilProgressbar -Label 'Aggiornamento di tutte le applicazioni' -Percent 10
        if ($Manager -eq 'Choco') { Install-WinUtilChoco; & choco upgrade all -y 2>&1 | ForEach-Object { Write-Host $_ } }
        else { Install-WinUtilWinget; & winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Host $_ } }
        Write-Host 'Aggiornamento completato.'
    }
    upgradesel = {
        param($Programs)
        $RWeb.Results.Clear()
        $list = @($Programs)
        foreach ($p in $list) { $RWeb.Results[[string]$p.Id] = @{ t = 'In attesa'; l = 'Muted'; ok = $false } }
        $updated = 0
        for ($i = 0; $i -lt $list.Count; $i++) {
            $p = $list[$i]
            Set-WinUtilProgressbar -Label ("Aggiornamento {0} di {1}: {2}" -f ($i + 1), $list.Count, $p.Name) -Percent (100 * $i / $list.Count)
            $RWeb.Results[[string]$p.Id] = @{ t = 'In corso...'; l = 'Running'; ok = $false }
            $r = Update-WinUtilProgram -Program $p
            if ($r.Success) { $updated++ }
            $RWeb.Results[[string]$p.Id] = @{ t = [string]$r.Text; l = [string]$r.Level; ok = [bool]$r.Success }
            Add-WinUtilSessionAction -Area 'Programmi' -Text ("Aggiornamento di {0} alla versione {1}" -f $p.Name, $p.Available) -Status $(if ($r.Success) { 'Success' } else { 'Error' })
        }
        if ($updated -lt $list.Count) { Write-Warning ("Applicazioni aggiornate: {0} su {1}. Quelle non riuscite restano selezionate, per riprovare." -f $updated, $list.Count) }
        else { Write-Host ("Applicazioni aggiornate: {0} su {1}." -f $updated, $list.Count) }
    }
    tweaks = {
        param($Ids, $Undo, $Dns)
        $ids = @($Ids)
        if (-not $Undo -and $ids -contains 'WPFTweaksRestorePoint') { $ids = @('WPFTweaksRestorePoint') + @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        if ($Undo) { $ids = @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $name = [string]$sync.configs.tweaks.($ids[$i]).Content
            if ($Undo) { Set-WinUtilProgressbar -Label "Annullo: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] -undo $true }
            else { Set-WinUtilProgressbar -Label "Applico: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] }
        }
        if ($Dns -and $Dns -ne 'Default') { Set-WinUtilProgressbar -Label "DNS: $Dns" -Percent 95; Set-WinUtilDNS -DNSProvider $Dns }
        Write-Host 'Ottimizzazioni completate.'
    }
    toggle = {
        param($Id, $On)
        if ($On) { Invoke-WinUtilTweaks $Id } else { Invoke-WinUtilTweaks $Id -undo $true }
        Write-Host 'Impostazione aggiornata.'
    }
    combo = {
        param($Id, $State)
        $cfg = $sync.configs.tweaks.$Id
        try {
            Set-WinUtilRegistryComboState -Registry $cfg.registry -State $State
            Write-Host "$($cfg.Content): $State"
            Add-WinUtilSessionAction -Area 'Ottimizzazione' -Text "$($cfg.Content): $State"
        } catch {
            Write-Error "$($cfg.Content): $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Ottimizzazione' -Text "$($cfg.Content): $State" -Status 'Error'
        }
    }
    features = {
        param($Ids)
        $ids = @($Ids); $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            Set-WinUtilProgressbar -Label ([string]$sync.configs.feature.($ids[$i]).Content) -Percent (100 * $i / $n)
            Invoke-WinUtilFeatureInstall $ids[$i]
        }
        Write-Host 'Funzionalita'' installate. Riavviare il PC per completare.'
    }
    button = {
        param($Id)
        $cfg = $sync.configs.feature.$Id
        if ($cfg -and $cfg.function -and (Get-Command $cfg.function -ErrorAction SilentlyContinue)) { & $cfg.function; return }
        if ($cfg -and $cfg.InvokeScript) { foreach ($s in $cfg.InvokeScript) { if ($s) { Invoke-Expression $s } }; return }
        switch ($Id) {
            'WPFAddUltPerf' { Invoke-WPFUltimatePerformance -Do }
            'WPFRemoveUltPerf' { Invoke-WPFUltimatePerformance }
            'WPFOOSUbutton' { Invoke-WPFOOSU }
            'WPFUpdatesdefault' { Invoke-WPFUpdatesdefault }
            'WPFUpdatessecurity' { Invoke-WPFUpdatessecurity }
            'WPFUpdatesdisable' { Invoke-WPFUpdatesdisable -Confirmed }
        }
        Write-Host 'Fatto.'
    }
    appx = {
        param($Ids, $Action)
        $ids = @($Ids); $apps = $sync.configs.appxHashtable; $ok = 0
        $packages = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $key = $ids[$i]; $app = $apps[$key]
            if ($Action -eq 'Remove') {
                Set-WinUtilProgressbar -Label ("Rimozione {0} di {1}: {2}" -f ($i + 1), $ids.Count, $app.Content) -Percent (100 * $i / $ids.Count)
                if ($key -eq 'WPFAppxMicrosoft_XboxGamingOverlay') {
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0 -ErrorAction SilentlyContinue
                }
                if ($key -eq 'WPFAppxMicrosoft_WindowsNotepad') { Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue }
                $done = Remove-WinUtilAPPX -Name $app.PackageId
                $packages.Add($app.PackageId)
                if ($key -eq 'WPFAppxMSTeams') { Get-Package -Name 'Microsoft Teams*' -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null }
                Add-WinUtilSessionAction -Area 'App di Windows' -Text ("Rimozione di {0}" -f $app.Content) -Status $(if ($done) { 'Success' } else { 'Error' })
            } else {
                Set-WinUtilProgressbar -Label ("Installazione {0} di {1}: {2}" -f ($i + 1), $ids.Count, $app.Content) -Percent (100 * $i / $ids.Count)
                $done = Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId
                Add-WinUtilSessionAction -Area 'App di Windows' -Text ("Installazione di {0}" -f $app.Content) -Status $(if ($done) { 'Success' } else { 'Error' })
            }
            if ($done) { $ok++ }
        }
        if ($Action -eq 'Remove' -and $packages.Count -gt 0) {
            Set-WinUtilProgressbar -Label 'Rimozione delle app per i nuovi profili utente' -Percent 95
            try { Remove-WinUtilProvisionedAPPX -PackageList $packages.ToArray() } catch { Write-Warning "Alcune app potrebbero comparire di nuovo nei profili utente creati in seguito. $($_.Exception.Message)" }
        }
        $verb = 'Installate'; if ($Action -eq 'Remove') { $verb = 'Rimosse' }
        if ($ok -lt $ids.Count) { Write-Warning ("{0} {1} app su {2}." -f $verb, $ok, $ids.Count) } else { Write-Host ("{0} {1} app su {2}." -f $verb, $ok, $ids.Count) }
    }
    printer = {
        param($Action, $Driver)
        switch ($Action) {
            'driver' {
                $f = @(Show-WinRUtilWebFileDialog -Mode Open -Title 'Seleziona il file del driver (.inf)' -Filter 'File driver (*.inf)|*.inf|Tutti i file (*.*)|*.*')
                if ($f.Count -eq 0) { Write-Warning 'Installazione del driver annullata.'; return }
                $text = "Installazione del driver di stampa {0}" -f [IO.Path]::GetFileName($f[0])
                Write-Host "Installazione del driver da: $($f[0])"
                $out = & pnputil.exe /add-driver "$($f[0])" /install 2>&1
                $out | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -eq 0) { Write-Host 'Driver installato.'; Add-WinUtilSessionAction -Area 'Stampanti' -Text $text }
                else { Write-Warning "pnputil ha restituito il codice $LASTEXITCODE."; Add-WinUtilSessionAction -Area 'Stampanti' -Text $text -Status 'Error' }
            }
            'remove' {
                try {
                    Remove-PrinterDriver -Name $Driver -ErrorAction Stop
                    Write-Host "Driver '$Driver' rimosso."
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text "Rimozione del driver di stampa $Driver"
                } catch {
                    Write-Error "Driver non rimosso (forse e' ancora usato da una stampante): $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text "Rimozione del driver di stampa $Driver" -Status 'Error'
                }
            }
            'restart' {
                try {
                    Restart-Service -Name Spooler -Force -ErrorAction Stop
                    Write-Host 'Spooler di stampa riavviato.'
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Riavvio dello spooler di stampa'
                } catch {
                    Write-Error "Riavvio dello spooler non riuscito: $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Riavvio dello spooler di stampa' -Status 'Error'
                }
            }
            'clear' {
                $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
                try {
                    Stop-Service -Name Spooler -Force -ErrorAction Stop
                    if (Test-Path $spool) { Get-ChildItem -Path $spool -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
                    Start-Service -Name Spooler -ErrorAction Stop
                    Write-Host 'Coda di stampa svuotata e spooler riavviato.'
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Svuotamento della coda di stampa'
                } catch {
                    Write-Error "Svuotamento della coda non riuscito: $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Svuotamento della coda di stampa' -Status 'Error'
                    try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }
    wifiexport = {
        if (-not (Test-WinUtilWlanService)) { return }
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Esporta i profili Wi-Fi' -Filter 'Archivio ZIP (*.zip)|*.zip' -FileName ("WinRUtil-WiFi_{0}_{1}.zip" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')))
        if ($f.Count -eq 0) { Write-Warning 'Esportazione annullata.'; return }
        try {
            $n = Export-WinUtilWifiProfiles -Path $f[0]
            if (-not $n) { Write-Warning 'Nessun profilo Wi-Fi da esportare.'; return }
            Write-Host ("Esportati {0} profili in {1}" -f $n, $f[0])
            Write-Warning 'Il file contiene le password in chiaro: conservalo in un luogo sicuro.'
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Backup di {0} {1}" -f $n, $(if ($n -eq 1) { 'profilo Wi-Fi' } else { 'profili Wi-Fi' }))
        } catch {
            Write-Error "Esportazione non riuscita: $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text 'Backup dei profili Wi-Fi' -Status 'Error'
        }
    }
    wifiimport = {
        if (-not (Test-WinUtilWlanService)) { return }
        $f = @(Show-WinRUtilWebFileDialog -Mode Open -Multi -Title 'Importa profili Wi-Fi' -Filter 'Profili Wi-Fi (*.zip;*.xml)|*.zip;*.xml')
        if ($f.Count -eq 0) { Write-Warning 'Importazione annullata.'; return }
        try {
            $res = @(Import-WinUtilWifiProfiles -Path $f)
            foreach ($r in $res) { if ($r.Success) { Write-Host "Importata: $($r.Name)" } else { Write-Warning "Non importata: $($r.Name) - $($r.Message)" } }
            $okNames = @($res | Where-Object { $_.Success } | ForEach-Object { $_.Name })
            $koNames = @($res | Where-Object { -not $_.Success } | ForEach-Object { $_.Name })
            if ($res.Count -eq 0) { Write-Warning 'Nessun profilo Wi-Fi trovato nei file scelti.' }
            elseif ($koNames.Count -eq 0) { Write-Host ("Importate {0} reti." -f $okNames.Count) }
            else { Write-Warning ("Importate {0} reti su {1}." -f $okNames.Count, $res.Count) }
            if ($okNames.Count) { Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Configurazione {0}: {1}" -f $(if ($okNames.Count -eq 1) { 'della rete Wi-Fi' } else { 'delle reti Wi-Fi' }), ($okNames -join ', ')) }
            if ($koNames.Count) { Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Configurazione {0}: {1}" -f $(if ($koNames.Count -eq 1) { 'della rete Wi-Fi' } else { 'delle reti Wi-Fi' }), ($koNames -join ', ')) -Status 'Error' }
        } catch {
            Write-Error "Importazione non riuscita: $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text 'Importazione dei profili Wi-Fi' -Status 'Error'
        }
    }
    wifiqrsave = {
        param($Ssid)
        $net = @(Get-WinRUtilWifiProfiles | Where-Object { $_.Ssid -eq $Ssid })
        if ($net.Count -eq 0 -or -not $net[0].CanShare) { Write-Error "Rete $Ssid non disponibile."; return }
        $net = $net[0]
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Salva il QR code della rete Wi-Fi' -Filter 'Immagine PNG (*.png)|*.png' -FileName ("WiFi-{0}.png" -f ($net.Ssid -replace '[\\/:*?"<>|]', '_')))
        if ($f.Count -eq 0) { Write-Warning 'Salvataggio annullato.'; return }
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
        $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $net)
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create((ConvertTo-WinUtilWifiQRCard -QRCode $qr -Network $net)))
        $stream = [System.IO.File]::Create($f[0])
        try { $enc.Save($stream) } finally { $stream.Dispose() }
        Write-Host "QR code salvato: $($f[0])"
        if ($net.Password) { Write-Warning 'L''immagine contiene la password della rete: condividila solo con chi deve collegarsi.' }
    }
    report = {
        param($Details)
        Save-WinUtilReportSettings -Technician $Details.Technician -Header $Details.Header
        $name = $Details.Customer; if (-not $name) { $name = $env:COMPUTERNAME }
        $date = Get-Date
        $fileName = "Rapporto_{0}_{1}" -f (($name -replace '[\\/:*?"<>|]', '' -replace '\s+', '-').Trim('-.')), $date.ToString('yyyyMMdd-HHmm')
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Salva il rapporto di intervento' -Filter 'Pagina HTML (*.html)|*.html' -FileName $fileName)
        if ($f.Count -eq 0) { Write-Warning 'Creazione del rapporto annullata.'; return }
        Set-WinUtilProgressbar -Label 'Lettura dei dati del computer' -Percent 30
        $d = @{
            Customer = $Details.Customer; Technician = $Details.Technician; Reference = $Details.Reference; Header = $Details.Header; Notes = $Details.Notes
            Actions = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() }); Date = $date
        }
        $html = ConvertTo-WinUtilInterventionReportHtml -Details $d -Report (Get-WinUtilSystemReport)
        [System.IO.File]::WriteAllText($f[0], $html, [System.Text.UTF8Encoding]::new($true))
        Write-Host "Rapporto salvato: $($f[0])"
        Start-Process -FilePath $f[0]
    }
    sysexport = {
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Esporta il report di sistema' -Filter 'Report HTML (*.html)|*.html|Testo semplice (*.txt)|*.txt' -FileName ("WinRUtil-Sistema_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')))
        if ($f.Count -eq 0) { Write-Warning 'Esportazione annullata.'; return }
        Set-WinUtilProgressbar -Label 'Lettura dei dati del computer' -Percent 30
        $r = Get-WinUtilSystemReport
        $isText = [IO.Path]::GetExtension($f[0]) -ieq '.txt'
        if ($isText) { $content = ConvertTo-WinUtilSystemReportText -Report $r } else { $content = ConvertTo-WinUtilSystemReportHtml -Report $r }
        [System.IO.File]::WriteAllText($f[0], $content, [System.Text.UTF8Encoding]::new($true))
        Write-Host "Report salvato: $($f[0])"
        if (-not $isText) { Start-Process -FilePath $f[0] }
    }
    classic = {
        # Niente download ed esecuzione sulla riga di comando di un nuovo PowerShell: gli antivirus lo bloccano.
        # Il file della versione classica si scarica qui e si avvia come file.
        param($LocalFile)
        $file = $LocalFile
        if (-not $file -or -not (Test-Path -LiteralPath $file)) {
            $file = Join-Path $winutildir 'winrutil.ps1'
            Set-WinUtilProgressbar -Label 'Download della versione classica' -Percent 30
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $tmp = "$file.download"
                Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
                Move-Item -LiteralPath $tmp -Destination $file -Force
            } catch {
                if (-not (Test-Path -LiteralPath $file)) { throw "Download della versione classica non riuscito: $($_.Exception.Message)" }
                Write-Warning 'Download non riuscito: avvio la copia scaricata in precedenza.'
            }
        }
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`"")
        Write-Host 'Versione classica avviata in una nuova finestra.'
    }
}

$script:RWebStrictKinds = @('printer', 'combo', 'wifiexport', 'wifiimport', 'wifiqrsave', 'report', 'sysexport', 'classic')

$script:RWebQueries = @{
    system   = '$r = Get-WinUtilSystemReport; $r.Disks = @($r.Disks | ForEach-Object { [pscustomobject]$_ }); [pscustomobject]$r'
    live     = '$l = [math]::Round([double](Get-CimInstance -ClassName Win32_Processor -Property LoadPercentage | Measure-Object -Property LoadPercentage -Average).Average); $o = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory,LastBootUpTime; $cs = Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory; $r = @{ CpuLoadPct = $l; CpuLoad = "$l%"; Uptime = (Format-WinUtilUptime $o.LastBootUpTime) }; Set-WinUtilSystemMemory -Report $r -TotalGB ([math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)) -FreeGB (([double]$o.FreePhysicalMemory * 1KB) / 1GB); [pscustomobject]$r'
    wifi     = '@(Get-WinRUtilWifiProfiles)'
    appx     = '@(Get-WinUtilInstalledAPPX)'
    printers = '@(Get-Printer -ErrorAction Stop | ForEach-Object { $j = 0; try { $j = @(Get-PrintJob -PrinterName $_.Name -ErrorAction Stop).Count } catch { }; [pscustomobject]@{ name = [string]$_.Name; driver = [string]$_.DriverName; port = [string]$_.PortName; status = [string]$_.PrinterStatus; jobs = $j } })'
    updWinget = 'if ((Test-WinUtilPackageManager -winget) -ne ''installed'') { Install-WinUtilWinget }; @(Get-WinUtilProgramUpdates -Manager Winget)'
    updChoco = 'if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw ''Chocolatey non e'''' installato: nessuna applicazione da aggiornare con Chocolatey.'' }; @(Get-WinUtilProgramUpdates -Manager Choco)'
    instWinget = '@(Invoke-WinUtilCurrentSystem -CheckBox winget)'
    instChoco = '@(Invoke-WinUtilCurrentSystem -CheckBox choco)'
    applied  = '@(Invoke-WinUtilCurrentSystem -CheckBox tweaks)'
}

function Start-RWebTask {
    param([string]$Kind, [string]$Title, [hashtable]$Params)
    $st = $script:RWebState
    if ($st.Phase -eq 'running') { return $false }
    Stop-RWebTask
    if (-not $st.Iss) { $st.Iss = New-RWebSessionState }
    $script:RWeb.Label = $Title; $script:RWeb.Percent = 0; $script:RWeb.Title = $Title; $script:RWeb.Kind = $Kind
    Add-RWebLog "== $Title" 'head'
    $rs = [runspacefactory]::CreateRunspace($Host, $st.Iss)
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:RWebTasks[$Kind].ToString())
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    $st.PS = $ps; $st.RS = $rs; $st.Read = @{ I = 0; W = 0; E = 0 }; $st.Error = ''
    $st.Handle = $ps.BeginInvoke(); $st.Started = Get-Date; $st.Phase = 'running'
    return $true
}

function Read-RWebStreams {
    $st = $script:RWebState
    if (-not $st.PS) { return }
    $s = $st.PS.Streams
    while ($st.Read.I -lt $s.Information.Count) { Add-RWebLog ([string]$s.Information[$st.Read.I].MessageData) 'info'; $st.Read.I++ }
    while ($st.Read.W -lt $s.Warning.Count) { Add-RWebLog ([string]$s.Warning[$st.Read.W].Message) 'warn'; $st.Read.W++ }
    while ($st.Read.E -lt $s.Error.Count) { Add-RWebLog ([string]$s.Error[$st.Read.E].Exception.Message) 'error'; $st.Read.E++ }
}

function Update-RWebPhase {
    $st = $script:RWebState
    if ($st.Phase -ne 'running') { return }
    Read-RWebStreams
    if ($st.Handle -and $st.Handle.IsCompleted) {
        try { [void]$st.PS.EndInvoke($st.Handle) } catch { $st.Error = $_.Exception.Message; Add-RWebLog $st.Error 'error' }
        Read-RWebStreams
        # Per le operazioni di questa variante un errore scritto vale come operazione non riuscita;
        # le funzioni della versione classica possono scrivere errori secondari senza fallire
        if (-not $st.Error -and $script:RWeb.Kind -in $script:RWebStrictKinds -and $st.PS.Streams.Error.Count -gt 0) { $st.Error = [string]$st.PS.Streams.Error[0].Exception.Message }
        $script:RWeb.Percent = 100
        $st.Phase = 'done'
        Add-RWebLog 'Terminato.' 'ok'
    }
}

function Stop-RWebTask {
    $st = $script:RWebState
    if ($st.PS) {
        try { if (-not $st.Handle.IsCompleted) { $st.PS.Stop() } } catch { }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close(); $st.RS.Dispose() } catch { }
    }
    $st.PS = $null; $st.RS = $null; $st.Handle = $null
}

function Get-RWebQueryEntry {
    # Letture lente (sistema, Wi-Fi, stampanti...) in un runspace separato: la pagina resta reattiva
    param([string]$Name, [switch]$Refresh)
    $q = $script:RWebState.Queries
    if ($Refresh -and $q.ContainsKey($Name) -and $q[$Name].Done) { [void]$q.Remove($Name) }
    if (-not $q.ContainsKey($Name)) {
        if (-not $script:RWebState.Iss) { $script:RWebState.Iss = New-RWebSessionState }
        $rs = [runspacefactory]::CreateRunspace($script:RWebState.Iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:RWebQueries[$Name])
        $q[$Name] = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Done = $false; Data = $null; Error = '' }
    }
    $e = $q[$Name]
    if (-not $e.Done -and $e.Handle.IsCompleted) {
        try { $e.Data = @($e.PS.EndInvoke($e.Handle)) } catch { $e.Data = @(); $e.Error = [string]$_.Exception.InnerException.Message; if (-not $e.Error) { $e.Error = [string]$_.Exception.Message } }
        try { $e.PS.Dispose(); $e.RS.Close(); $e.RS.Dispose() } catch { }
        $e.Done = $true
    }
    return $e
}

function Get-RWebQuery {
    param([string]$Name, [switch]$Refresh)
    $e = Get-RWebQueryEntry $Name -Refresh:$Refresh
    if (-not $e.Done) { return @{ loading = $true } }
    $data = @($e.Data)
    switch -Regex ($Name) {
        '^(system|live)$' { $out = $null; if ($data.Count) { $out = $data[$data.Count - 1] } }
        '^wifi$' { $out = @($data | ForEach-Object { @{ ssid = [string]$_.Ssid; password = [string]$_.Password; security = [string]$_.Security; auto = [string]$_.AutoConnect; hidden = [bool]$_.Hidden; canShare = [bool]$_.CanShare } }) }
        '^appx$' {
            $names = @($data | ForEach-Object { [string]$_ })
            $out = @($script:RWebState.Catalog.appx | Where-Object { $names -contains $_.pkg } | ForEach-Object { $_.id })
        }
        '^upd' { $out = @($data | ForEach-Object { @{ id = [string]$_.Id; name = [string]$_.Name; version = [string]$_.Version; available = [string]$_.Available; source = [string]$_.Source; manager = [string]$_.Manager; selected = [bool]$_.Selected } }) }
        '^(inst|applied)' { $out = @($data | ForEach-Object { [string]$_ } | Select-Object -Unique) }
        default { $out = $data }
    }
    return @{ loading = $false; data = $out; error = [string]$e.Error }
}

function Get-RWebToggles {
    $o = @{}
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        if ($p.Value.Type -ne 'Toggle') { continue }
        try { $o[$p.Name] = [bool](Get-WinUtilToggleStatus $p.Name) } catch { $o[$p.Name] = $false }
    }
    return $o
}

function Get-RWebCombos {
    $o = @{}
    foreach ($c in @($script:RWebState.Catalog.combos)) {
        try { $o[$c.id] = [string](Get-WinUtilRegistryComboState -Registry $sync.configs.tweaks.($c.id).registry) } catch { $o[$c.id] = '' }
    }
    return $o
}

function Get-RWebReport {
    $src = @(); if ($sync.SessionActions) { $src = $sync.SessionActions.ToArray() }
    $actions = @($src | ForEach-Object { @{ time = [string]$_.Time; area = [string]$_.Area; text = [string]$_.Text; status = [string]$_.Status; result = [string]$_.Result } })
    $s = Get-WinUtilReportSettings
    return @{ actions = $actions; technician = [string]$s.Technician; header = [string]$s.Header }
}

function Get-RWebWifiNetwork {
    # Rete dell'ultimo elenco letto (lo stesso mostrato nella pagina)
    param([string]$Ssid)
    $e = $script:RWebState.Queries['wifi']
    if (-not $e -or -not $e.Done) { return $null }
    return @($e.Data | Where-Object { $_.Ssid -eq $Ssid })[0]
}

function ConvertTo-RWebQRModules {
    param($QR)
    $sb = New-Object System.Text.StringBuilder ($QR.Size * $QR.Size)
    foreach ($m in $QR.Modules) { if ($m) { [void]$sb.Append('1') } else { [void]$sb.Append('0') } }
    return $sb.ToString()
}

function Test-RWebTokenEqual {
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($d -eq 0)
}

function Send-RWebBytes {
    param($Ctx, [byte[]]$Bytes, [string]$Type, [int]$Code = 200, [hashtable]$Extra = @{})
    $res = $Ctx.Response
    $res.StatusCode = $Code; $res.ContentType = $Type
    $res.Headers['Cache-Control'] = 'no-store'; $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'; $res.Headers['X-Frame-Options'] = 'DENY'
    foreach ($k in $Extra.Keys) { $res.Headers[$k] = $Extra[$k] }
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Send-RWebJson {
    param($Ctx, $Obj, [int]$Code = 200)
    $json = ConvertTo-Json -InputObject $Obj -Depth 6 -Compress
    Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Code
}

function Read-RWebBody {
    param($Req)
    if (-not $Req.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ($t.Length -gt 50000) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Select-RWebIds {
    # Accetta solo identificativi presenti nella configurazione
    param($Ids, $Valid)
    return @(@($Ids) | ForEach-Object { [string]$_ } | Where-Object { $Valid -contains $_ } | Select-Object -Unique)
}

function Get-RWebText {
    param($Value, [int]$Max = 2000)
    $t = ([string]$Value).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Get-RWebStatus {
    param([int]$Since)
    Update-RWebPhase
    $log = $script:RWeb.Log
    $count = $log.Count
    if ($Since -lt 0 -or $Since -gt $count) { $Since = 0 }
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = $Since; $i -lt $count; $i++) { $items.Add($log[$i]) }
    $st = $script:RWebState
    $el = 0; if ($st.Started) { $el = [int]((Get-Date) - $st.Started).TotalSeconds }
    $results = @{}; foreach ($k in @($script:RWeb.Results.Keys)) { $results[$k] = $script:RWeb.Results[$k] }
    return @{ phase = $st.Phase; kind = [string]$script:RWeb.Kind; title = [string]$script:RWeb.Title; label = [string]$script:RWeb.Label; percent = [int]$script:RWeb.Percent; logIndex = $count; log = $items.ToArray(); elapsed = $el; error = [string]$st.Error; results = $results }
}

function Invoke-RWebRequest {
    param($Ctx, [string]$Html)
    $st = $script:RWebState
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -ne "localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'host' } 403; return }
    if ($path -eq '/' -or $path -eq '/index.html') {
        $nb = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($nb); $rng.Dispose()
        $nonce = [Convert]::ToBase64String($nb)
        $csp = "default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; img-src data: $script:RWebIconSources; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($Html.Replace('__NONCE__', $nonce))) 'text/html; charset=utf-8' 200 @{ 'Content-Security-Policy' = $csp }
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-RWebJson $Ctx @{ error = 'not found' } 404; return }
    if (-not (Test-RWebTokenEqual $req.Headers['X-Token']$st.Token)) { Send-RWebJson $Ctx @{ error = 'token' } 403; return }
    $o = $req.Headers['Origin']
    if ($req.HttpMethod -eq 'POST' -and $o -and $o -ne "http://localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'origin' } 403; return }
    $st.LastActivity = Get-Date
    $b = $null
    if ($req.HttpMethod -eq 'POST') { $b = Read-RWebBody $req }
    $cat = $st.Catalog
    $busy = @{ error = 'Un''altra operazione e'' in corso.' }
    $refresh = [string]$req.QueryString['refresh'] -eq '1'
    $mgrQ = 'Winget'; if ([string]$req.QueryString['manager'] -eq 'Choco') { $mgrQ = 'Choco' }
    $start = {
        param($Kind, $Title, $Params)
        if (Start-RWebTask $Kind $Title $Params) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
    }
    switch ("$($req.HttpMethod) $path") {
        'GET /api/ping' { Send-RWebJson $Ctx @{ ok = $true } }
        'GET /api/info' {
            $pm = [string]$sync.preferences.packagemanager; if (-not $pm) { $pm = 'Winget' }
            Send-RWebJson $Ctx @{ app = 'WinRUtil'; version = [string]$sync.version; pc = [Environment]::MachineName; isAdmin = $true; manager = $pm }
        }
        'GET /api/catalog' { Send-RWebJson $Ctx $cat }
        'GET /api/toggles' { Send-RWebJson $Ctx (Get-RWebToggles) }
        'GET /api/combos' { Send-RWebJson $Ctx (Get-RWebCombos) }
        'GET /api/system' { Send-RWebJson $Ctx (Get-RWebQuery 'system' -Refresh:$refresh) }
        'GET /api/live' { Send-RWebJson $Ctx (Get-RWebQuery 'live' -Refresh:$refresh) }
        'GET /api/wifi' { Send-RWebJson $Ctx (Get-RWebQuery 'wifi' -Refresh:$refresh) }
        'GET /api/appx' { Send-RWebJson $Ctx (Get-RWebQuery 'appx' -Refresh:$refresh) }
        'GET /api/printers' { Send-RWebJson $Ctx (Get-RWebQuery 'printers' -Refresh:$refresh) }
        'GET /api/updates' { Send-RWebJson $Ctx (Get-RWebQuery "upd$mgrQ" -Refresh:$refresh) }
        'GET /api/installed' { Send-RWebJson $Ctx (Get-RWebQuery "inst$mgrQ" -Refresh:$refresh) }
        'GET /api/applied' { Send-RWebJson $Ctx (Get-RWebQuery 'applied' -Refresh:$refresh) }
        'GET /api/report' { Send-RWebJson $Ctx (Get-RWebReport) }
        'GET /api/status' {
            $since = 0; [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
            Send-RWebJson $Ctx (Get-RWebStatus $since)
        }
        'POST /api/apps' {
            $ids = Select-RWebIds $b.ids @($cat.apps | ForEach-Object { $_.id })
            $act = 'Install'; if ([string]$b.action -eq 'Uninstall') { $act = 'Uninstall' }
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''applicazione.' } 400; return }
            $t = "Installazione di $($ids.Count) applicazioni"; if ($act -eq 'Uninstall') { $t = "Disinstallazione di $($ids.Count) applicazioni" }
            & $start 'apps' $t @{ Ids = $ids; Manager = $mgr; Action = $act }
        }
        'POST /api/upgrade' {
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            & $start 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = $mgr }
        }
        'POST /api/updates' {
            # Solo applicazioni dell'ultimo elenco degli aggiornamenti trovati
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            $e = $st.Queries["upd$mgr"]
            if (-not $e -or -not $e.Done) { Send-RWebJson $Ctx @{ error = 'Cerca prima gli aggiornamenti.' } 400; return }
            $ids = @(@($b.ids) | ForEach-Object { [string]$_ })
            $programs = @($e.Data | Where-Object { $ids -contains [string]$_.Id })
            if ($programs.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''applicazione da aggiornare.' } 400; return }
            & $start 'upgradesel' "Aggiornamento di $($programs.Count) applicazioni" @{ Programs = $programs }
        }
        'POST /api/tweaks' {
            $ids = Select-RWebIds $b.ids @($cat.tweaks | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            $dns = [string]$b.dns; if ($cat.dns -notcontains $dns) { $dns = 'Default' }
            $undo = [bool]$b.undo
            if ($ids.Count -eq 0 -and $dns -eq 'Default') { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''ottimizzazione.' } 400; return }
            $t = "Applicazione di $($ids.Count) ottimizzazioni"; if ($undo) { $t = "Annullamento di $($ids.Count) ottimizzazioni" }
            & $start 'tweaks' $t @{ Ids = $ids; Undo = $undo; Dns = $dns }
        }
        'POST /api/toggle' {
            $id = [string]$b.id
            $t = @($cat.tweaks | Where-Object { $_.id -eq $id -and $_.type -eq 'Toggle' })
            if ($t.Count -ne 1) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            $lbl = "$($t[0].name): disattivato"; if ([bool]$b.on) { $lbl = "$($t[0].name): attivato" }
            & $start 'toggle' $lbl @{ Id = $id; On = [bool]$b.on }
        }
        'POST /api/combo' {
            $id = [string]$b.id; $state = [string]$b.state
            $c = @($cat.combos | Where-Object { $_.id -eq $id })
            if ($c.Count -ne 1 -or $c[0].items -notcontains $state) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            & $start 'combo' "$($c[0].name): $state" @{ Id = $id; State = $state }
        }
        'POST /api/features' {
            $ids = Select-RWebIds $b.ids @($cat.features | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno una funzionalita''.' } 400; return }
            & $start 'features' "Installazione di $($ids.Count) funzionalita'" @{ Ids = $ids }
        }
        'POST /api/button' {
            $id = [string]$b.id
            if ((Get-RWebButtonIds) -notcontains $id) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            if ($id -eq 'WPFInstallUpgrade') { & $start 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = 'Winget' }; return }
            $name = Get-RWebText $b.label 120; if (-not $name) { $name = $id }
            & $start 'button' $name @{ Id = $id }
        }
        'POST /api/appx' {
            $ids = Select-RWebIds $b.ids @($cat.appx | ForEach-Object { $_.id })
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''app di Windows.' } 400; return }
            if ([string]$b.action -eq 'Remove') { & $start 'appx' "Rimozione di $($ids.Count) app di Windows" @{ Ids = $ids; Action = 'Remove' } }
            else { & $start 'appx' "Installazione di $($ids.Count) app di Windows" @{ Ids = $ids; Action = 'Install' } }
        }
        'POST /api/printer' {
            $act = [string]$b.action
            $titles = @{ driver = 'Installazione di un driver di stampa'; remove = 'Rimozione del driver di stampa'; restart = 'Riavvio dello spooler di stampa'; clear = 'Svuotamento della coda di stampa' }
            if (-not $titles.ContainsKey($act)) { Send-RWebJson $Ctx @{ error = 'azione' } 400; return }
            $drv = ''
            if ($act -eq 'remove') {
                # Solo driver di una stampante dell'elenco mostrato
                $e = $st.Queries['printers']
                $drv = [string]$b.driver
                if (-not $e -or -not $e.Done -or -not @($e.Data | Where-Object { $_.driver -eq $drv }).Count) { Send-RWebJson $Ctx @{ error = 'Seleziona una stampante dell''elenco.' } 400; return }
            }
            & $start 'printer' $titles[$act] @{ Action = $act; Driver = $drv }
        }
        'POST /api/wifiqr' {
            $n = Get-RWebWifiNetwork ([string]$b.ssid)
            if (-not $n) { Send-RWebJson $Ctx @{ error = 'Rete non trovata: aggiorna l''elenco.' } 400; return }
            if (-not $n.CanShare) {
                $msg = 'QR code non disponibile: la password non risulta salvata su questo PC.'
                if ($n.Security -match 'Enterprise') { $msg = 'QR code non disponibile: le reti aziendali (802.1X) usano credenziali personali.' }
                Send-RWebJson $Ctx @{ error = $msg } 400; return
            }
            try { $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $n) }
            catch { Send-RWebJson $Ctx @{ error = "Impossibile creare il QR code: $($_.Exception.Message)" } 500; return }
            Send-RWebJson $Ctx @{ ssid = [string]$n.Ssid; security = [string]$n.Security; open = (-not $n.Password); size = [int]$qr.Size; modules = (ConvertTo-RWebQRModules $qr) }
        }
        'POST /api/wifiqrsave' {
            $n = Get-RWebWifiNetwork ([string]$b.ssid)
            if (-not $n -or -not $n.CanShare) { Send-RWebJson $Ctx @{ error = 'Rete non disponibile.' } 400; return }
            & $start 'wifiqrsave' "QR code della rete $($n.Ssid)" @{ Ssid = [string]$n.Ssid }
        }
        'POST /api/wifiexport' { & $start 'wifiexport' 'Esportazione dei profili Wi-Fi' @{} }
        'POST /api/wifiimport' { & $start 'wifiimport' 'Importazione dei profili Wi-Fi' @{} }
        'POST /api/report' {
            $d = @{ Customer = (Get-RWebText $b.customer 200); Technician = (Get-RWebText $b.technician 200); Reference = (Get-RWebText $b.reference 200); Header = (Get-RWebText $b.header 1000); Notes = (Get-RWebText $b.notes 4000) }
            & $start 'report' 'Rapporto di intervento' @{ Details = $d }
        }
        'POST /api/report/clear' { if ($sync.SessionActions) { $sync.SessionActions.Clear() }; Send-RWebJson $Ctx @{ ok = $true } }
        'POST /api/sysexport' { & $start 'sysexport' 'Esportazione del report di sistema' @{} }
        'POST /api/manager' {
            $m = [string]$b.manager
            if ($m -in @('Winget', 'Choco')) { $sync.preferences.packagemanager = [PackageManagers]$m; try { Set-Preferences -save } catch { } }
            Send-RWebJson $Ctx @{ ok = $true }
        }
        'POST /api/classic' { & $start 'classic' 'Apertura della versione classica' @{ LocalFile = $st.ClassicFile } }
        'POST /api/exit' { Send-RWebJson $Ctx @{ ok = $true }; if ($st.Phase -ne 'running') { $st.Quit = $true } }
        default { Send-RWebJson $Ctx @{ error = 'not found' } 404 }
    }
}

function Find-RWebBrowser {
    $c = @()
    foreach ($b in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Microsoft\Edge\Application\msedge.exe' } }
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Google\Chrome\Application\chrome.exe' } }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Start-WinRUtilWebApp {
    param([string]$Html, [switch]$NoBrowser, [int]$IdleTimeout = 25)
    $st = $script:RWebState
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
    $st.Token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $tl = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tl.Start(); $st.Port = ([Net.IPEndPoint]$tl.LocalEndpoint).Port; $tl.Stop()
    $st.Catalog = Get-RWebCatalog
    $prefix = "http://localhost:$($st.Port)/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try { $listener.Start() } catch { Write-Host "Impossibile avviare l'interfaccia su $prefix : $($_.Exception.Message)" -ForegroundColor Red; return }
    $url = "$prefix#$($st.Token)"
    if ($NoBrowser) { $IdleTimeout = 900; Write-Host "WinRUtil web in ascolto: $url" }
    else {
        $st.Browser = Find-RWebBrowser
        $st.ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ('WinRUtilUI_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        if ($st.Browser) {
            $argList = @("--app=$url", "--user-data-dir=`"$($st.ProfileDir)`"", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--window-size=1320,900')
            $st.BrowserProc = Start-Process -FilePath $st.Browser -ArgumentList $argList -PassThru
        } else { Start-Process $url }
        Write-Host ''
        Write-Host '  WinRUtil e'' aperto nella sua finestra. Questa console si chiude da sola quando chiudi WinRUtil.' -ForegroundColor Green
    }
    try {
        while (-not $st.Quit) {
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(400)) {
                Update-RWebPhase
                $idle = ((Get-Date) - $st.LastActivity).TotalSeconds
                if ($st.Phase -ne 'running' -and $idle -gt $IdleTimeout) { $st.Quit = $true; break }
                if ($st.Quit) { break }
            }
            if ($st.Quit) { break }
            $ctx = $null
            try { $ctx = $task.GetAwaiter().GetResult() } catch { continue }
            try { Invoke-RWebRequest $ctx $Html } catch { try { Send-RWebJson $ctx @{ error = $_.Exception.Message } 500 } catch { } }
        }
    } finally {
        if ($st.Phase -eq 'running') {
            Write-Host '  Attendo la fine dell''operazione in corso...' -ForegroundColor Yellow
            while ($st.Handle -and -not $st.Handle.IsCompleted) { Start-Sleep -Milliseconds 500; Read-RWebStreams }
        }
        try { $listener.Stop(); $listener.Close() } catch { }
        Stop-RWebTask
        foreach ($q in @($st.Queries.Values)) { try { $q.PS.Dispose(); $q.RS.Close() } catch { } }
        if ($st.BrowserProc) { try { if (-not $st.BrowserProc.HasExited) { [void]$st.BrowserProc.CloseMainWindow() } } catch { } }
        if ($st.ProfileDir -and (Test-Path -LiteralPath $st.ProfileDir)) {
            Start-Sleep -Milliseconds 800
            try { Remove-Item -LiteralPath $st.ProfileDir -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}
