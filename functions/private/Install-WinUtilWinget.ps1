function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed

    .PARAMETER Force
        Reinstalls WinGet even when it is already available
    #>
    param(
        [switch]$Force
    )

    if (-not $Force -and (Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    if ($Force) {
        Write-Host "Reinstalling WinGet..." -ForegroundColor Yellow
    } else {
        Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red
    }

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers -Force:$Force
}
