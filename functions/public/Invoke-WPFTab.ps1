function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header

    # Reflect the active section in the title bar (Italian display names)
    if ($sync.WPFCurrentTabTitle) {
        $titleMap = @{
            "Install"  = "Installa"
            "Tweaks"   = "Ottimizza"
            "Config"   = "Configura"
            "Updates"  = "Aggiornamenti"
            "Printers" = "Stampanti"
            "System"   = "Sistema"
            "WiFi"     = "Password Wi-Fi"
            "Report"   = "Rapporto di intervento"
            "AppX"     = "App di Windows"
        }
        $display = $titleMap[[string]$sync.currentTab]
        if (-not $display) { $display = $sync.currentTab }
        $sync.WPFCurrentTabTitle.Text = $display
    }

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset the search of the Install tab, keeping the categories chosen with the chips
        Find-AppsByNameOrDescription -SearchString "" -Categories @($sync.SelectedAppCategories)
    } elseif ($sync.currentTab -eq "Tweaks" -or $sync.currentTab -eq "AppX") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "System") {
        # Auto-populate the System dashboard when it is opened
        Invoke-WPFSystemInfoRefresh
    } elseif ($sync.currentTab -eq "Report") {
        # Show the operations recorded so far in this session
        Update-WinUtilReportView
    }

    # Live CPU / memory values only while the System dashboard is visible
    if ($sync.currentTab -eq "System") {
        Start-WinUtilSystemLiveUpdate
    } else {
        Stop-WinUtilSystemLiveUpdate
    }

    # Show search bar in Install, Tweaks and Windows apps tabs
    if ($sync.currentTab -in @("Install", "Tweaks", "AppX")) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}
