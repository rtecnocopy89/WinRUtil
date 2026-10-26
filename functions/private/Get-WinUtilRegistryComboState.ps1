function Get-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Finds the choice of a combo box that matches the current registry values

    .PARAMETER Registry
        The registry entries of the combo box, with the value of each choice in Values

    .OUTPUTS
        The name of the matching choice. Throws an error when the values match no choice.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry
    )

    foreach ($state in $Registry[0].Values.PSObject.Properties) {
        $stateMatches = $true
        foreach ($setting in @($Registry)) {
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $actualValue = if ($currentValue.Exists -and $null -ne $currentValue.Value) { $currentValue.Value } else { $setting.DefaultValue }
            $configuredValue = $setting.Values.PSObject.Properties[$state.Name].Value
            # A removed value means the default of Windows
            $expectedValue = if ($configuredValue -eq "<RemoveEntry>") { $setting.DefaultValue } else { $configuredValue }
            if ([string]$actualValue -ne [string]$expectedValue) {
                $stateMatches = $false
                break
            }
        }
        if ($stateMatches) {
            return $state.Name
        }
    }

    throw "I valori del registro non corrispondono a nessuna delle scelte disponibili."
}
