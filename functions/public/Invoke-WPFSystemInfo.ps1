function Write-WinUtilSystemLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the System tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFSystemLog
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

function Format-WinUtilUptime {
    <#
        .SYNOPSIS
            Formats the time elapsed since the given boot time, e.g. "2g 4h 11m".
    #>
    param([datetime]$BootTime)

    $up = (Get-Date) - $BootTime
    if ($up.Days -gt 0) { "{0}g {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes } else { "{0}h {1}m" -f $up.Hours, $up.Minutes }
}

function Set-WinUtilSystemMemory {
    <#
        .SYNOPSIS
            Fills the memory fields of a system report from the total and the free memory in GB.
    #>
    param($Report, [double]$TotalGB, [double]$FreeGB)

    $free = [math]::Round($FreeGB, 1)
    $used = [math]::Round($TotalGB - $free, 1)
    $Report.RamTotalGB = $TotalGB
    $Report.RamText = "{0:N1} / {1:N1} GB" -f $used, $TotalGB
    $Report.RamUsedPct = if ($TotalGB -gt 0) { [math]::Round(($used / $TotalGB) * 100) } else { 0 }
    $Report.RamFree = "{0:N1} GB" -f $free
}

function Get-WinUtilSystemReport {
    <#
        .SYNOPSIS
            Gathers OS, activation, hardware, BitLocker, CPU, RAM, storage (with SMART health),
            GPU, network, battery and Windows Update information via CIM/WMI and COM. Returns a
            hashtable of preformatted strings (plus numeric percentages for the progress bars).
            Every section is isolated so a single failing query never aborts the report.
    #>

    $r = @{}

    # Helpers (local) ----------------------------------------------------------
    $toGB = { param($bytes) try { [math]::Round([double]$bytes / 1GB, 1) } catch { 0 } }
    $nd   = "Non disponibile"
    $dot  = [char]0x00B7

    # OS / build ---------------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $r.OSCaption = ($os.Caption -replace 'Microsoft ', '').Trim()
        $display = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        $buildStr = "$($os.Version)"
        if ($ubr) { $buildStr = "$($os.Version).$ubr" }
        $verPart = if ($display) { "versione $display" } else { "" }
        $r.OSBuild = ("{0}  {3}  build {1}  {3}  {2}" -f $verPart, $buildStr, $os.OSArchitecture, $dot).TrimStart(" $dot").Trim()
        $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = try { (Get-Date $os.InstallDate -Format 'dd/MM/yyyy') } catch { $nd }
        $r.BootTime = $os.LastBootUpTime
        $r.Uptime = Format-WinUtilUptime $os.LastBootUpTime
    } catch {
        $r.OSCaption = "Windows"; $r.OSBuild = $nd; $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = $nd; $r.Uptime = $nd
    }

    # Activation ---------------------------------------------------------------
    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
            -ErrorAction Stop | Select-Object -First 1
        switch ([int]$lic.LicenseStatus) {
            1       { $r.ActivationText = "Windows attivato";        $r.ActivationColorKey = "SuccessColor" }
            2       { $r.ActivationText = "Periodo di prova (OOB)";  $r.ActivationColorKey = "WarningColor" }
            3       { $r.ActivationText = "Periodo di prova (OOT)";  $r.ActivationColorKey = "WarningColor" }
            4       { $r.ActivationText = "Copia non genuina";       $r.ActivationColorKey = "DangerColor" }
            5       { $r.ActivationText = "Non attivato";            $r.ActivationColorKey = "DangerColor" }
            6       { $r.ActivationText = "Tolleranza estesa";       $r.ActivationColorKey = "WarningColor" }
            default { $r.ActivationText = "Non attivato";            $r.ActivationColorKey = "DangerColor" }
        }
    } catch {
        $r.ActivationText = "Stato sconosciuto"; $r.ActivationColorKey = "MutedForegroundColor"
    }

    # Hardware -----------------------------------------------------------------
    try {
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $r.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { $nd }
        $r.Model = if ($cs.Model) { $cs.Model.Trim() } else { $nd }
        $r.Serial = if ($bios -and $bios.SerialNumber -and $bios.SerialNumber -notmatch '^(0+|To be filled.*|Default.*|System Serial.*)$') { $bios.SerialNumber.Trim() } else { $nd }
        $r.Bios = if ($bios) { ("{0}" -f $bios.SMBIOSBIOSVersion).Trim() } else { $nd }
    } catch {
        $r.Manufacturer = $nd; $r.Model = $nd; $r.Serial = $nd; $r.Bios = $nd
    }

    # Secure Boot
    $r.SecureBoot = try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { "Attivo" } else { "Disattivato" }
    } catch { $nd }

    # TPM
    $r.Tpm = try {
        $t = Get-Tpm -ErrorAction Stop
        if (-not $t.TpmPresent) { "Assente" }
        elseif ($t.TpmEnabled) { "Presente e attivo" }
        else                    { "Presente (disattivato)" }
    } catch {
        try {
            $tc = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -Class Win32_Tpm -ErrorAction Stop
            if ($tc.IsEnabled_InitialValue) { "Presente e attivo" } else { "Presente (disattivato)" }
        } catch { $nd }
    }

    # BitLocker on the system drive (requires administrator rights)
    $r.BitLocker = $nd
    try {
        $vol = Get-CimInstance -Namespace 'root/cimv2/security/microsoftvolumeencryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1
        if ($vol) {
            $protected = ([int]$vol.ProtectionStatus -eq 1)
            $conv = $null
            try { $conv = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus -ErrorAction Stop } catch { }
            if ($conv -and $conv.ReturnValue -eq 0) {
                $pct = [int]$conv.EncryptionPercentage
                $r.BitLocker = switch ([int]$conv.ConversionStatus) {
                    0 { "Disattivato" }
                    1 { if ($protected) { "Attivo" } else { "Protezione sospesa" } }
                    2 { "Cifratura in corso ($pct%)" }
                    3 { "Decifratura in corso ($pct%)" }
                    4 { "Cifratura in pausa ($pct%)" }
                    5 { "Decifratura in pausa ($pct%)" }
                    default { if ($protected) { "Attivo" } else { "Disattivato" } }
                }
            } else {
                $r.BitLocker = if ($protected) { "Attivo" } else { "Disattivato" }
            }
        }
    } catch { }

    # CPU ----------------------------------------------------------------------
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $cpu = $cpus[0]
        $r.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $r.CpuCores = "$cores core / $threads thread"
        $r.CpuClock = "{0:N2} GHz" -f ([double]$cpu.MaxClockSpeed / 1000)
        $load = [math]::Round(($cpus | Measure-Object -Property LoadPercentage -Average).Average)
        $r.CpuLoadPct = [double]$load
        $r.CpuLoad = "$load%"
    } catch {
        $r.CpuName = $nd; $r.CpuCores = $nd; $r.CpuClock = $nd; $r.CpuLoadPct = 0; $r.CpuLoad = "-"
    }

    # RAM ----------------------------------------------------------------------
    try {
        if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        Set-WinUtilSystemMemory -Report $r -TotalGB (& $toGB $cs.TotalPhysicalMemory) -FreeGB (([double]$os.FreePhysicalMemory * 1KB) / 1GB)
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($mods.Count -gt 0) {
            $speed = ($mods | Select-Object -First 1).Speed
            $r.RamModules = "{0} modulo/i @ {1} MHz" -f $mods.Count, $speed
        } else { $r.RamModules = $nd }
    } catch {
        $r.RamText = $nd; $r.RamUsedPct = 0; $r.RamFree = $nd; $r.RamModules = $nd
    }

    # Storage ------------------------------------------------------------------
    $disks = New-Object System.Collections.Generic.List[object]
    try {
        $vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
        foreach ($v in ($vols | Select-Object -First 4)) {
            if (-not $v.Size -or $v.Size -eq 0) { continue }
            $sizeGB = & $toGB $v.Size
            $freeGB = & $toGB $v.FreeSpace
            $usedPct = [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100)
            $label = $v.DeviceID
            if ($v.VolumeName) { $label = "{0}  {1}" -f $v.DeviceID, $v.VolumeName }
            $disks.Add(@{
                Label   = $label
                Text    = ("{0:N0} GB liberi su {1:N0} GB" -f $freeGB, $sizeGB)
                UsedPct = $usedPct
                Warn    = ($usedPct -ge 90)
            })
        }
    } catch { }
    $r.Disks = $disks

    # SMART / physical-disk health
    try {
        $health = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -ExpandProperty HealthStatus -Unique)
        if ($health -contains 'Unhealthy') { $r.DiskHealthText = "Salute: Critico";    $r.DiskHealthColorKey = "DangerColor" }
        elseif ($health -contains 'Warning') { $r.DiskHealthText = "Salute: Attenzione"; $r.DiskHealthColorKey = "WarningColor" }
        elseif ($health -contains 'Healthy') { $r.DiskHealthText = "Salute: OK";         $r.DiskHealthColorKey = "SuccessColor" }
        else                                 { $r.DiskHealthText = "Salute: n/d";        $r.DiskHealthColorKey = "MutedForegroundColor" }
    } catch {
        $r.DiskHealthText = "Salute: n/d"; $r.DiskHealthColorKey = "MutedForegroundColor"
    }

    # GPU ----------------------------------------------------------------------
    $r.GpuName = $nd; $r.GpuVram = $nd; $r.GpuDriver = $nd; $r.GpuResolution = $nd
    try {
        $allGpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        # Prefer real adapters, but keep the basic/remote one if it is all we have
        $real = @($allGpus | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Mirror|Basic Display|DameWare|Meta Virtual' })
        $gpus = if ($real.Count -gt 0) { $real } else { $allGpus }

        $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) { $r.GpuName = ($names -join "  $dot  ") }

        $g0 = $gpus | Select-Object -First 1
        if ($g0) {
            # VRAM: Win32_VideoController.AdapterRAM is a 32-bit value capped at ~4 GB,
            # so prefer the accurate qwMemorySize from the display-adapter registry key.
            $vramBytes = 0
            try {
                $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                Get-ChildItem $base -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                    $q = (Get-ItemProperty -Path $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
                    if ($q -and [double]$q -gt $vramBytes) { $vramBytes = [double]$q }
                }
            } catch { }
            try {
                if ($vramBytes -le 0 -and $g0.AdapterRAM) { $vramBytes = [double]$g0.AdapterRAM }
                if ($vramBytes -gt 0) {
                    $vramGB = [math]::Round($vramBytes / 1GB, 0)
                    if ($vramGB -ge 1) { $r.GpuVram = "{0:N0} GB" -f $vramGB }
                }
            } catch { }
            if ($g0.DriverVersion) { $r.GpuDriver = $g0.DriverVersion }
        }

        $active = $gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($active) { $r.GpuResolution = "{0} x {1}" -f $active.CurrentHorizontalResolution, $active.CurrentVerticalResolution }
    } catch { }

    # Network ------------------------------------------------------------------
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4Address -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' })
        # Prefer the adapter with a default gateway, so virtual switches and VPNs do not hide the real connection
        $cfg = @($configs | Where-Object { $_.IPv4DefaultGateway }) + $configs | Select-Object -First 1
        if ($cfg) {
            $r.NetAdapter = $cfg.InterfaceAlias
            $r.NetIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
            $r.NetMac = if ($cfg.NetAdapter.MacAddress) { $cfg.NetAdapter.MacAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } else { throw "no up adapter" }
    } catch {
        try {
            $na = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop | Select-Object -First 1
            $r.NetAdapter = $na.Description
            $r.NetIp = ($na.IPAddress | Where-Object { $_ -match '\.' } | Select-Object -First 1)
            $r.NetMac = if ($na.MACAddress) { $na.MACAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } catch {
            $r.NetAdapter = $nd; $r.NetIp = "n/d"; $r.NetMac = $nd; $r.NetStatus = "Non connesso"
        }
    }

    # Battery ------------------------------------------------------------------
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($batt) {
            $r.HasBattery = $true
            $r.BatteryPct = [double]$batt.EstimatedChargeRemaining
            $r.BatteryCharge = "{0}%" -f [int]$batt.EstimatedChargeRemaining
            $r.BatteryStatus = switch ([int]$batt.BatteryStatus) {
                1 { "In uso (a batteria)" }
                2 { "Alimentazione di rete" }
                3 { "Carica completa" }
                4 { "Bassa" }
                5 { "Critica" }
                6 { "In carica" }
                7 { "In carica (alta)" }
                8 { "In carica (bassa)" }
                9 { "In carica (critica)" }
                default { "Sconosciuto" }
            }
            $r.BatteryHealth = $nd
            try {
                $static = Get-CimInstance -Namespace root/wmi -Class BatteryStaticData -ErrorAction Stop | Select-Object -First 1
                $full   = Get-CimInstance -Namespace root/wmi -Class BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($static.DesignedCapacity -gt 0 -and $full.FullChargedCapacity -gt 0) {
                    $wear = [math]::Round((1 - ($full.FullChargedCapacity / $static.DesignedCapacity)) * 100, 1)
                    if ($wear -lt 0) { $wear = 0 }
                    $r.BatteryHealth = "{0:N0}% usura" -f $wear
                }
            } catch { }
        } else { $r.HasBattery = $false }
    } catch { $r.HasBattery = $false }

    # Windows Update -----------------------------------------------------------
    # The Windows Update Agent reports dates in UTC
    $toLocalDate = {
        param($value)
        $date = [datetime]$value
        if ($date.Year -lt 2000) { return $nd }
        [datetime]::SpecifyKind($date, [System.DateTimeKind]::Utc).ToLocalTime().ToString('dd/MM/yyyy HH:mm')
    }
    $r.UpdatesLastInstall = $nd; $r.UpdatesLastSearch = $nd; $r.UpdatesRecent = @()
    try {
        $results = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
        if ($results.LastInstallationSuccessDate) { $r.UpdatesLastInstall = & $toLocalDate $results.LastInstallationSuccessDate }
        if ($results.LastSearchSuccessDate) { $r.UpdatesLastSearch = & $toLocalDate $results.LastSearchSuccessDate }
    } catch { }
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $total = $searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            $recent = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $searcher.QueryHistory(0, [math]::Min($total, 300))) {
                # Completed installations and removals (Operation 1/2, ResultCode 2-5), newest first and
                # one row per update, without the daily Defender definition updates (KB2267602 / KB915597)
                # and the Microsoft Store app updates
                if ($entry.Operation -notin @(1, 2) -or $entry.ResultCode -notin @(2, 3, 4, 5) -or -not $entry.Title) { continue }
                if ($entry.Title -match '2267602|915597' -or $entry.Title -match '^9[0-9A-Z]{11}-') { continue }
                if ($recent | Where-Object { $_.Title -eq $entry.Title }) { continue }

                # Localized titles use either "(KB5031234)" or "- 4052623 KB"
                $kb = if ($entry.Title -match 'KB\s*(\d{6,8})' -or $entry.Title -match '(\d{6,8})\s*KB') { "KB$($Matches[1])" } else { "" }
                $result, $level = if ($entry.Operation -eq 2) {
                    if ($entry.ResultCode -in @(2, 3)) { "Rimosso", "Muted" } else { "Rimozione non riuscita", "Danger" }
                } else {
                    switch ($entry.ResultCode) {
                        2 { "Installato", "Success" }
                        3 { "Installato con errori", "Warning" }
                        4 { "Non riuscito", "Danger" }
                        default { "Annullato", "Warning" }
                    }
                }
                if ($entry.ResultCode -ne 2 -and $entry.HResult -ne 0) { $result = "{0} ({1})" -f $result, ('0x{0:X8}' -f $entry.HResult) }
                $recent.Add([pscustomobject]@{
                    Date = (& $toLocalDate $entry.Date); Title = $entry.Title; KB = $kb; Result = $result; Level = $level
                })
                if ($recent.Count -ge 15) { break }
            }
            $r.UpdatesRecent = $recent.ToArray()
        }
    } catch { }

    return $r
}

