function Write-WinUtilWifiLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Wi-Fi tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFWifiStatusLog
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

function Get-WinRUtilWifiProfiles {
    <#
    .SYNOPSIS
        Lists saved Wi-Fi profiles (SSID, plaintext password, security type, autoconnect).
    .DESCRIPTION
        Locale independent: exports every WLAN profile to XML via
        "netsh wlan export profile key=clear" and parses the XML elements
        (name, authentication, keyMaterial, connectionMode) instead of reading
        the localized console output of "netsh wlan show profile ... key=clear".
        Works on Windows PowerShell 5.1+ and PowerShell 7. ASCII-only source.
    .OUTPUTS
        Array of [PSCustomObject] with properties: Ssid, Password, Security, AutoConnect, Hidden, CanShare.
    #>
    [CmdletBinding()]
    param()

    # Unique temp working folder; removed in finally.
    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    $results = New-Object System.Collections.Generic.List[object]
    $skipped = 0

    try {
        # Bail out gracefully if the WLAN AutoConfig service is not running.
        $svc = Get-Service -Name 'Wlansvc' -ErrorAction SilentlyContinue
        if ($null -eq $svc -or $svc.Status -ne 'Running') {
            return @()
        }

        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null

        # Export ALL profiles at once with cleartext keys. Names with spaces /
        # special chars are handled by netsh; SSIDs are read from the XML below,
        # never from the (mangled, locale-affected) file names.
        $null = netsh wlan export profile key=clear folder="$work" 2>&1

        $xmlFiles = @(Get-ChildItem -Path $work -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($xmlFiles.Count -eq 0) {
            return @()
        }

        foreach ($file in $xmlFiles) {
            try {
                # Read raw text first; used both for XML load and regex fallback.
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

                $ssid          = $null
                $authentication = $null
                $keyMaterial    = $null
                $hasKeyElement  = $false
                $connectionMode = $null
                $hidden         = $false
                $encryption     = $null

                # Primary path: parse as XML using namespace-agnostic local-name()
                # XPath so the default v1 namespace (and nested v3/v4) do not matter.
                $parsedXml = $false
                try {
                    $doc = New-Object System.Xml.XmlDocument
                    $doc.PreserveWhitespace = $false
                    $doc.LoadXml($raw)

                    $nameNode = $doc.SelectSingleNode("//*[local-name()='WLANProfile']/*[local-name()='name']")
                    if ($null -eq $nameNode) {
                        $nameNode = $doc.SelectSingleNode("//*[local-name()='name']")
                    }
                    if ($nameNode) { $ssid = $nameNode.InnerText }

                    $authNode = $doc.SelectSingleNode("//*[local-name()='authentication']")
                    if ($authNode) { $authentication = $authNode.InnerText }

                    $encNode = $doc.SelectSingleNode("//*[local-name()='encryption']")
                    if ($encNode) { $encryption = $encNode.InnerText }

                    $keyNode = $doc.SelectSingleNode("//*[local-name()='keyMaterial']")
                    if ($keyNode) {
                        $hasKeyElement = $true
                        $keyMaterial = $keyNode.InnerText
                    }

                    $cmNode = $doc.SelectSingleNode("//*[local-name()='connectionMode']")
                    if ($cmNode) { $connectionMode = $cmNode.InnerText }

                    # Networks that do not broadcast their SSID
                    $hiddenNode = $doc.SelectSingleNode("//*[local-name()='nonBroadcast']")
                    $hidden = $hiddenNode -and $hiddenNode.InnerText -match '^(true|1)$'

                    # transitionMode (WPA2<->WPA3 mixed) lives in the v4 namespace.
                    $transNode = $doc.SelectSingleNode("//*[local-name()='transitionMode']")
                    $transitionMode = $false
                    if ($transNode -and $transNode.InnerText -match '^(true|1)$') {
                        $transitionMode = $true
                    }

                    $parsedXml = $true
                }
                catch {
                    $parsedXml = $false
                }

                # Robust fallback: regex the inner text of the elements if XML
                # parsing failed for any reason (e.g. unexpected encoding).
                if (-not $parsedXml) {
                    $transitionMode = $false
                    $hidden = $raw -match '(?s)<nonBroadcast>\s*(true|1)\s*</nonBroadcast>'
                    if ($raw -match '(?s)<name>(.*?)</name>') { $ssid = $matches[1] }
                    if ($raw -match '(?s)<authentication>(.*?)</authentication>') { $authentication = $matches[1] }
                    if ($raw -match '(?s)<encryption>(.*?)</encryption>') { $encryption = $matches[1] }
                    if ($raw -match '(?s)<keyMaterial>(.*?)</keyMaterial>') {
                        $hasKeyElement = $true
                        $keyMaterial = $matches[1]
                    }
                    if ($raw -match '(?s)<connectionMode>(.*?)</connectionMode>') { $connectionMode = $matches[1] }
                    if ($raw -match '(?s)<transitionMode[^>]*>(.*?)</transitionMode>') {
                        if ($matches[1] -match '^(true|1)$') { $transitionMode = $true }
                    }
                    # Decode the handful of XML entities that appear in SSIDs.
                    if ($null -ne $ssid) {
                        $ssid = $ssid -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&apos;', "'"
                    }
                }

                if ([string]::IsNullOrEmpty($ssid)) {
                    $skipped++
                    continue
                }

                # Normalize values.
                if ($null -eq $authentication) { $authentication = '' }
                $authUpper = $authentication.ToUpperInvariant()

                # Password: empty string for open networks (no keyMaterial element).
                if (-not $hasKeyElement -or $null -eq $keyMaterial) {
                    $password = ''
                }
                else {
                    $password = $keyMaterial
                }

                # AutoConnect: Italian yes / no based on connectionMode (char code keeps the source ASCII-only).
                if ($connectionMode -and $connectionMode.Trim().ToLowerInvariant() -eq 'auto') {
                    $autoConnect = "S$([char]0x00EC)"
                }
                else {
                    $autoConnect = 'No'
                }

                # Map the raw authentication token to a human-readable label.
                $security = switch -Regex ($authUpper) {
                    '^OPEN$'        { if ($hasKeyElement -and $encryption -match '^WEP$') { 'WEP' } else { 'Aperta' }; break }   # open-system WEP has a key
                    '^SHARED$'      { 'WEP'; break }            # legacy shared-key WEP
                    '^WPA3SAE$'     { if ($transitionMode) { 'WPA2/WPA3' } else { 'WPA3-SAE' }; break }
                    '^WPA3ENT.*'    { 'WPA3-Enterprise'; break }
                    '^WPA3$'        { 'WPA3-Enterprise'; break }
                    '^WPA2PSK$'     { 'WPA2-Personal'; break }
                    '^WPA2$'        { 'WPA2-Enterprise'; break }
                    '^WPAPSK$'      { 'WPA-Personal'; break }
                    '^WPA$'         { 'WPA-Enterprise'; break }
                    'OWE'           { 'OWE'; break }            # Enhanced Open
                    default {
                        if ([string]::IsNullOrEmpty($authentication)) {
                            if ($hasKeyElement) { 'Sconosciuta' } else { 'Aperta' }
                        }
                        else {
                            $authentication
                        }
                    }
                }

                # If there is genuinely no key element and auth says open, force Aperta.
                if (-not $hasKeyElement -and ($authUpper -eq 'OPEN' -or $authUpper -eq '')) {
                    $security = 'Aperta'
                    $password = ''
                }

                $results.Add([PSCustomObject]@{
                    Ssid        = $ssid
                    Password    = $password
                    Security    = $security
                    AutoConnect = $autoConnect
                    Hidden      = [bool]$hidden
                    # Enterprise (802.1X) networks use per-user credentials, which a Wi-Fi QR code cannot carry
                    CanShare    = ($security -notmatch 'Enterprise') -and ($password -ne '' -or $security -in @('Aperta', 'OWE'))
                })
            }
            catch {
                $skipped++
                continue
            }
        }
    }
    catch {
        # Any unexpected failure: return whatever we have (possibly empty), never throw.
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($skipped -gt 0) {
        Write-Verbose ("Get-WinRUtilWifiProfiles: skipped {0} profile(s) that failed to parse." -f $skipped)
    }

    # Sort by Ssid and always return an array.
    return @($results | Sort-Object -Property Ssid)
}

function Invoke-WPFWifiRefresh {
    <#
        .SYNOPSIS
            Scans saved Wi-Fi networks and fills the Wi-Fi DataGrid (SSID, password, security, autoconnect).
    #>
    Write-WinUtilWifiLog "Scansione delle reti Wi-Fi salvate..."
    try {
        $profiles = @(Get-WinRUtilWifiProfiles)
        $sync.WPFWifiList.ItemsSource = $profiles
        $withPwd = @($profiles | Where-Object { $_.Password -ne "" }).Count
        Write-WinUtilWifiLog ("Trovate {0} rete/i Wi-Fi ({1} con password)." -f $profiles.Count, $withPwd) -Level Success
    } catch {
        Write-WinUtilWifiLog "Impossibile leggere le reti Wi-Fi: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFWifiCopyAll {
    <#
        .SYNOPSIS
            Copies all scanned Wi-Fi networks (SSID, password, security) to the clipboard as tab-separated text.
    #>
    $items = @($sync.WPFWifiList.ItemsSource)
    if ($items.Count -eq 0) {
        Write-WinUtilWifiLog "Nessuna rete da copiare. Esegui prima una scansione." -Level Warning
        return
    }

    $lines = foreach ($it in $items) {
        "{0}`t{1}`t{2}" -f $it.Ssid, $it.Password, $it.Security
    }
    $text = "SSID`tPassword`tSicurezza`r`n" + ($lines -join "`r`n")

    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        Write-WinUtilWifiLog ("Copiate {0} rete/i negli appunti." -f $items.Count) -Level Success
    } catch {
        Write-WinUtilWifiLog "Copia negli appunti non riuscita: $($_.Exception.Message)" -Level Error
    }
}

function Test-WinUtilWlanService {
    <#
        .SYNOPSIS
            Returns $true when the WLAN AutoConfig service is running; otherwise logs why the Wi-Fi tools are unavailable.
    #>
    $svc = Get-Service -Name 'Wlansvc' -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -ne 'Running') {
        Write-WinUtilWifiLog "Servizio WLAN (Wlansvc) non attivo: su questo PC non sono disponibili reti Wi-Fi." -Level Warning
        return $false
    }
    return $true
}

function Export-WinUtilWifiProfiles {
    <#
        .SYNOPSIS
            Exports every saved Wi-Fi profile, with its key in clear text, to a .zip archive that
            Import-WinUtilWifiProfiles (or "netsh wlan add profile") can import on another PC.
        .PARAMETER Path
            Full path of the .zip archive to create. An existing file is replaced.
        .OUTPUTS
            The number of exported profiles.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    try {
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
        $null = netsh wlan export profile key=clear folder="$work" 2>&1

        $files = @(Get-ChildItem -LiteralPath $work -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            return 0
        }

        $readme = @(
            "Profili Wi-Fi esportati da WinRUtil ($env:COMPUTERNAME, $(Get-Date -Format 'dd/MM/yyyy HH:mm'))."
            "ATTENZIONE: i file contengono le password in chiaro, conserva questo archivio in un luogo sicuro."
            ""
            "Per importarli su un altro PC:"
            "- WinRUtil > Wi-Fi > Importa profili, poi scegli questo file .zip"
            "- oppure, da un prompt dei comandi come amministratore, per ogni file .xml:"
            "  netsh wlan add profile filename=""NomeFile.xml"" user=all"
        )
        Set-Content -LiteralPath (Join-Path $work 'LEGGIMI.txt') -Value $readme -Encoding ASCII

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($work, $Path)
        return $files.Count
    }
    finally {
        # The exported files contain the keys in clear text: never leave them behind
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-WinUtilWifiProfiles {
    <#
        .SYNOPSIS
            Imports Wi-Fi profiles for all users from .zip archives created by Export-WinUtilWifiProfiles
            or from .xml profile files exported by netsh.
        .PARAMETER Path
            One or more .zip or .xml files.
        .OUTPUTS
            One object per profile file, with Name, Success and Message.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    try {
        $xmlFiles = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Path) {
            if ([System.IO.Path]::GetExtension($item) -ieq '.zip') {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $target = Join-Path $work ([guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                [System.IO.Compression.ZipFile]::ExtractToDirectory($item, $target)
                Get-ChildItem -LiteralPath $target -Filter '*.xml' -File -Recurse | ForEach-Object { $xmlFiles.Add($_.FullName) }
            } else {
                $xmlFiles.Add($item)
            }
        }

        foreach ($file in $xmlFiles) {
            # Only WLAN profile documents are handed to netsh
            $name = $null
            try {
                $doc = New-Object System.Xml.XmlDocument
                $stream = [System.IO.File]::OpenRead($file)
                try { $doc.Load($stream) } finally { $stream.Dispose() }
                if ($doc.DocumentElement.LocalName -eq 'WLANProfile') {
                    $nameNode = $doc.DocumentElement.SelectSingleNode("*[local-name()='name']")
                    if ($nameNode) { $name = $nameNode.InnerText }
                }
            } catch {
                $name = $null
            }

            if ([string]::IsNullOrEmpty($name)) {
                [PSCustomObject]@{ Name = [System.IO.Path]::GetFileName($file); Success = $false; Message = "File non valido: non contiene un profilo Wi-Fi." }
                continue
            }

            $output = netsh wlan add profile filename="$file" user=all 2>&1
            [PSCustomObject]@{
                Name    = $name
                Success = ($LASTEXITCODE -eq 0)
                Message = (($output | Out-String) -replace '\s+', ' ').Trim()
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WPFWifiExport {
    <#
        .SYNOPSIS
            Asks for a destination file and exports all saved Wi-Fi profiles, with their passwords, to a .zip archive.
    #>
    if (-not (Test-WinUtilWlanService)) {
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Esporta i profili Wi-Fi"
    $dialog.Filter = "Archivio ZIP (*.zip)|*.zip"
    $dialog.FileName = "WinRUtil-WiFi_{0}_{1}.zip" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilWifiLog "Esportazione annullata." -Level Warning
        return
    }

    Write-WinUtilWifiLog "Esportazione dei profili Wi-Fi..."
    try {
        $count = Export-WinUtilWifiProfiles -Path $dialog.FileName
        if ($count -eq 0) {
            Write-WinUtilWifiLog "Nessun profilo Wi-Fi da esportare." -Level Warning
        } else {
            Write-WinUtilWifiLog ("Esportati {0} profilo/i in {1}" -f $count, $dialog.FileName) -Level Success
            Write-WinUtilWifiLog "Il file contiene le password in chiaro: conservalo in un luogo sicuro." -Level Warning
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Backup di {0} {1}" -f $count, $(if ($count -eq 1) { "profilo Wi-Fi" } else { "profili Wi-Fi" }))
        }
    } catch {
        Write-WinUtilWifiLog "Esportazione non riuscita: $($_.Exception.Message)" -Level Error
        Add-WinUtilSessionAction -Area "Wi-Fi" -Text "Backup dei profili Wi-Fi" -Status "Error"
    }
}

function Invoke-WPFWifiImport {
    <#
        .SYNOPSIS
            Asks for one or more exported files (.zip or .xml) and imports the Wi-Fi profiles they contain.
    #>
    if (-not (Test-WinUtilWlanService)) {
        return
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Importa profili Wi-Fi"
    $dialog.Filter = "Profili Wi-Fi (*.zip;*.xml)|*.zip;*.xml"
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilWifiLog "Importazione annullata." -Level Warning
        return
    }

    Write-WinUtilWifiLog "Importazione dei profili Wi-Fi..."
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try {
        $results = @(Import-WinUtilWifiProfiles -Path $dialog.FileNames)
        foreach ($res in $results) {
            if ($res.Success) {
                Write-WinUtilWifiLog "Importata: $($res.Name)"
            } else {
                Write-WinUtilWifiLog "Non importata: $($res.Name) - $($res.Message)" -Level Warning
            }
        }

        $imported = @($results | Where-Object { $_.Success }).Count
        if ($results.Count -eq 0) {
            Write-WinUtilWifiLog "Nessun profilo Wi-Fi trovato nei file selezionati." -Level Warning
        } elseif ($imported -eq $results.Count) {
            Write-WinUtilWifiLog ("Importate {0} rete/i." -f $imported) -Level Success
        } else {
            Write-WinUtilWifiLog ("Importate {0} rete/i su {1}." -f $imported, $results.Count) -Level Warning
        }

        # One report line for the imported networks and one for those that failed
        $importedNames = @($results | Where-Object { $_.Success } | ForEach-Object { $_.Name })
        $failedNames = @($results | Where-Object { -not $_.Success } | ForEach-Object { $_.Name })
        if ($importedNames.Count -gt 0) {
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Configurazione {0}: {1}" -f $(if ($importedNames.Count -eq 1) { "della rete Wi-Fi" } else { "delle reti Wi-Fi" }), ($importedNames -join ", "))
        }
        if ($failedNames.Count -gt 0) {
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Configurazione {0}: {1}" -f $(if ($failedNames.Count -eq 1) { "della rete Wi-Fi" } else { "delle reti Wi-Fi" }), ($failedNames -join ", ")) -Status "Error"
        }
    } catch {
        Write-WinUtilWifiLog "Importazione non riuscita: $($_.Exception.Message)" -Level Error
        Add-WinUtilSessionAction -Area "Wi-Fi" -Text "Importazione dei profili Wi-Fi" -Status "Error"
    } finally {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    }

    Invoke-WPFWifiRefresh
}

function Get-WinUtilWifiQRText {
    <#
        .SYNOPSIS
            Returns the Wi-Fi configuration text that phone cameras recognize in a QR code
            (WIFI:T:<type>;S:<ssid>;P:<password>;;), with \ ; , : and " escaped.
        .PARAMETER Network
            A network returned by Get-WinRUtilWifiProfiles.
    #>
    param(
        [Parameter(Mandatory)]
        $Network
    )

    $escape = { param([string]$value) $value -replace '([\\;,:"])', '\$1' }
    $type = switch -Regex ($Network.Security) {
        '^(Aperta|OWE)$' { 'nopass'; break }
        '^WEP$' { 'WEP'; break }
        default { 'WPA' }
    }

    $text = "WIFI:T:{0};S:{1};" -f $type, (& $escape $Network.Ssid)
    if ($type -ne 'nopass') {
        $text += "P:{0};" -f (& $escape $Network.Password)
    }
    if ($Network.Hidden) {
        $text += "H:true;"
    }
    $text + ";"
}

function ConvertTo-WinUtilQRGeometry {
    <#
        .SYNOPSIS
            Returns the dark modules of a QR code (see ConvertTo-WinUtilQRCode) as a frozen geometry,
            one unit per module, without the quiet zone.
    #>
    param(
        [Parameter(Mandatory)]
        $QRCode
    )

    $size = $QRCode.Size
    $modules = $QRCode.Modules
    $geometry = [System.Windows.Media.StreamGeometry]::new()
    $context = $geometry.Open()
    try {
        for ($y = 0; $y -lt $size; $y++) {
            $x = 0
            while ($x -lt $size) {
                if (-not $modules[$y * $size + $x]) {
                    $x++
                    continue
                }
                # One rectangle for each horizontal run of dark modules
                $start = $x
                while ($x -lt $size -and $modules[$y * $size + $x]) { $x++ }
                $context.BeginFigure([System.Windows.Point]::new($start, $y), $true, $true)
                $context.LineTo([System.Windows.Point]::new($x, $y), $false, $false)
                $context.LineTo([System.Windows.Point]::new($x, $y + 1), $false, $false)
                $context.LineTo([System.Windows.Point]::new($start, $y + 1), $false, $false)
            }
        }
    } finally {
        $context.Close()
    }
    $geometry.FillRule = [System.Windows.Media.FillRule]::Nonzero
    $geometry.Freeze()
    $geometry
}

function ConvertTo-WinUtilWifiQRCard {
    <#
        .SYNOPSIS
            Draws the QR code of a Wi-Fi network as a printable card with the network name and the password.
        .PARAMETER QRCode
            The QR code of the network (see ConvertTo-WinUtilQRCode).
        .PARAMETER Network
            The network the QR code connects to.
        .OUTPUTS
            A frozen 96 DPI bitmap.
    #>
    param(
        [Parameter(Mandatory)]
        $QRCode,
        [Parameter(Mandatory)]
        $Network
    )

    # Whole pixels per module keep the module edges sharp; the white margin is the 4-module quiet zone
    $moduleSize = [math]::Max(6, [int][math]::Floor(400 / ($QRCode.Size + 8)))
    $quietZone = 4 * $moduleSize
    $qrSide = $QRCode.Size * $moduleSize
    $width = $qrSide + 2 * $quietZone
    $padding = 24

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo("it-IT")
    $family = [System.Windows.Media.FontFamily]::new("Segoe UI")
    $newText = {
        param([string]$value, $weight, [double]$emSize, [string]$color)
        $typeface = [System.Windows.Media.Typeface]::new($family, [System.Windows.FontStyles]::Normal, $weight, [System.Windows.FontStretches]::Normal)
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($color))
        $formatted = [System.Windows.Media.FormattedText]::new($value, $culture, [System.Windows.FlowDirection]::LeftToRight, $typeface, $emSize, $brush, 1.0)
        $formatted.MaxTextWidth = $width - 2 * $padding
        $formatted.TextAlignment = [System.Windows.TextAlignment]::Center
        $formatted
    }
    $secret = if ($Network.Password) { "Password: $($Network.Password)" } else { "Rete aperta, senza password" }
    $lines = @(
        (& $newText $Network.Ssid ([System.Windows.FontWeights]::Bold) 22 "#111111")
        (& $newText $secret ([System.Windows.FontWeights]::Normal) 16 "#333333")
        (& $newText "Inquadra il codice con la fotocamera del telefono per collegarti alla rete Wi-Fi." ([System.Windows.FontWeights]::Normal) 12.5 "#666666")
    )
    $height = $quietZone + $qrSide + $quietZone + $padding
    foreach ($line in $lines) {
        $height += $line.Height + 6
    }

    $visual = [System.Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $context.DrawRectangle([System.Windows.Media.Brushes]::White, $null, [System.Windows.Rect]::new(0, 0, $width, $height))
    $context.PushTransform([System.Windows.Media.MatrixTransform]::new($moduleSize, 0, 0, $moduleSize, $quietZone, $quietZone))
    $context.DrawGeometry([System.Windows.Media.Brushes]::Black, $null, (ConvertTo-WinUtilQRGeometry -QRCode $QRCode))
    $context.Pop()
    $top = $quietZone + $qrSide + $quietZone
    foreach ($line in $lines) {
        $context.DrawText($line, [System.Windows.Point]::new($padding, $top))
        $top += $line.Height + 6
    }
    $context.Close()

    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($width), [int][math]::Ceiling($height), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $bitmap.Freeze()
    $bitmap
}

function Show-WinUtilWifiQRCode {
    <#
        .SYNOPSIS
            Shows, over the Wi-Fi tab, the QR code that connects a phone to the given network.
        .PARAMETER Network
            A network of the Wi-Fi list.
    #>
    param($Network)

    if (-not $Network) {
        return
    }
    if (-not $Network.CanShare) {
        if ($Network.Security -match 'Enterprise') {
            Write-WinUtilWifiLog "QR code non disponibile per $($Network.Ssid): le reti Enterprise (802.1X) usano credenziali personali." -Level Warning
        } else {
            Write-WinUtilWifiLog "QR code non disponibile per $($Network.Ssid): la password non risulta salvata su questo PC." -Level Warning
        }
        return
    }

    try {
        $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $Network)
    } catch {
        Write-WinUtilWifiLog "Impossibile creare il QR code: $($_.Exception.Message)" -Level Error
        return
    }

    # White background with the 4-module quiet zone, then the dark modules
    $side = $qr.Size + 8
    $drawing = [System.Windows.Media.DrawingGroup]::new()
    $drawing.Children.Add([System.Windows.Media.GeometryDrawing]::new([System.Windows.Media.Brushes]::White, $null, [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $side, $side))))
    $symbol = [System.Windows.Media.DrawingGroup]::new()
    $symbol.Transform = [System.Windows.Media.TranslateTransform]::new(4, 4)
    $symbol.Children.Add([System.Windows.Media.GeometryDrawing]::new([System.Windows.Media.Brushes]::Black, $null, (ConvertTo-WinUtilQRGeometry -QRCode $qr)))
    $drawing.Children.Add($symbol)
    $drawing.Freeze()

    $sync.WifiQrNetwork = $Network
    $sync.WifiQrCode = $qr
    $sync.WPFWifiQrImage.Source = [System.Windows.Media.DrawingImage]::new($drawing)
    $sync.WPFWifiQrSsid.Text = $Network.Ssid
    $sync.WPFWifiQrDetails.Text = if ($Network.Password) { "Sicurezza: $($Network.Security)" } else { "Rete aperta, senza password" }
    $sync.WPFWifiQrOverlay.Visibility = "Visible"
    Write-WinUtilWifiLog "QR code della rete $($Network.Ssid) pronto: inquadralo con la fotocamera del telefono."
}

function Invoke-WPFWifiQrSave {
    <#
        .SYNOPSIS
            Saves the QR code shown in the Wi-Fi tab as a PNG card, with the network name and the password, ready to print.
    #>
    $network = $sync.WifiQrNetwork
    $qr = $sync.WifiQrCode
    if (-not $network -or -not $qr) {
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Salva il QR code della rete Wi-Fi"
    $dialog.Filter = "Immagine PNG (*.png)|*.png"
    $dialog.FileName = "WiFi-{0}.png" -f ($network.Ssid -replace '[\\/:*?"<>|]', '_')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create((ConvertTo-WinUtilWifiQRCard -QRCode $qr -Network $network)))
        $stream = [System.IO.File]::Create($dialog.FileName)
        try {
            $encoder.Save($stream)
        } finally {
            $stream.Dispose()
        }
        Write-WinUtilWifiLog "QR code salvato: $($dialog.FileName)" -Level Success
        if ($network.Password) {
            Write-WinUtilWifiLog "L'immagine contiene la password della rete: condividila solo con chi deve collegarsi." -Level Warning
        }
    } catch {
        Write-WinUtilWifiLog "Salvataggio del QR code non riuscito: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFWifiQrClose {
    <#
        .SYNOPSIS
            Closes the QR code shown in the Wi-Fi tab.
    #>
    $sync.WPFWifiQrOverlay.Visibility = "Collapsed"
    $sync.WPFWifiQrImage.Source = $null
    $sync.WifiQrNetwork = $null
    $sync.WifiQrCode = $null
}
