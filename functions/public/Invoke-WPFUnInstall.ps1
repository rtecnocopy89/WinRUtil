function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Seleziona i programmi da disinstallare."
        [System.Windows.MessageBox]::Show($WarningMsg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "WinRUtil"
    $Messageboxbody = "Vuoi disinstallare i seguenti programmi?`n`n" + (($PackagesToUninstall | ForEach-Object { "- $($_.content)" }) -join "`n")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference -Action Uninstall
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        if ($packagesWinget -contains "Microsoft.Edge") {
            # The Edge uninstaller refuses to run unless this file exists
            New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force | Out-Null
        }

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "Disinstallazione app in corso..."

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
           Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False

    }
}
