function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
        Add-WinUtilSessionAction -Area "Programmi" -Text "Aggiornamento di tutti i programmi (Chocolatey)" -Status "Info"
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
        Add-WinUtilSessionAction -Area "Programmi" -Text "Aggiornamento di tutti i programmi (WinGet)" -Status "Info"
    }
}
