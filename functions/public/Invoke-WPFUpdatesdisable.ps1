function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    .PARAMETER Confirmed
        Disables the updates without asking, for the automatic runs

    #>
    param([switch]$Confirmed)

    if (-not $Confirmed) {
        $message = "Disattivando Windows Update si fermano i servizi di aggiornamento, si disattivano le attivit$([char]0x00E0) pianificate e si cancellano gli aggiornamenti scaricati. Gli aggiornamenti di sicurezza non verranno installati finch$([char]0x00E9) non ripristini le impostazioni predefinite.`n`nVuoi continuare?"
        $answer = [System.Windows.MessageBox]::Show($message, "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne "Yes") {
            return
        }
    }

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    # New-Item -Force on an existing key deletes the key and its subkeys first: only missing keys
    # are created, so the other policies stored there (WSUS, target version...) are kept
    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
    }

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config")) {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
    }

    Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared SoftwareDistribution folder"

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "---   Updates Are Disabled    ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Disabilita gli aggiornamenti"
}