function Set-WinUtilSystemBar {
    <#
        .SYNOPSIS
            Fills one of the System dashboard progress bars (a two-column star grid).
            Colors are theme resource references, so they follow a later theme change.
    #>
    param($Grid, [double]$Percent, [bool]$Warn)

    if (-not $Grid) { return }
    $p = [math]::Max(0, [math]::Min(100, $Percent))
    $Grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new($p, [System.Windows.GridUnitType]::Star)
    $Grid.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new((100 - $p), [System.Windows.GridUnitType]::Star)
    $colorKey = if ($Warn) { "DangerColor" } else { "AccentColor" }
    $Grid.Children[0].SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $colorKey)
}

function Invoke-WPFSystemInfoRefresh {
    <#
        .SYNOPSIS
            Refreshes the System dashboard. Gathers the report on a background runspace
            and pushes every value to the WPF controls on the UI thread, so the window
            never freezes while data is collected.
    #>

    if ($sync.SystemInfoLoading) { return }
    $sync.SystemInfoLoading = $true
    Write-WinUtilSystemLog "Raccolta delle informazioni di sistema in corso..."

    Invoke-WPFRunspace -ScriptBlock {
        try {
            $report = Get-WinUtilSystemReport
            $sync.SystemReport = $report

            Invoke-WPFUIThread -ScriptBlock {
                $r = $sync.SystemReport

                # Hero
                $sync.WPFSysOSCaption.Text   = $r.OSCaption
                $sync.WPFSysOSBuild.Text      = $r.OSBuild
                $sync.WPFSysHostname.Text     = $r.Hostname
                $sync.WPFSysUptime.Text       = $r.Uptime
                $sync.WPFSysInstallDate.Text  = $r.InstallDate
                $sync.WPFSysActivation.Text   = $r.ActivationText
                $sync.WPFSysActivation.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $r.ActivationColorKey)
                $sync.WPFSysActivationDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $r.ActivationColorKey)

                # Hardware
                $sync.WPFSysManufacturer.Text = $r.Manufacturer
                $sync.WPFSysModel.Text        = $r.Model
                $sync.WPFSysSerial.Text       = $r.Serial
                $sync.WPFSysBios.Text         = $r.Bios
                $sync.WPFSysSecureBoot.Text   = $r.SecureBoot
                $sync.WPFSysTpm.Text          = $r.Tpm
                $sync.WPFSysBitLocker.Text    = $r.BitLocker

                # CPU
                $sync.WPFSysCpuName.Text  = $r.CpuName
                $sync.WPFSysCpuCores.Text = $r.CpuCores
                $sync.WPFSysCpuClock.Text = $r.CpuClock
                $sync.WPFSysCpuLoad.Text  = $r.CpuLoad
                Set-WinUtilSystemBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                # RAM
                $sync.WPFSysRamText.Text    = $r.RamText
                $sync.WPFSysRamFree.Text    = $r.RamFree
                $sync.WPFSysRamModules.Text = $r.RamModules
                Set-WinUtilSystemBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)

                # Storage
                $sync.WPFSysDiskHealth.Text       = $r.DiskHealthText
                $sync.WPFSysDiskHealth.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $r.DiskHealthColorKey)
                for ($i = 0; $i -lt 4; $i++) {
                    $panel = $sync["WPFSysDisk$i"]
                    if (-not $panel) { continue }
                    if ($i -lt $r.Disks.Count) {
                        $d = $r.Disks[$i]
                        $sync["WPFSysDisk${i}Label"].Text = $d.Label
                        $sync["WPFSysDisk${i}Text"].Text  = $d.Text
                        Set-WinUtilSystemBar $sync["WPFSysDisk${i}Bar"] $d.UsedPct $d.Warn
                        $panel.Visibility = "Visible"
                    } else {
                        $panel.Visibility = "Collapsed"
                    }
                }

                # GPU
                $sync.WPFSysGpuName.Text       = $r.GpuName
                $sync.WPFSysGpuVram.Text       = $r.GpuVram
                $sync.WPFSysGpuResolution.Text = $r.GpuResolution
                $sync.WPFSysGpuDriver.Text     = $r.GpuDriver

                # Network
                $sync.WPFSysNetAdapter.Text = $r.NetAdapter
                $sync.WPFSysNetIp.Text      = $r.NetIp
                $sync.WPFSysNetMac.Text     = $r.NetMac
                $sync.WPFSysNetStatus.Text  = $r.NetStatus

                # Windows Update
                $sync.WPFSysUpdLastInstall.Text = $r.UpdatesLastInstall
                $sync.WPFSysUpdLastSearch.Text  = $r.UpdatesLastSearch
                $sync.WPFSysUpdList.ItemsSource = @($r.UpdatesRecent)
                $hasUpdates = @($r.UpdatesRecent).Count -gt 0
                $sync.WPFSysUpdTable.Visibility = if ($hasUpdates) { "Visible" } else { "Collapsed" }
                $sync.WPFSysUpdEmpty.Visibility = if ($hasUpdates) { "Collapsed" } else { "Visible" }

                # Battery
                if ($r.HasBattery) {
                    $sync.WPFSysBatteryCard.Visibility = "Visible"
                    $sync.WPFSysBatteryCharge.Text = $r.BatteryCharge
                    $sync.WPFSysBatteryStatus.Text = $r.BatteryStatus
                    $sync.WPFSysBatteryHealth.Text = $r.BatteryHealth
                    Set-WinUtilSystemBar $sync.WPFSysBatteryBar $r.BatteryPct ($r.BatteryPct -le 15)
                } else {
                    $sync.WPFSysBatteryCard.Visibility = "Collapsed"
                }
            }

            Write-WinUtilSystemLog "Informazioni di sistema aggiornate." -Level Success
        } catch {
            Write-WinUtilSystemLog "Errore durante la lettura del sistema: $($_.Exception.Message)" -Level Error
        } finally {
            $sync.SystemInfoLoading = $false
        }
    }
}

