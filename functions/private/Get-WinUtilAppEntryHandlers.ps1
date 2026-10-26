function Get-WinUtilAppEntryHandlers {
    <#
        .SYNOPSIS
            The event handlers shared by every app entry on the Install tab

        .DESCRIPTION
            A script block written inside a loop is a new script block every time round, and building
            them for every app is the largest cost of drawing the app list. None of them depend on the
            entry: they read the control that raised the event through $this, so one set serves every app.
    #>

    if ($null -ne $script:WinUtilAppEntryHandlers) {
        return $script:WinUtilAppEntryHandlers
    }

    $script:WinUtilAppEntryHandlers = @{
        BorderClick = {
            $childCheckbox = $sync.$($this.Tag)
            $childCheckbox.IsChecked = -not $childCheckbox.IsChecked
        }
        MouseEnter = {
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        }
        MouseLeave = {
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        }
        RightClick = {
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        }
        Checked = {
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $this.Parent.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        }
        Unchecked = {
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $this.Parent.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        }
        # Without a connection, or when the site has no icon, the initial of the app stays visible
        ImageFailed = {
            $this.Visibility = "Collapsed"
            $this.Parent.Children[0].Visibility = "Visible"
        }
    }

    return $script:WinUtilAppEntryHandlers
}
