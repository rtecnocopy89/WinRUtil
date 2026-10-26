function Invoke-WPFSelectedCheckboxesUpdate{
    <#
        .SYNOPSIS
            This is a helper function that is called by the Checked and Unchecked events of the Checkboxes.
            It also Updates the "Selected Apps" selectedAppLabel on the Install Tab to represent the current collection
        .PARAMETER type
            Either: Add | Remove
        .PARAMETER checkboxName
            should contain the name of the current instance of the checkbox that triggered the Event.
            Most of the time will be the automatic variable $this.Parent.Tag
        .EXAMPLE
            $checkbox.Add_Unchecked({Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag})
            OR
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $specificCheckbox.Parent.Tag
    #>
    param (
        $type,
        $checkboxName
    )

    if (($type -ne "Add") -and ($type -ne "Remove"))
    {
        Write-Error "Type: $type not implemented"
        return
    }

    $appKey = [string]$checkboxName
    $listName = switch -Regex ($appKey) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }
    if (-not $listName) {
        Write-Host "Unknown group for checkbox: $($appKey)"
        return
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if ($sync.$listName -notcontains $appKey) {
            $sync.$listName.Add($appKey)
            $selectionChanged = $true
        }
    } else {
        # Every copy is removed, also one imported with a different case
        for ($index = $sync.$listName.Count - 1; $index -ge 0; $index--) {
            if ($sync.$listName[$index] -eq $appKey) {
                $sync.$listName.RemoveAt($index)
                $selectionChanged = $true
            }
        }
    }

    if ($listName -eq "selectedApps" -and $selectionChanged) {
        $sync.WPFselectedAppsButton.Content = "App selezionate: $($sync.selectedApps.Count)"
        # The menu is rebuilt on every change, to keep it in alphabetical order
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
    }
}
