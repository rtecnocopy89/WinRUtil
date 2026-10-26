function Get-WinUtilSelectedPackages
{
     <#
    .SYNOPSIS
        Sorts given packages based on installer preference and availability.

    .OUTPUTS
        Hashtable. Key = Package Manager, Value = ArrayList of packages to install
    #>
    param (
        [Parameter(Mandatory=$true)]
        $PackageList,
        [Parameter(Mandatory=$true)]
        [PackageManagers]$Preference,
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install"
    )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packages = [System.Collections.Hashtable]::new()
    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages[[PackageManagers]::Winget] = $packagesWinget
    $packages[[PackageManagers]::Choco] = $packagesChoco

    Write-Debug "Checking packages using Preference '$($Preference)'"

    function Test-PackageId {
        param($PackageId)
        -not ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na")
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId,
            [string]$Manager
        )

        # A field can hold several IDs separated by ";" (dependencies first, then the app).
        # Uninstalling removes only the app, the last ID.
        $ids = [string]$PackageId -split ";"
        if ($Action -eq "Uninstall") {
            $ids = @($ids[-1])
        }
        foreach ($id in $ids) {
            $id = $id.Trim()
            if ((Test-PackageId $id) -and -not $Target.Contains($id)) {
                $null = $Target.Add($id)
                Write-Host "Queueing $id for $Manager..."
            }
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if (Test-PackageId $package.choco) {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco -Manager "Chocolatey"
                } else {
                    Write-Debug "$($package.content) has no Choco value."
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget -Manager "WinGet"
                }
                break
            }
            "Winget" {
                if (Test-PackageId $package.winget) {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget -Manager "WinGet"
                } else {
                    Write-Debug "$($package.content) has no WinGet value."
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco -Manager "Chocolatey"
                }
                break
            }
        }
    }

    return $packages
}
