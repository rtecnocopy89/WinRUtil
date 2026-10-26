function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name, for all users

    .PARAMETER Name
        The name of the APPX package to remove

    .OUTPUTS
        True when no package that matches the name is left

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"

    # One package at a time instead of the pipeline: in PowerShell 7 Remove-AppxPackage fails silently
    # through the pipeline, and Get-AppxPackage -AllUsers returns the same package once per user profile
    $removed = $true
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    foreach ($pkg in @($pkgs)) {
        if ($null -eq $pkg) {
            continue
        }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            Write-Warning "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            $removed = $false
        }
    }
    return $removed
}
