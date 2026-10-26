Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry
    if (-not $ToggleSwitchReg) {
        return $false
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
    }

    # Reading the state must not change the registry: a missing key or value takes the DefaultState of the entry
    foreach ($regentry in $ToggleSwitchReg) {
        $regstate = $null
        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path -ErrorAction SilentlyContinue).$($regentry.Name)
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
            return $false
        }
    }

    return $true
}
