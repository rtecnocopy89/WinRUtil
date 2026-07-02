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
        Array of [PSCustomObject] with properties: Ssid, Password, Security, AutoConnect.
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

                    $keyNode = $doc.SelectSingleNode("//*[local-name()='keyMaterial']")
                    if ($keyNode) {
                        $hasKeyElement = $true
                        $keyMaterial = $keyNode.InnerText
                    }

                    $cmNode = $doc.SelectSingleNode("//*[local-name()='connectionMode']")
                    if ($cmNode) { $connectionMode = $cmNode.InnerText }

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
                    if ($raw -match '(?s)<name>(.*?)</name>') { $ssid = $matches[1] }
                    if ($raw -match '(?s)<authentication>(.*?)</authentication>') { $authentication = $matches[1] }
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

                # AutoConnect: Italian Si / No based on connectionMode.
                if ($connectionMode -and $connectionMode.Trim().ToLowerInvariant() -eq 'auto') {
                    $autoConnect = 'Si'
                }
                else {
                    $autoConnect = 'No'
                }

                # Map the raw authentication token to a human-readable label.
                $security = switch -Regex ($authUpper) {
                    '^OPEN$'        { 'Aperta'; break }
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
