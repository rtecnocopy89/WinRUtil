function Update-WinUtilAppCategoryChip {
    <#
    .SYNOPSIS
        Checks the category chips of the Install tab that match the categories shown

    .DESCRIPTION
        A toggle button changes its state on every click; the state has to follow the categories
        shown instead. The "Tutte" chip is checked when no category is selected.
    #>

    $selected = $sync.SelectedAppCategories
    if ($null -eq $selected -or $null -eq $sync.AppCategoryChips) {
        return
    }

    foreach ($chip in $sync.AppCategoryChips) {
        $chip.IsChecked = if ($chip.Tag) { $selected.Contains([string]$chip.Tag) } else { $selected.Count -eq 0 }
    }
}
