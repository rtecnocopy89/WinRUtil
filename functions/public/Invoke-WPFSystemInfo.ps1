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

function Get-WinUtilSystemReport {
    <#
        .SYNOPSIS
            Gathers OS, activation, hardware, CPU, RAM, storage (with SMART health),
            GPU, network and battery information via CIM/WMI. Returns a hashtable of
            preformatted strings (plus numeric percentages for the progress bars).
            Every section is isolated so a single failing query never aborts the report.
    #>

    $r = @{}

    # Helpers (local) ----------------------------------------------------------
    $toGB = { param($bytes) try { [math]::Round([double]$bytes / 1GB, 1) } catch { 0 } }
    $nd   = "Non disponibile"

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
        $r.OSBuild = ("{0}  ·  build {1}  ·  {2}" -f $verPart, $buildStr, $os.OSArchitecture).TrimStart(' ·').Trim()
        $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = try { (Get-Date $os.InstallDate -Format 'dd/MM/yyyy') } catch { $nd }
        $boot = $os.LastBootUpTime
        $up = (Get-Date) - $boot
        $r.Uptime = if ($up.Days -gt 0) { "{0}g {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes } else { "{0}h {1}m" -f $up.Hours, $up.Minutes }
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
            1       { $r.ActivationText = "Windows attivato";        $r.ActivationColor = "#3DF5A0" }
            2       { $r.ActivationText = "Periodo di prova (OOB)";  $r.ActivationColor = "#F5A623" }
            3       { $r.ActivationText = "Periodo di prova (OOT)";  $r.ActivationColor = "#F5A623" }
            4       { $r.ActivationText = "Copia non genuina";       $r.ActivationColor = "#EF4444" }
            5       { $r.ActivationText = "Non attivato";            $r.ActivationColor = "#EF4444" }
            6       { $r.ActivationText = "Tolleranza estesa";       $r.ActivationColor = "#F5A623" }
            default { $r.ActivationText = "Non attivato";            $r.ActivationColor = "#EF4444" }
        }
    } catch {
        $r.ActivationText = "Stato sconosciuto"; $r.ActivationColor = "#8A93A6"
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
        $totalGB = & $toGB $cs.TotalPhysicalMemory
        $freeGB  = [math]::Round(([double]$os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $r.RamText = "{0:N1} / {1:N1} GB" -f $usedGB, $totalGB
        $r.RamUsedPct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100) } else { 0 }
        $r.RamFree = "{0:N1} GB" -f $freeGB
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
        if ($health -contains 'Unhealthy') { $r.DiskHealthText = "Salute: Critico";    $r.DiskHealthColor = "#EF4444" }
        elseif ($health -contains 'Warning') { $r.DiskHealthText = "Salute: Attenzione"; $r.DiskHealthColor = "#F5A623" }
        elseif ($health -contains 'Healthy') { $r.DiskHealthText = "Salute: OK";         $r.DiskHealthColor = "#3DF5A0" }
        else                                 { $r.DiskHealthText = "Salute: n/d";        $r.DiskHealthColor = "#8A93A6" }
    } catch {
        $r.DiskHealthText = "Salute: n/d"; $r.DiskHealthColor = "#8A93A6"
    }

    # GPU ----------------------------------------------------------------------
    $r.GpuName = $nd; $r.GpuVram = $nd; $r.GpuDriver = $nd; $r.GpuResolution = $nd
    try {
        $allGpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        # Prefer real adapters, but keep the basic/remote one if it is all we have
        $real = @($allGpus | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Mirror|Basic Display|DameWare|Meta Virtual' })
        $gpus = if ($real.Count -gt 0) { $real } else { $allGpus }

        $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) { $r.GpuName = ($names -join "  ·  ") }

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
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4Address -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
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

    return $r
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

                # Local helper: paint one of the star-grid progress bars.
                function Set-SysBar($grid, $pct, $warn) {
                    if (-not $grid) { return }
                    $p = [double][math]::Max(0, [math]::Min(100, $pct))
                    $grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new($p, [System.Windows.GridUnitType]::Star)
                    $grid.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new((100 - $p), [System.Windows.GridUnitType]::Star)
                    $hex = if ($warn) { "#EF4444" } else { "#3DF5A0" }
                    $col = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                    $grid.Children[0].Background = [System.Windows.Media.SolidColorBrush]::new($col)
                }
                function New-SysBrush($hex) {
                    $col = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                    [System.Windows.Media.SolidColorBrush]::new($col)
                }

                # Hero
                $sync.WPFSysOSCaption.Text   = $r.OSCaption
                $sync.WPFSysOSBuild.Text      = $r.OSBuild
                $sync.WPFSysHostname.Text     = $r.Hostname
                $sync.WPFSysUptime.Text       = $r.Uptime
                $sync.WPFSysInstallDate.Text  = $r.InstallDate
                $sync.WPFSysActivation.Text   = $r.ActivationText
                $sync.WPFSysActivation.Foreground = New-SysBrush $r.ActivationColor
                $sync.WPFSysActivationDot.Fill    = New-SysBrush $r.ActivationColor

                # Hardware
                $sync.WPFSysManufacturer.Text = $r.Manufacturer
                $sync.WPFSysModel.Text        = $r.Model
                $sync.WPFSysSerial.Text       = $r.Serial
                $sync.WPFSysBios.Text         = $r.Bios
                $sync.WPFSysSecureBoot.Text   = $r.SecureBoot
                $sync.WPFSysTpm.Text          = $r.Tpm

                # CPU
                $sync.WPFSysCpuName.Text  = $r.CpuName
                $sync.WPFSysCpuCores.Text = $r.CpuCores
                $sync.WPFSysCpuClock.Text = $r.CpuClock
                $sync.WPFSysCpuLoad.Text  = $r.CpuLoad
                Set-SysBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                # RAM
                $sync.WPFSysRamText.Text    = $r.RamText
                $sync.WPFSysRamFree.Text    = $r.RamFree
                $sync.WPFSysRamModules.Text = $r.RamModules
                Set-SysBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)

                # Storage
                $sync.WPFSysDiskHealth.Text       = $r.DiskHealthText
                $sync.WPFSysDiskHealth.Foreground = New-SysBrush $r.DiskHealthColor
                for ($i = 0; $i -lt 4; $i++) {
                    $panel = $sync["WPFSysDisk$i"]
                    if (-not $panel) { continue }
                    if ($i -lt $r.Disks.Count) {
                        $d = $r.Disks[$i]
                        $sync["WPFSysDisk${i}Label"].Text = $d.Label
                        $sync["WPFSysDisk${i}Text"].Text  = $d.Text
                        Set-SysBar $sync["WPFSysDisk${i}Bar"] $d.UsedPct $d.Warn
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

                # Battery
                if ($r.HasBattery) {
                    $sync.WPFSysBatteryCard.Visibility = "Visible"
                    $sync.WPFSysBatteryCharge.Text = $r.BatteryCharge
                    $sync.WPFSysBatteryStatus.Text = $r.BatteryStatus
                    $sync.WPFSysBatteryHealth.Text = $r.BatteryHealth
                    Set-SysBar $sync.WPFSysBatteryBar $r.BatteryPct ($r.BatteryPct -le 15)
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

function Invoke-WPFSystemInfoExport {
    <#
        .SYNOPSIS
            Writes the current system report to a timestamped .txt file on the Desktop.
    #>

    Write-WinUtilSystemLog "Creazione del report di sistema..."
    Invoke-WPFRunspace -ScriptBlock {
        try {
            $r = $sync.SystemReport
            if (-not $r) { $r = Get-WinUtilSystemReport; $sync.SystemReport = $r }

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
            $null = $sb.AppendLine("[ ARCHIVIAZIONE ]$($r.DiskHealthText)")
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

            $fileName = "WinRUtil-Sistema_{0}_{1}.txt" -f $r.Hostname, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $path = Join-Path ([Environment]::GetFolderPath('Desktop')) $fileName
            $sb.ToString() | Out-File -FilePath $path -Encoding UTF8 -Force
            Write-WinUtilSystemLog "Report salvato sul Desktop: $fileName" -Level Success
        } catch {
            Write-WinUtilSystemLog "Impossibile creare il report: $($_.Exception.Message)" -Level Error
        }
    }
}
