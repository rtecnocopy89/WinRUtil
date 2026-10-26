function Set-WinUtilAppCategoryFilter {
    <#
    .SYNOPSIS
        Applies the category filter of the Install tab and updates its chips

    .DESCRIPTION
        The categories shown are in $sync.SelectedAppCategories: an empty list shows every category,
        which is what the "Tutte" chip stands for. The search text is applied again on top of the categories.

    .PARAMETER Category
        The category to act on. An empty value shows every category again.

    .PARAMETER Additive
        Adds the category to the ones shown, or removes it, instead of showing only that category (Ctrl+click)
    #>

    param(
        [string]$Category = "",
        [switch]$Additive
    )

    if ($null -eq $sync.SelectedAppCategories) {
        $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()
    }
    $selected = $sync.SelectedAppCategories

    if ([string]::IsNullOrWhiteSpace($Category)) {
        $selected.Clear()
    } elseif ($Additive) {
        if ($selected.Contains($Category)) {
            [void]$selected.Remove($Category)
        } else {
            $selected.Add($Category)
        }
    } elseif ($selected.Count -eq 1 -and $selected.Contains($Category)) {
        # A second click on the only category shown shows them all again
        $selected.Clear()
    } else {
        $selected.Clear()
        $selected.Add($Category)
    }

    Update-WinUtilAppCategoryChip
    Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $selected.ToArray()
}
