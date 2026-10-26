function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers an AppX package again from the copy left on the PC, or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The Microsoft Store product ID, used when no copy of the package is left on the PC

    .OUTPUTS
        True when the package was installed

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-Host "Installing $Name"

    # The AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Both the installed and
    # the provisioned packages can point to a manifest that can be registered again.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-Host "Registered $Name from $manifestPath"
            return $true
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Local registration of $Name failed: $(($manifestOutput | Out-String).Trim())"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        Write-Warning "$Name cannot be installed: no copy is left on the PC and it has no Microsoft Store ID."
        return $false
    }

    Write-Host "No copy of $Name is left on the PC: installing it from the Microsoft Store ($StoreId)"
    Install-WinUtilWinget
    $exitCode = Invoke-WinUtilProcess -FilePath "winget" -ArgumentList "install --id $StoreId --source msstore --silent --accept-source-agreements --accept-package-agreements" -NoNewWindow
    # Installed, already installed, or installed with a restart needed to finish
    return $exitCode -in @(0, -1978335135, 3010, 1641, -1978334967, -1978334965)
}
