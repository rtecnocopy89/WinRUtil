function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes the provisioned AppX packages that match the given names, so that new user profiles do not get them

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."

    # The DISM cmdlets often fail with "Class not registered" or stop responding in PowerShell 7,
    # so they run in Windows PowerShell 5.1
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages | Where-Object DisplayName -Like "*$Package*"
            foreach ($prov in @($provs)) {
                if ($null -eq $prov) {
                    continue
                }
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                } catch {
                    $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        throw "Provisioned AppX package removal failed: $(($removalOutput | Out-String).Trim())"
    }
}
