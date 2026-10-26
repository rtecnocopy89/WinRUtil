function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Downloads the updates and asks before installing them, so the PC does not restart unexpectedly

    #>

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "Restoring Windows Update availability..."
    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    # A Windows 11 image made by the Win11 Creator of earlier versions blocks Windows Update until its
    # first-logon cleanup runs: clear what is left of that block, but keep a real WSUS server
    Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "DisableWindowsUpdateAccess" -ErrorAction SilentlyContinue
    if ((Get-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUServer" -ErrorAction SilentlyContinue).WUServer -eq "http://localhost:8080") {
        Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUServer" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUStatusServer" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "UseWUServer" -ErrorAction SilentlyContinue
    }

    Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc -ErrorAction SilentlyContinue

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Disabling driver offering through Windows Update..."

    # New-Item -Force on an existing key deletes the key and its subkeys first: only missing keys
    # are created, so the other policies stored there (WSUS, target version...) are kept
    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    if (-not (Test-Path $windowsUpdatePolicyPath)) {
        New-Item -Path $windowsUpdatePolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Deferring feature updates by 365 days and quality updates by 4 days..."
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    # The values that earlier versions wrote in the settings of Windows Update instead of the policies
    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "Configuring automatic updates to download and notify before installation..."
    if (-not (Test-Path $automaticUpdatePolicyPath)) {
        New-Item -Path $automaticUpdatePolicyPath -Force | Out-Null
    }

    # NoAutoRebootWithLoggedOnUsers is not reliable on recent versions of Windows: AUOptions 3 downloads
    # the updates and notifies before installing them, so nothing is installed or restarted unasked
    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 3
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Applica impostazioni di sicurezza"
}
