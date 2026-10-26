function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Filters the apps of the Install tab by search text and by category

        .DESCRIPTION
            An app is shown when its name or description contains the search text and its
            category is one of the categories chosen with the chips. An empty search text matches
            every app, and no category chosen matches every category.

            While a filter is active the categories with results are expanded, otherwise a collapsed
            category would hide them; without filters the categories go back to how the user left them.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as normal characters.

        .PARAMETER Categories
            The categories to show. Without categories every category is shown.
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = "",

        [Parameter(Mandatory=$false)]
        [string[]]$Categories = @()
    )

    if ($null -eq $sync.ItemsControl) {
        return
    }

    # Categories expanded by the filters, so that clearing the filters can collapse them again
    if ($null -eq $sync.AppCategoryAutoExpanded) {
        $sync.AppCategoryAutoExpanded = @{}
    }

    $activeCategories = @($Categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasSearch = -not [string]::IsNullOrWhiteSpace($SearchString)
    $hasCategories = $activeCategories.Count -gt 0

    # Reset the visibility if there are no filters
    if (-not $hasSearch -and -not $hasCategories) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # A category expanded by a filter goes back to how the user left it
                $categoryName = $categoryLabel.Content -replace '^[+-] ', ''
                if ($sync.AppCategoryAutoExpanded.ContainsKey($categoryName)) {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^- ", "+ "
                    $sync.AppCategoryAutoExpanded.Remove($categoryName)
                }

                # Respect the collapsed state of categories (indicated by + prefix)
                if ($categoryLabel.Content -like "+*") {
                    $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                } else {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                }

                # Show all apps within the category
                $wrapPanel.Children | ForEach-Object {
                    $_.Visibility = [Windows.Visibility]::Visible
                }
            }
        }
        return
    }

    $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            foreach ($appControl in $wrapPanel.Children) {
                $appEntry = $sync.configs.applicationsHashtable[[string]$appControl.Tag]
                $categoryMatch = -not $hasCategories -or $activeCategories -contains $appEntry.Category
                $textMatch = -not $hasSearch -or
                    $appEntry.Content -like "*$escapedSearchString*" -or
                    $appEntry.Description -like "*$escapedSearchString*"

                if ($appEntry -and $categoryMatch -and $textMatch) {
                    $appControl.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                } else {
                    $appControl.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Expand the category to show its matches, and remember that it was collapsed
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    $sync.AppCategoryAutoExpanded[($categoryLabel.Content -replace '^- ', '')] = $true
                }
            } else {
                # Hide the entire category container if no matches
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    }
}