function Start-WinUtilSystemLiveUpdate {
    <#
        .SYNOPSIS
            Refreshes CPU load, memory usage and uptime of the System dashboard every two seconds
            while the dashboard is open. The values are read on the runspace pool, so the UI never waits.
    #>

    if (-not $sync.SystemLiveTimer) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2)
        $timer.Add_Tick({ Update-WinUtilSystemLiveData })
        $sync.SystemLiveTimer = $timer
    }
    $sync.SystemLiveTimer.Start()
}

function Stop-WinUtilSystemLiveUpdate {
    <#
        .SYNOPSIS
            Stops the live refresh of the System dashboard.
    #>

    if ($sync.SystemLiveTimer) { $sync.SystemLiveTimer.Stop() }
}

function Update-WinUtilSystemLiveData {
    <#
        .SYNOPSIS
            Timer tick of the live System dashboard (UI thread): shows the result of the previous
            query and starts the next one. Reading the CPU load takes about one second.
    #>

    $job = $sync.SystemLiveJob
    if ($job) {
        if (-not $job.Handle.IsCompleted) { return }
        try {
            $data = @($job.PowerShell.EndInvoke($job.Handle)) | Select-Object -Last 1
            $r = $sync.SystemReport
            if ($data -and $r) {
                $r.CpuLoadPct = [double]$data.CpuLoadPct
                $r.CpuLoad = "$($data.CpuLoadPct)%"
                $sync.WPFSysCpuLoad.Text = $r.CpuLoad
                Set-WinUtilSystemBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                if ($r.RamTotalGB -gt 0) {
                    Set-WinUtilSystemMemory -Report $r -TotalGB $r.RamTotalGB -FreeGB $data.FreeGB
                    $sync.WPFSysRamText.Text = $r.RamText
                    $sync.WPFSysRamFree.Text = $r.RamFree
                    Set-WinUtilSystemBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)
                }

                if ($r.BootTime) {
                    $r.Uptime = Format-WinUtilUptime $r.BootTime
                    $sync.WPFSysUptime.Text = $r.Uptime
                }
            }
        } catch {
            Write-Debug "Live system update failed: $($_.Exception.Message)"
        } finally {
            $job.PowerShell.Dispose()
            $sync.SystemLiveJob = $null
        }
    }

    if (-not $sync.runspace -or $sync.Form.WindowState -eq [System.Windows.WindowState]::Minimized) { return }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $sync.runspace
    [void]$ps.AddScript({
        $load = (Get-CimInstance -ClassName Win32_Processor -Property LoadPercentage | Measure-Object -Property LoadPercentage -Average).Average
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory
        [pscustomobject]@{
            CpuLoadPct = [math]::Round([double]$load)
            FreeGB     = ([double]$os.FreePhysicalMemory * 1KB) / 1GB
        }
    }.ToString())
    $sync.SystemLiveJob = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function ConvertTo-WinUtilSystemReportText {
    <#
        .SYNOPSIS
            Formats a system report (see Get-WinUtilSystemReport) as plain text.
    #>
    param([Parameter(Mandatory)][hashtable]$Report)

    $r = $Report
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("WinRUtil - Report di sistema")
    $null = $sb.AppendLine("Generato il $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    $null = $sb.AppendLine(("=" * 56))
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ WINDOWS ]")
    $null = $sb.AppendLine("  Edizione        : $($r.OSCaption)")
    $null = $sb.AppendLine("  Build           : $($r.OSBuild)")
    $null = $sb.AppendLine("  Attivazione     : $($r.ActivationText)")
    $null = $sb.AppendLine("  Nome PC         : $($r.Hostname)")
    $null = $sb.AppendLine("  Installato il   : $($r.InstallDate)")
    $null = $sb.AppendLine("  Acceso da       : $($r.Uptime)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ HARDWARE ]")
    $null = $sb.AppendLine("  Produttore      : $($r.Manufacturer)")
    $null = $sb.AppendLine("  Modello         : $($r.Model)")
    $null = $sb.AppendLine("  N. di serie     : $($r.Serial)")
    $null = $sb.AppendLine("  BIOS / UEFI     : $($r.Bios)")
    $null = $sb.AppendLine("  Secure Boot     : $($r.SecureBoot)")
    $null = $sb.AppendLine("  TPM             : $($r.Tpm)")
    $null = $sb.AppendLine("  BitLocker ($env:SystemDrive)  : $($r.BitLocker)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ PROCESSORE ]")
    $null = $sb.AppendLine("  Modello         : $($r.CpuName)")
    $null = $sb.AppendLine("  Core / Thread   : $($r.CpuCores)")
    $null = $sb.AppendLine("  Frequenza base  : $($r.CpuClock)")
    $null = $sb.AppendLine("  Carico attuale  : $($r.CpuLoad)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ MEMORIA ]")
    $null = $sb.AppendLine("  Utilizzo        : $($r.RamText)")
    $null = $sb.AppendLine("  Disponibile     : $($r.RamFree)")
    $null = $sb.AppendLine("  Moduli          : $($r.RamModules)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine(("[ ARCHIVIAZIONE ]  {0}" -f $r.DiskHealthText))
    foreach ($d in $r.Disks) {
        $null = $sb.AppendLine("  $($d.Label)  -  $($d.Text)  ($($d.UsedPct)% usato)")
    }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ GRAFICA ]")
    $null = $sb.AppendLine("  Scheda          : $($r.GpuName)")
    $null = $sb.AppendLine("  Memoria video   : $($r.GpuVram)")
    $null = $sb.AppendLine("  Risoluzione     : $($r.GpuResolution)")
    $null = $sb.AppendLine("  Driver          : $($r.GpuDriver)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ RETE ]")
    $null = $sb.AppendLine("  Scheda          : $($r.NetAdapter)")
    $null = $sb.AppendLine("  Indirizzo IPv4  : $($r.NetIp)")
    $null = $sb.AppendLine("  Indirizzo MAC   : $($r.NetMac)")
    $null = $sb.AppendLine("  Stato           : $($r.NetStatus)")
    if ($r.HasBattery) {
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("[ BATTERIA ]")
        $null = $sb.AppendLine("  Carica          : $($r.BatteryCharge)")
        $null = $sb.AppendLine("  Stato           : $($r.BatteryStatus)")
        $null = $sb.AppendLine("  Salute          : $($r.BatteryHealth)")
    }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ AGGIORNAMENTI WINDOWS ]")
    $null = $sb.AppendLine("  Ultima installazione : $($r.UpdatesLastInstall)")
    $null = $sb.AppendLine("  Ultima ricerca       : $($r.UpdatesLastSearch)")
    if (@($r.UpdatesRecent).Count -gt 0) {
        $null = $sb.AppendLine("  Cronologia recente:")
        foreach ($u in $r.UpdatesRecent) {
            $null = $sb.AppendLine(("    {0}  {1,-26} {2}" -f $u.Date, $u.Result, $u.Title))
        }
    }
    $sb.ToString()
}

