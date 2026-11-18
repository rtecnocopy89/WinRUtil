function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    .DESCRIPTION
        Removes the values written by the other update profiles and enables the update services and
        tasks again. Other Windows Update policies, such as a WSUS server, are kept.

    #>

    Write-Host "Removing the Windows Update settings managed by WinRUtil..." -ForegroundColor Green

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    # Earlier versions hid the Windows Update page of the Settings app when disabling the updates
    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    # Other tweak tools can deny SYSTEM write access to these keys. Set-Service goes through the Service
    # Control Manager, which runs as SYSTEM, so clear those rules before restoring startup types.
    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc", "WaaSMedicSvc")) {
        $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName"
        try {
            $serviceKeyAcl = Get-Acl -Path $serviceKeyPath -ErrorAction Stop
            # Match the SID because the SYSTEM account name is localized.
            $systemDenyRules = @($serviceKeyAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                $_.AccessControlType -eq "Deny" -and $_.IdentityReference.Value -eq "S-1-5-18"
            })

            if ($systemDenyRules.Count -gt 0) {
                foreach ($denyRule in $systemDenyRules) {
                    $serviceKeyAcl.RemoveAccessRule($denyRule) | Out-Null
                }
                Set-Acl -Path $serviceKeyPath -AclObject $serviceKeyAcl -ErrorAction Stop
                Write-Host "Removed SYSTEM deny rules from $serviceName"
            }
        } catch {
            Write-Host "Could not check SYSTEM deny rules on $serviceName" -ForegroundColor Yellow
        }
    }

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue

    Write-Host "Restored UsoSvc to Automatic"
    Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc -ErrorAction SilentlyContinue

    # WaaSMedicSvc is launch protected, so Set-Service is denied even for administrators.
    $waaSMedicKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
    if ((Get-ItemProperty -Path $waaSMedicKeyPath -Name "Start" -ErrorAction SilentlyContinue).Start -ne 3) {
        try {
            Set-ItemProperty -Path $waaSMedicKeyPath -Name "Start" -Type DWord -Value 3 -ErrorAction Stop
            Write-Host "Restored WaaSMedicSvc to Manual"
        } catch {
            Write-Host "Could not restore WaaSMedicSvc to Manual" -ForegroundColor Yellow
        }
    }

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

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

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Ripristina impostazioni predefinite"
}
