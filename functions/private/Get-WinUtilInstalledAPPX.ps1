function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of the AppX packages installed for all users

    #>

    # In PowerShell 7 the AppX module can depend on a temporary compatibility session of
    # Windows PowerShell, so the packages are read in Windows PowerShell 5.1
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to get the installed AppX packages: $(($packageOutput | Out-String).Trim())"
        return @()
    }

    return @($packageOutput)
}