function ConvertTo-WinUtilSystemReportHtml {
    <#
        .SYNOPSIS
            Formats a system report (see Get-WinUtilSystemReport) as a standalone, printable HTML page.
    #>
    param([Parameter(Mandatory)][hashtable]$Report)

    $r = $Report
    $enc = { param($value) [System.Net.WebUtility]::HtmlEncode([string]$value) }
    $row = { param($label, $value, $class) "<tr><td class=""k"">$label</td><td class=""v $class"">$(& $enc $value)</td></tr>" }
    $bar = {
        param($pct, $warn)
        $width = [math]::Max(0, [math]::Min(100, [double]$pct)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $class = if ($warn) { ' class="danger"' } else { '' }
        "<div class=""bar""><i$class style=""width:$width%""></i></div>"
    }
    $card = { param($title, $body) "<section class=""card""><h3>$title</h3>$body</section>" }
    $state = @{ SuccessColor = 'ok'; WarningColor = 'warn'; DangerColor = 'danger' }

    $css = @'
:root{--bg:#f1f4f8;--card:#fff;--border:#d6dce4;--fg:#0f172a;--muted:#556275;--accent:#047857;--warn:#b45309;--danger:#dc2626;--track:#e2e8f0}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1000px;margin:0 auto;padding:32px 16px}
header{margin-bottom:20px}
.brand{margin:0;color:var(--accent);font-weight:700}
h1{margin:2px 0 0;font-size:26px;line-height:1.2}
.meta{margin:4px 0 0;color:var(--muted)}
.hero{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-start;background:#ecfdf5;border:1px solid #a7f3d0;border-radius:16px;padding:20px 22px;margin-bottom:16px}
.hero h2{margin:0;font-size:22px}
.facts{display:flex;flex-wrap:wrap;gap:28px;margin-top:12px}
.facts span{display:block;font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
.facts b{font-size:14px}
.pill{border-radius:999px;padding:6px 14px;font-weight:600;background:#fff;border:1px solid var(--border)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px 18px}
h3{margin:0 0 10px;font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
table{width:100%;border-collapse:collapse}
td{padding:3px 0;vertical-align:top}
td.k{color:var(--muted);padding-right:12px;white-space:nowrap}
td.v{text-align:right;overflow-wrap:anywhere}
.big{font-size:20px;font-weight:700;margin:0}
.bar{height:6px;border-radius:3px;background:var(--track);overflow:hidden;margin:4px 0 10px}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.danger{background:var(--danger)}
.disk{display:flex;justify-content:space-between;gap:12px;font-weight:600}
.disk span{font-weight:400;color:var(--muted);font-size:12px}
.ok{color:var(--accent)}
.warn{color:var(--warn)}
.danger{color:var(--danger)}
.muted{color:var(--muted)}
.nw{white-space:nowrap}
.wide{margin-top:16px}
.wide .facts{margin-top:0}
table.list{margin-top:14px}
table.list th{text-align:left;font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted);padding:4px 14px 6px 0}
table.list td{padding:6px 14px 6px 0;border-top:1px solid var(--border)}
footer{margin-top:24px;color:var(--muted);font-size:12px}
@media print{body{background:#fff}main{padding:0}.hero,.card{break-inside:avoid}.card.wide{break-inside:auto}tr{break-inside:avoid}}
'@

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="it">')
    $null = $sb.AppendLine('<head>')
    $null = $sb.AppendLine('<meta charset="utf-8">')
    $null = $sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $null = $sb.AppendLine("<title>Report di sistema - $(& $enc $r.Hostname)</title>")
    $null = $sb.AppendLine("<style>`r`n$css</style>")
    $null = $sb.AppendLine('</head>')
    $null = $sb.AppendLine('<body>')
    $null = $sb.AppendLine('<main>')
    $null = $sb.AppendLine('<header><p class="brand">WinRUtil</p><h1>Report di sistema</h1>')
    $null = $sb.AppendLine("<p class=""meta"">$(& $enc $r.Hostname) &middot; generato il $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p></header>")

    $null = $sb.AppendLine('<section class="hero"><div>')
    $null = $sb.AppendLine("<h2>$(& $enc $r.OSCaption)</h2><p class=""meta"">$(& $enc $r.OSBuild)</p>")
    $null = $sb.AppendLine("<div class=""facts""><div><span>Nome PC</span><b>$(& $enc $r.Hostname)</b></div><div><span>Acceso da</span><b>$(& $enc $r.Uptime)</b></div><div><span>Installato il</span><b>$(& $enc $r.InstallDate)</b></div></div>")
    $null = $sb.AppendLine("</div><span class=""pill $($state[[string]$r.ActivationColorKey])"">$(& $enc $r.ActivationText)</span></section>")

    $null = $sb.AppendLine('<div class="grid">')

    $body = '<table>' +
        (& $row 'Produttore' $r.Manufacturer) +
        (& $row 'Modello' $r.Model) +
        (& $row 'N. di serie' $r.Serial) +
        (& $row 'BIOS / UEFI' $r.Bios) +
        (& $row 'Secure Boot' $r.SecureBoot) +
        (& $row 'TPM' $r.Tpm) +
        (& $row "BitLocker ($env:SystemDrive)" $r.BitLocker) + '</table>'
    $null = $sb.AppendLine((& $card 'Hardware' $body))

    $body = "<p><b>$(& $enc $r.CpuName)</b></p><table>" +
        (& $row 'Core / Thread' $r.CpuCores) +
        (& $row 'Frequenza base' $r.CpuClock) +
        (& $row 'Carico' $r.CpuLoad) + '</table>' + (& $bar $r.CpuLoadPct ($r.CpuLoadPct -ge 90))
    $null = $sb.AppendLine((& $card 'Processore' $body))

    $body = "<p class=""big"">$(& $enc $r.RamText)</p>" + (& $bar $r.RamUsedPct ($r.RamUsedPct -ge 90)) + '<table>' +
        (& $row 'Disponibile' $r.RamFree) +
        (& $row 'Moduli' $r.RamModules) + '</table>'
    $null = $sb.AppendLine((& $card 'Memoria' $body))

    $body = "<p class=""$($state[[string]$r.DiskHealthColorKey])"">$(& $enc $r.DiskHealthText)</p>"
    foreach ($d in $r.Disks) {
        $body += "<div class=""disk"">$(& $enc $d.Label)<span>$(& $enc $d.Text)</span></div>" + (& $bar $d.UsedPct $d.Warn)
    }
    $null = $sb.AppendLine((& $card 'Archiviazione' $body))

    $body = "<p><b>$(& $enc $r.GpuName)</b></p><table>" +
        (& $row 'Memoria video' $r.GpuVram) +
        (& $row 'Risoluzione' $r.GpuResolution) +
        (& $row 'Driver' $r.GpuDriver) + '</table>'
    $null = $sb.AppendLine((& $card 'Grafica' $body))

    $body = '<table>' +
        (& $row 'Scheda' $r.NetAdapter) +
        (& $row 'Indirizzo IPv4' $r.NetIp) +
        (& $row 'Indirizzo MAC' $r.NetMac) +
        (& $row 'Stato' $r.NetStatus) + '</table>'
    $null = $sb.AppendLine((& $card 'Rete' $body))

    if ($r.HasBattery) {
        $body = "<p class=""big"">$(& $enc $r.BatteryCharge)</p>" + (& $bar $r.BatteryPct ($r.BatteryPct -le 15)) + '<table>' +
            (& $row 'Stato' $r.BatteryStatus) +
            (& $row 'Salute' $r.BatteryHealth) + '</table>'
        $null = $sb.AppendLine((& $card 'Batteria' $body))
    }

    $null = $sb.AppendLine('</div>')

    # Windows Update history as a full-width table, as in the dashboard
    $level = @{ Success = 'ok'; Warning = 'warn'; Danger = 'danger'; Muted = 'muted' }
    $body = "<div class=""facts""><div><span>Ultima installazione</span><b>$(& $enc $r.UpdatesLastInstall)</b></div>" +
        "<div><span>Ultima ricerca</span><b>$(& $enc $r.UpdatesLastSearch)</b></div></div>"
    if (@($r.UpdatesRecent).Count -gt 0) {
        $body += '<table class="list"><thead><tr><th>Data</th><th>Aggiornamento</th><th>KB</th><th>Esito</th></tr></thead><tbody>' +
            (-join (@($r.UpdatesRecent) | ForEach-Object {
                "<tr><td class=""nw muted"">$(& $enc $_.Date)</td><td>$(& $enc $_.Title)</td><td class=""nw"">$(& $enc $_.KB)</td>" +
                "<td class=""nw $($level[[string]$_.Level])"">$(& $enc $_.Result)</td></tr>"
            })) + '</tbody></table>'
    }
    $null = $sb.AppendLine("<section class=""card wide""><h3>Aggiornamenti Windows</h3>$body</section>")
    $null = $sb.AppendLine("<footer>Generato con WinRUtil $(& $enc $sync.version) &middot; https://github.com/rtecnocopy89/WinRUtil</footer>")
    $null = $sb.AppendLine('</main>')
    $null = $sb.AppendLine('</body>')
    $null = $sb.AppendLine('</html>')
    $sb.ToString()
}

function Invoke-WPFSystemInfoExport {
    <#
        .SYNOPSIS
            Asks where to save the system report and writes it as an HTML page (opened in the
            default browser, ready to print or save as PDF) or as plain text.
    #>

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Esporta il report di sistema"
    $dialog.Filter = "Report HTML (*.html)|*.html|Testo semplice (*.txt)|*.txt"
    $dialog.FileName = "WinRUtil-Sistema_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilSystemLog "Esportazione del report annullata." -Level Warning
        return
    }
    $sync.SystemReportExportPath = $dialog.FileName

    Write-WinUtilSystemLog "Creazione del report di sistema..."
    Invoke-WPFRunspace -ScriptBlock {
        try {
            $path = $sync.SystemReportExportPath
            $r = $sync.SystemReport
            if (-not $r) { $r = Get-WinUtilSystemReport; $sync.SystemReport = $r }

            $isText = [System.IO.Path]::GetExtension($path) -ieq '.txt'
            $content = if ($isText) { ConvertTo-WinUtilSystemReportText -Report $r } else { ConvertTo-WinUtilSystemReportHtml -Report $r }
            [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($true))
            Write-WinUtilSystemLog "Report salvato: $path" -Level Success
            if (-not $isText) { Start-Process -FilePath $path }
        } catch {
            Write-WinUtilSystemLog "Impossibile creare il report: $($_.Exception.Message)" -Level Error
        }
    }
}
