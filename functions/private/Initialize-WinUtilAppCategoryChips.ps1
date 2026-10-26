function Initialize-WinUtilAppCategoryChips {
    <#
    .SYNOPSIS
        Creates the category filters above the app list of the Install tab

    .DESCRIPTION
        One chip per category of applications.json, in the order of the list, after the chip that
        shows every category. A click shows only that category (a second click shows them all
        again), Ctrl+click adds or removes the category from the ones shown.

    .PARAMETER Apps
        The Hashtable of Apps, from which the categories are taken
    #>

    param($Apps)

    $chipPanel = $sync.Form.FindName("WPFAppCategoryChips")
    if (-not $chipPanel) {
        return
    }
    $chipPanel.Children.Clear()
    $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()
    $sync.AppCategoryChips = [System.Collections.Generic.List[object]]::new()

    $filterIcon = New-Object Windows.Controls.TextBlock
    $filterIcon.Text = [string][char]0xE71C
    $filterIcon.FontFamily = "Segoe MDL2 Assets"
    $filterIcon.VerticalAlignment = "Center"
    $filterIcon.Margin = New-Object Windows.Thickness(2, 0, 10, 6)
    $filterIcon.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "IconFontSize")
    $filterIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "LabelboxForegroundColor")
    $filterIcon.ToolTip = "Filtra per categoria. Ctrl+clic per mostrarne pi$([char]0x00F9) di una."
    [void]$chipPanel.Children.Add($filterIcon)

    $categories = @($Apps.Values | ForEach-Object { $_.Category } | Sort-Object -Unique | Sort-Object { Get-WinUtilAppCategoryName $_ })
    foreach ($category in @("") + $categories) {
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $sync.Form.Resources.AppCategoryChipStyle
        # The chip carries its category, empty for the one that shows every category
        $chip.Tag = $category
        $chip.Content = if ($category) { Get-WinUtilAppCategoryName $category } else { "Tutte" }
        $chip.IsChecked = -not $category
        [System.Windows.Automation.AutomationProperties]::SetName($chip, "Filtro categoria: $($chip.Content)")
        $chip.Add_Click({
            $additive = [bool]([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)
            Set-WinUtilAppCategoryFilter -Category $this.Tag -Additive:$additive
        })
        [void]$chipPanel.Children.Add($chip)
        $sync.AppCategoryChips.Add($chip)
    }
}
