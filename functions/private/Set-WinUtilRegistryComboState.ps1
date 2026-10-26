function Set-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Writes the registry values of a choice of a combo box, and checks them

    .DESCRIPTION
        When a value cannot be written, the values that were there before are restored.

    .PARAMETER Registry
        The registry entries of the combo box, with the value of each choice in Values

    .PARAMETER State
        The name of the choice to apply
    #>
    param(
        [Parameter(Mandatory)]
        $Registry,

        [Parameter(Mandatory)]
        [string]$State
    )

    if ($Registry[0].Values.PSObject.Properties.Name -notcontains $State) {
        throw "Scelta sconosciuta: '$State'."
    }

    # The values before the change, to restore them if the change fails halfway
    $previousValues = foreach ($setting in @($Registry)) {
        $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
        [pscustomobject]@{ Setting = $setting; Exists = $currentValue.Exists; Value = $currentValue.Value }
    }

    try {
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $previousValue = $previousValues | Where-Object Setting -EQ $setting
            if ($configuredValue -ne "<RemoveEntry>" -or $previousValue.Exists) {
                Set-WinUtilRegistry -Name $setting.Name -Path $setting.Path -Type $setting.Type -Value $configuredValue
            }
        }

        # Set-WinUtilRegistry reports write errors without throwing, so every value is read again
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $writeMatches = if ($configuredValue -eq "<RemoveEntry>") {
                -not $currentValue.Exists
            } else {
                $currentValue.Exists -and [string]$currentValue.Value -eq [string]$configuredValue
            }
            if (-not $writeMatches) {
                throw "I valori del registro non corrispondono alla scelta richiesta."
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($applyError)) {
            $applyError = "I valori del registro non corrispondono alla scelta richiesta."
        }
        $rollbackFailed = $false
        foreach ($previousValue in $previousValues) {
            try {
                $currentValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($previousValue.Exists -or $currentValue.Exists) {
                    $rollbackValue = if ($previousValue.Exists) { $previousValue.Value } else { "<RemoveEntry>" }
                    Set-WinUtilRegistry -Name $previousValue.Setting.Name -Path $previousValue.Setting.Path -Type $previousValue.Setting.Type -Value $rollbackValue
                }
                $restoredValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($restoredValue.Exists -ne $previousValue.Exists -or ($restoredValue.Exists -and [string]$restoredValue.Value -ne [string]$previousValue.Value)) {
                    $rollbackFailed = $true
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        if ($rollbackFailed) {
            throw ("Impossibile applicare '{0}': {1} Non {2} stato possibile ripristinare i valori precedenti del registro." -f $State, $applyError, [char]0x00E8)
        }
        throw "Impossibile applicare '$State': $applyError"
    }
}
