function Get-WinUtilRegistryComboValue {
    <#
    .SYNOPSIS
        Reads one registry value of a combo box whose choices are registry states

    .PARAMETER Setting
        The registry entry of the combo box in tweaks.json

    .OUTPUTS
        Exists, and the Value when the value exists
    #>
    param(
        [Parameter(Mandatory)]
        $Setting
    )

    try {
        $item = Get-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction Stop
        $property = $item.PSObject.Properties[$Setting.Name]
        return [pscustomobject]@{ Exists = $null -ne $property; Value = $property.Value }
    } catch [System.Management.Automation.PSArgumentException] {
        # The registry provider throws PSArgumentException when a named value is missing
        return [pscustomobject]@{ Exists = $false; Value = $null }
    } catch [System.Management.Automation.ItemNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}
