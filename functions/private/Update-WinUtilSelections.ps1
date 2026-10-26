function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.

    .PARAMETER Replace
        Replaces the current selections instead of adding to them

    .OUTPUTS
        The keys that are not known to this version of WinRUtil, which are skipped
    #>

    param (
        $flatJson,

        [switch]$Replace
    )

    Write-Debug "JSON to import: $($flatJson)"

    $nextSelections = @{
        selectedApps     = [System.Collections.Generic.List[string]]::new()
        selectedTweaks   = [System.Collections.Generic.List[string]]::new()
        selectedToggles  = [System.Collections.Generic.List[string]]::new()
        selectedFeatures = [System.Collections.Generic.List[string]]::new()
        selectedAppx     = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($item in $flatJson) {
        # Ensure each item is treated as a string to handle PSCustomObject from JSON deserialization
        $cbkey = [string]$item
        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        # Exports of earlier versions can name entries that no longer exist
        $isKnown = switch ($listName) {
            'selectedApps' { $sync.configs.applicationsHashtable.ContainsKey($cbkey) }
            'selectedTweaks' { $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey] }
            'selectedToggles' { $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey] }
            'selectedFeatures' { $null -ne $sync.configs.feature.PSObject.Properties[$cbkey] }
            'selectedAppx' { $null -ne $sync.configs.appxHashtable -and $sync.configs.appxHashtable.ContainsKey($cbkey) }
            default { $false }
        }
        if (-not $isKnown) {
            Write-Host "Skipping unknown selection: $cbkey"
            $cbkey
            continue
        }

        if ($nextSelections[$listName] -notcontains $cbkey) {
            $nextSelections[$listName].Add($cbkey)
        }
    }

    foreach ($listName in $nextSelections.Keys) {
        if ($Replace) {
            $sync[$listName] = $nextSelections[$listName]
            continue
        }
        foreach ($cbkey in $nextSelections[$listName]) {
            # A preset and a configuration that both name an entry must not select it twice
            if ($sync.$listName -notcontains $cbkey) {
                $sync.$listName.Add($cbkey)
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "Selected AppX: $($sync.selectedAppx)"
    Write-Debug "--------------------------------------"
}
