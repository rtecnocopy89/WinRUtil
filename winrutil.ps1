<#
.NOTES
    WinRUtil — Windows toolkit
    Maintainer     : @rtecnocopy89
    GitHub         : https://github.com/rtecnocopy89/WinRUtil
    Copyright       : (c) 2026 rtecnocopy89 — (c) 2022 CT Tech Group LLC
    Based on       : ChrisTitusTech/winutil (MIT)
    Version        : 26.06.14
#>

param (
    [string]$Config,
    [switch]$Run,
    [switch]$Noui,
    [switch]$Offline
)

if ($Config) {
    $PARAM_CONFIG = $Config
}

$PARAM_RUN = $false
# Handle the -Run switch
if ($Run) {
    $PARAM_RUN = $true
}

$PARAM_NOUI = $false
if ($Noui) {
    $PARAM_NOUI = $true
}

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinRUtil is unable to run on your system, powershell execution is restricted by security policies" -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinRUtil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Load DLLs
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $PSScriptRoot
$sync.version = "26.06.14"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"
$sync.selectedAppsStackPanel
$sync.selectedAppsPopup

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Set the path for the winutil directory
$winutildir = "$env:LocalAppData\winutil"
New-Item $winutildir -ItemType Directory -Force | Out-Null

$logdir = "$winutildir\logs"
New-Item $logdir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$logdir\winutil_$dateTime.log" -Append -NoClobber | Out-Null

# Set PowerShell window title
$Host.UI.RawUI.WindowTitle = "WinUtil (Admin)"
clear-host
    function Add-SelectedAppsMenuItem {
        <#
        .SYNOPSIS
            This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

        .Parameter name
            The actual Name of an App like "Chrome" or "Brave"
            This name is contained in the "Content" property inside the applications.json
        .PARAMETER key
            The key which identifies an app object in applications.json
            For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
        #>

        param ([string]$name, [string]$key)

        $selectedAppGrid = New-Object Windows.Controls.Grid

        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

        # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
        # With the tooltip, you can still read the whole entry on hover
        $selectedAppLabel = New-Object Windows.Controls.Label
        $selectedAppLabel.Content = $name
        $selectedAppLabel.ToolTip = $name
        $selectedAppLabel.HorizontalAlignment = "Left"
        $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
        $selectedAppGrid.Children.Add($selectedAppLabel)

        $selectedAppRemoveButton = New-Object Windows.Controls.Button
        $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
        $selectedAppRemoveButton.Content = [string]([char]0xE711)
        $selectedAppRemoveButton.HorizontalAlignment = "Center"
        $selectedAppRemoveButton.Tag = $key
        $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

        # Highlight the Remove icon on Hover
        $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
        $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
        $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
        })
        [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
        $selectedAppGrid.Children.Add($selectedAppRemoveButton)
        # Add new Element to Popup
        $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
    }
function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )
    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

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

    # Perform search
    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            # Search through apps in this category
            $wrapPanel.Children | ForEach-Object {
                $appEntry = $sync.configs.applicationsHashtable.$($_.Tag)
                if ($appEntry.Content -like "*$SearchString*" -or $appEntry.Description -like "*$SearchString*") {
                    # Show the App and mark that this category has a match
                    $_.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            # If category has matches, show the WrapPanel and update the category label to expanded state
            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Update category label to show expanded state (-)
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                }
            } else {
                # Hide the entire category container if no matches
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    }
}
function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )

    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        # Show all categories
        $tweakspanel = $sync.Form.FindName("tweakspanel")
        $tweakspanel.Children | ForEach-Object {
            $_.Visibility = [Windows.Visibility]::Visible

            # Foreach category section, show all items
            if ($_ -is [Windows.Controls.Border]) {
                $_.Visibility = [Windows.Visibility]::Visible

                # Find ItemsControl
                $dockPanel = $_.Child
                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                    if ($itemsControl) {
                        # Show items in the category
                        foreach ($item in $itemsControl.Items) {
                            if ($item -is [Windows.Controls.Label]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            } elseif ($item -is [Windows.Controls.DockPanel] -or
                                      $item -is [Windows.Controls.StackPanel]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            }
                        }
                    }
                }
            }
        }
        return
    }

    # Search for matching tweaks when search string is not null
    $tweakspanel = $sync.Form.FindName("tweakspanel")

    $tweakspanel.Children | ForEach-Object {
        $categoryBorder = $_
        $categoryVisible = $false

        if ($_ -is [Windows.Controls.Border]) {
            # Find the ItemsControl
            $dockPanel = $_.Child
            if ($dockPanel -is [Windows.Controls.DockPanel]) {
                $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                if ($itemsControl) {
                    $categoryLabel = $null

                    # Process all items in the ItemsControl
                    for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                        $item = $itemsControl.Items[$i]

                        if ($item -is [Windows.Controls.Label]) {
                            $categoryLabel = $item
                            $item.Visibility = [Windows.Visibility]::Collapsed
                        } elseif ($item -is [Windows.Controls.DockPanel]) {
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                            $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                            if ($label -and ($label.Content -like "*$SearchString*" -or $label.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        } elseif ($item -is [Windows.Controls.StackPanel]) {
                            # StackPanel which contain checkboxes or other elements
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                            if ($checkbox -and ($checkbox.Content -like "*$SearchString*" -or $checkbox.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        }
                    }
                }
            }

            # Set the visibility based on if any item matched
            $categoryBorder.Visibility = if ($categoryVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

        }
    }
}
function Get-LocalizedYesNo {
    <#
    .SYNOPSIS
    This function runs choice.exe and captures its output to extract yes no in a localized Windows

    .DESCRIPTION
    The function retrieves the output of the command 'cmd /c "choice <nul 2>nul"' and converts the default output for Yes and No
    in the localized format, such as "Yes=<first character>, No=<second character>".

    .EXAMPLE
    $yesNoArray = Get-LocalizedYesNo
    Write-Host "Yes=$($yesNoArray[0]), No=$($yesNoArray[1])"
    #>

    # Run choice and capture its options as output
    # The output shows the options for Yes and No as "[Y,N]?" in the (partially) localized format.
    # eg. English: [Y,N]?
    # Dutch: [Y,N]?
    # German: [J,N]?
    # French: [O,N]?
    # Spanish: [S,N]?
    # Italian: [S,N]?
    # Russian: [Y,N]?

    $line = cmd /c "choice <nul 2>nul"
    $charactersArray = @()
    $regexPattern = '([a-zA-Z])'
    $charactersArray = [regex]::Matches($line, $regexPattern) | ForEach-Object { $_.Groups[1].Value }

    Write-Debug "According to takeown.exe local Yes is $charactersArray[0]"
    # Return the array of characters
    return $charactersArray

  }
function Get-WinUtilSelectedPackages
{
     <#
    .SYNOPSIS
        Sorts given packages based on installer preference and availability.

    .OUTPUTS
        Hashtable. Key = Package Manager, Value = ArrayList of packages to install
    #>
    param (
        [Parameter(Mandatory=$true)]
        $PackageList,
        [Parameter(Mandatory=$true)]
        [PackageManagers]$Preference
    )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packages = [System.Collections.Hashtable]::new()
    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages[[PackageManagers]::Winget] = $packagesWinget
    $packages[[PackageManagers]::Choco] = $packagesChoco

    Write-Debug "Checking packages using Preference '$($Preference)'"

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ($package.choco -eq "na") {
                    Write-Debug "$($package.content) has no Choco value."
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                }
                break
            }
            "Winget" {
                if ($package.winget -eq "na") {
                    Write-Debug "$($package.content) has no WinGet value."
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
                }
                break
            }
        }
    }

    return $packages
}
Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    try {
        if (($ToggleSwitchReg.path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
            if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                Write-Debug "HKU drive created successfully."
            } else {
                Write-Debug "Failed to create HKU drive."
            }
        }
    } catch {
        Write-Error "An error occurred regarding the HKU Drive: $_"
        return $false
    }

    if ($ToggleSwitchReg) {
        $count = 0

        foreach ($regentry in $ToggleSwitchReg) {
            try {
                if (!(Test-Path $regentry.Path)) {
                    New-Item -Path $regentry.Path -Force | Out-Null
                }
                $regstate = (Get-ItemProperty -path $regentry.Path).$($regentry.Name)
                if ($regstate -eq $regentry.Value) {
                    $count += 1
                    Write-Debug "$($regentry.Name) is true (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                } else {
                    Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                }
                if ($null -eq $regstate) {
                    switch ($regentry.DefaultState) {
                        "true" {
                            $regstate = $regentry.Value
                            $count += 1
                        }
                        "false" {
                            $regstate = $regentry.OriginalValue
                        }
                        default {
                            Write-Error "Entry for $($regentry.Name) does not exist and no DefaultState is defined."
                            $regstate = $regentry.OriginalValue
                        }
                    }
                }
            } catch {
                Write-Error "An unexpected error occurred: $_"
            }
        }

        if ($count -eq $ToggleSwitchReg.Count) {
            Write-Debug "$($ToggleSwitchReg.Name) is true (count: $count)"
            return $true
        } else {
            Write-Debug "$($ToggleSwitchReg.Name) is false (count: $count)"
            return $false
        }
    } else {
        return $false
    }
}
function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            } catch {
                <#I am here so errors don't get outputted for a couple variables that don't have the .GetType() attribute#>
            }
        }
        return $output
    }
    return $keys
}
function Get-WPFObjectName {
    <#
        .SYNOPSIS
            This is a helper function that generates an objectname with the prefix WPF that can be used as a Powershell Variable after compilation.
            To achieve this, all characters that are not a-z, A-Z or 0-9 are simply removed from the name.

        .PARAMETER type
            The type of object for which the name should be generated. (e.g. Label, Button, CheckBox...)

        .PARAMETER name
            The name or description to be used for the object. (invalid characters are removed)

        .OUTPUTS
            A string that can be used as a object/variable name in powershell.
            For example: WPFLabelMicrosoftTools

        .EXAMPLE
            Get-WPFObjectName -type Label -name "Microsoft Tools"
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$type,

        [Parameter(position=1)]
        [string]$name
    )

    $Output = $("WPF"+$type+$name) -replace '[^a-zA-Z0-9]', ''
    return $Output
}
function Hide-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Hides the busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall has finished.
    #>
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Collapsed
        $sync.InstallAppAreaBorder.IsEnabled = $true
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 0
    }
}
    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

                Also creates an overlay with a progress bar and text to indicate that an install or uninstall is in progress

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        $sync.InstallAppAreaBorder = $Border

        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $sync.InstallAppAreaScrollViewer = $scrollViewer
        $Border.Child = $scrollViewer

        # Initialize the Blur Effect for the ScrollViewer, which will be used to indicate that an install/uninstall is in progress
        $blurEffect = New-Object Windows.Media.Effects.BlurEffect
        $blurEffect.Radius = 0
        $scrollViewer.Effect = $blurEffect

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        $overlay = New-Object Windows.Controls.Border
        $overlay.CornerRadius = New-Object Windows.CornerRadius(10)
        $overlay.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallOverlayBackgroundColor")
        $overlay.Visibility = [Windows.Visibility]::Collapsed

        # Also add the overlay to the target Grid on top of the App Area
        $targetGrid.Children.Add($overlay) | Out-Null
        $sync.InstallAppAreaOverlay = $overlay

        $overlayText = New-Object Windows.Controls.TextBlock
        $overlayText.Text = "Installing apps..."
        $overlayText.HorizontalAlignment = 'Center'
        $overlayText.VerticalAlignment = 'Center'
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        $overlayText.Background = "Transparent"
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "HeaderFontSize")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, "MainFontFamily")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontWeightProperty, "MainFontWeight")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::MarginProperty, "MainMargin")
        $sync.InstallAppAreaOverlayText = $overlayText

        $progressbar = New-Object Windows.Controls.ProgressBar
        $progressbar.Name = "ProgressBar"
        $progressbar.Width = 250
        $progressbar.Height = 50
        $sync.ProgressBar = $progressbar

        # Add a TextBlock overlay for the progress bar text
        $progressBarTextBlock = New-Object Windows.Controls.TextBlock
        $progressBarTextBlock.Name = "progressBarTextBlock"
        $progressBarTextBlock.FontWeight = [Windows.FontWeights]::Bold
        $progressBarTextBlock.FontSize = 16
        $progressBarTextBlock.Width = $progressbar.Width
        $progressBarTextBlock.Height = $progressbar.Height
        $progressBarTextBlock.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarTextColor")
        $progressBarTextBlock.TextTrimming = "CharacterEllipsis"
        $progressBarTextBlock.Background = "Transparent"
        $sync.progressBarTextBlock = $progressBarTextBlock

        # Create a Grid to overlay the text on the progress bar
        $progressGrid = New-Object Windows.Controls.Grid
        $progressGrid.Width = $progressbar.Width
        $progressGrid.Height = $progressbar.Height
        $progressGrid.Margin = "0,10,0,10"
        $progressGrid.Children.Add($progressbar) | Out-Null
        $progressGrid.Children.Add($progressBarTextBlock) | Out-Null

        $overlayStackPanel = New-Object Windows.Controls.StackPanel
        $overlayStackPanel.Orientation = "Vertical"
        $overlayStackPanel.HorizontalAlignment = 'Center'
        $overlayStackPanel.VerticalAlignment = 'Center'
        $overlayStackPanel.Children.Add($overlayText) | Out-Null
        $overlayStackPanel.Children.Add($progressGrid) | Out-Null

        $overlay.Child = $overlayStackPanel

        return $itemsControl
    }
function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $Apps.$appKey.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $Apps.$appKey.content

        # Change color to Green if FOSS
        if ($Apps.$appKey.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the name to the Checkbox
        $checkBox.Content = $appName

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)

        $border.Child = $checkBox
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($sender, $e)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $sender.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $sender.Content = $sender.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $sender.Content = $sender.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            # Add apps to the wrap panel
            $appsByCategory[$category] | Sort-Object | ForEach-Object {
                $sync.$_ = $(Initialize-InstallAppEntry -TargetElement $wrapPanel -AppKey $_)
            }
        }
    }
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>
    if ((Test-WinUtilPackageManager -choco) -eq "installed") {
        return
    }

    Write-Host "Chocolatey is not installed. Installing now..."
    Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
}
function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
    Manages the installation or uninstallation of a list of Chocolatey packages.

    .PARAMETER Programs
    A string array containing the programs to be installed or uninstalled.

    .PARAMETER Action
    Specifies the action to perform: "Install" or "Uninstall". The default value is "Install".

    .DESCRIPTION
    This function processes a list of programs to be managed using Chocolatey. Depending on the specified action, it either installs or uninstalls each program in the list, updating the taskbar progress accordingly. After all operations are completed, temporary output files are cleaned up.

    .EXAMPLE
    Install-WinUtilProgramChoco -Programs @("7zip","chrome") -Action "Uninstall"
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Programs,

        [Parameter(Position = 1)]
        [String]$Action = "Install"
    )

    function Initialize-OutputFile {
        <#
        .SYNOPSIS
        Initializes an output file by removing any existing file and creating a new, empty file at the specified path.

        .PARAMETER filePath
        The full path to the file to be initialized.

        .DESCRIPTION
        This function ensures that the specified file is reset by removing any existing file at the provided path and then creating a new, empty file. It is useful when preparing a log or output file for subsequent operations.

        .EXAMPLE
        Initialize-OutputFile -filePath "C:\temp\output.txt"
        #>

        param ($filePath)
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $filePath | Out-Null
    }

    function Invoke-ChocoCommand {
        <#
        .SYNOPSIS
        Executes a Chocolatey command with the specified arguments and returns the exit code.

        .PARAMETER arguments
        The arguments to be passed to the Chocolatey command.

        .DESCRIPTION
        This function runs a specified Chocolatey command by passing the provided arguments to the `choco` executable. It waits for the process to complete and then returns the exit code, allowing the caller to determine success or failure based on the exit code.

        .RETURNS
        [int]
        The exit code of the Chocolatey command.

        .EXAMPLE
        $exitCode = Invoke-ChocoCommand -arguments "install 7zip -y"
        #>

        param ($arguments)
        return (Start-Process -FilePath "choco" -ArgumentList $arguments -Wait -PassThru).ExitCode
    }

    function Test-UpgradeNeeded {
        <#
        .SYNOPSIS
        Checks if an upgrade is needed for a Chocolatey package based on the content of a log file.

        .PARAMETER filePath
        The path to the log file that contains the output of a Chocolatey install command.

        .DESCRIPTION
        This function reads the specified log file and checks for keywords that indicate whether an upgrade is needed. It returns a boolean value indicating whether the terms "reinstall" or "already installed" are present, which suggests that the package might need an upgrade.

        .RETURNS
        [bool]
        True if the log file indicates that an upgrade is needed; otherwise, false.

        .EXAMPLE
        $isUpgradeNeeded = Test-UpgradeNeeded -filePath "C:\temp\install-output.txt"
        #>

        param ($filePath)
        return Get-Content -Path $filePath | Select-String -Pattern "reinstall|already installed" -Quiet
    }

    function Update-TaskbarProgress {
        <#
        .SYNOPSIS
        Updates the taskbar progress based on the current installation progress.

        .PARAMETER currentIndex
        The current index of the program being installed or uninstalled.

        .PARAMETER totalPrograms
        The total number of programs to be installed or uninstalled.

        .DESCRIPTION
        This function calculates the progress of the installation or uninstallation process and updates the taskbar accordingly. The taskbar is set to "Normal" if all programs have been processed, otherwise, it is set to "Error" as a placeholder.

        .EXAMPLE
        Update-TaskbarProgress -currentIndex 3 -totalPrograms 10
        #>

        param (
            [int]$currentIndex,
            [int]$totalPrograms
        )
        $progressState = if ($currentIndex -eq $totalPrograms) { "Normal" } else { "Error" }
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state $progressState -value ($currentIndex / $totalPrograms) }
    }

    function Install-ChocoPackage {
        <#
        .SYNOPSIS
        Installs a Chocolatey package and optionally upgrades it if needed.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be installed.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be installed.

        .DESCRIPTION
        This function installs a Chocolatey package by running the `choco install` command. If the installation output indicates that an upgrade might be needed, the function will attempt to upgrade the package. The taskbar progress is updated after each package is processed.

        .EXAMPLE
        Install-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $installOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt"
        Initialize-OutputFile $installOutputFile

        Write-Host "Starting installation of $Program with Chocolatey."

        try {
            $installStatusCode = Invoke-ChocoCommand "install $Program -y --log-file $installOutputFile"
            if ($installStatusCode -eq 0) {

                if (Test-UpgradeNeeded $installOutputFile) {
                    $upgradeStatusCode = Invoke-ChocoCommand "upgrade $Program -y"
                    Write-Host "$Program was" $(if ($upgradeStatusCode -eq 0) { "upgraded successfully." } else { "not upgraded." })
                }
                else {
                    Write-Host "$Program installed successfully."
                }
            }
            else {
                Write-Host "Failed to install $Program."
            }
        }
        catch {
            Write-Host "Failed to install $Program due to an error: $_"
        }
        finally {
            Update-TaskbarProgress $currentIndex $totalPrograms
        }
    }

    function Uninstall-ChocoPackage {
        <#
        .SYNOPSIS
        Uninstalls a Chocolatey package and any related metapackages.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be uninstalled.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be uninstalled.

        .DESCRIPTION
        This function uninstalls a Chocolatey package and any related metapackages (e.g., .install or .portable variants). It updates the taskbar progress after processing each package.

        .EXAMPLE
        Uninstall-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $uninstallOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt"
        Initialize-OutputFile $uninstallOutputFile

        Write-Host "Searching for metapackages of $Program (.install or .portable)"
        $chocoPackages = ((choco list | Select-String -Pattern "$Program(\.install|\.portable)?").Matches.Value) -join " "
        if ($chocoPackages) {
            Write-Host "Starting uninstallation of $chocoPackages with Chocolatey..."
            try {
                $uninstallStatusCode = Invoke-ChocoCommand "uninstall $chocoPackages -y"
                Write-Host "$Program" $(if ($uninstallStatusCode -eq 0) { "uninstalled successfully." } else { "failed to uninstall." })
            }
            catch {
                Write-Host "Failed to uninstall $Program due to an error: $_"
            }
            finally {
                Update-TaskbarProgress $currentIndex $totalPrograms
            }
        }
        else {
            Write-Host "$Program is not installed."
        }
    }

    $totalPrograms = $Programs.Count
    if ($totalPrograms -le 0) {
        throw "Parameter 'Programs' must have at least one item."
    }

    Write-Host "==========================================="
    Write-Host "--   Configuring Chocolatey packages   ---"
    Write-Host "==========================================="

    for ($currentIndex = 0; $currentIndex -lt $totalPrograms; $currentIndex++) {
        $Program = $Programs[$currentIndex]
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($currentIndex / $totalPrograms * 100)
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($currentIndex / $totalPrograms)}

        switch ($Action) {
            "Install" {
                Install-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            "Uninstall" {
                Uninstall-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            default {
                throw "Invalid action parameter value: '$Action'."
            }
        }
    }
    Set-WinUtilProgressBar -label "$($Action)ation done" -percent 100
    # Cleanup Output Files
    $outputFiles = @("$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt", "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt")
    foreach ($filePath in $outputFiles) {
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
    Runs the designated action on the provided programs using Winget

    .PARAMETER Programs
    A list of programs to process

    .PARAMETER action
    The action to perform on the programs, can be either 'Install' or 'Uninstall'

    .NOTES
    The triple quotes are required any time you need a " in a normal script block.
    The winget Return codes are documented here: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-actionr/winget/returnCodes.md
    #>

    param(
        [Parameter(Mandatory, Position=0)]$Programs,

        [Parameter(Mandatory, Position=1)]
        [ValidateSet("Install", "Uninstall")]
        [String]$Action
    )

    Function Invoke-Winget {
    <#
    .SYNOPSIS
    Invokes the winget.exe with the provided arguments and return the exit code

    .PARAMETER wingetId
    The Id of the Program that WinGet should Install/Uninstall

    .NOTES
    Invoke WinGet uses the public variable $Action defined outside the function to determine if a Program should be installed or removed
    #>
        param (
            [string]$wingetId
        )

        $commonArguments = "--id $wingetId --silent"
        $arguments = if ($Action -eq "Install") {
            "install $commonArguments --accept-source-agreements --accept-package-agreements --source winget"
        } else {
            "uninstall $commonArguments --source winget"
        }

        $processParams = @{
            FilePath = "winget"
            ArgumentList = $arguments
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }

        return (Start-Process @processParams).ExitCode
    }

    Function Invoke-Install {
    <#
    .SYNOPSIS
    Contains the Install Logic and return code handling from winget

    .PARAMETER Program
    The WinGet ID of the Program that should be installed
    #>
        param (
            [string]$Program
        )
        $status = Invoke-Winget -wingetId $Program
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully."
            return $true
        } elseif ($status -eq -1978335189) {
            Write-Host "No applicable update found for $($Program)."
            return $true
        }

        Write-Host "Failed to install $($Program)."
        return $false
    }

    Function Invoke-Uninstall {
        <#
        .SYNOPSIS
        Contains the Uninstall Logic and return code handling from WinGet

        .PARAMETER Program
        The WinGet ID of the Program that should be uninstalled
        #>
        param (
            [string]$Program
        )

        try {
            $status = Invoke-Winget -wingetId $Program
            if ($status -eq 0) {
                Write-Host "$($Program) uninstalled successfully."
                return $true
            } else {
                Write-Host "Failed to uninstall $($Program)."
                return $false
            }
        } catch {
            Write-Host "Failed to uninstall $($Program) due to an error: $_"
            return $false
        }
    }

    $count = $Programs.Count
    $failedPackages = @()

    Write-Host "==========================================="
    Write-Host "--    Configuring WinGet packages       ---"
    Write-Host "==========================================="

    for ($i = 0; $i -lt $count; $i++) {
        $Program = $Programs[$i]
        $result = $false
        Set-WinUtilProgressBar -label "$Action $($Program)" -percent ($i / $count * 100)
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -value ($i / $count)}

        $result = switch ($Action) {
            "Install" {Invoke-Install -Program $Program}
            "Uninstall" {Invoke-Uninstall -Program $Program}
            default {throw "[Install-WinUtilProgramWinget] Invalid action: $Action"}
        }

        if (-not $result) {
            $failedPackages += $Program
        }
    }

    Set-WinUtilProgressBar -label "$($Action) action done." -percent 100
    return $failedPackages
}
function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}
function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          # WinRUtil mark: a hexagonal nut (utility/tools symbol) in the brand neon-mint.
          # Outer hexagon ring (flat-top) with a hexagonal hole, drawn even-odd.
          $LogoNutData = @"
F0
M 89.84,27.00 L 50.00,4.00 L 10.16,27.00 L 10.16,73.00 L 50.00,96.00 L 89.84,73.00 Z
M 69.05,39.00 L 50.00,28.00 L 30.95,39.00 L 30.95,61.00 L 50.00,72.00 L 69.05,61.00 Z
"@
          $LogoNut = New-Object Windows.Shapes.Path
          $LogoNut.Data = [Windows.Media.Geometry]::Parse($LogoNutData)
          $LogoNut.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3DF5A0")

          # Inner accent dot at the center of the hole for a two-tone, distinctive look.
          $LogoDotData = "M 58.00,50.00 A 8,8 0 1,0 42.00,50.00 A 8,8 0 1,0 58.00,50.00 Z"
          $LogoDot = New-Object Windows.Shapes.Path
          $LogoDot.Data = [Windows.Media.Geometry]::Parse($LogoDotData)
          $LogoDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2BD389")

          $canvas.Children.Add($LogoNut) | Out-Null
          $canvas.Children.Add($LogoDot) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}
Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $Sync.InstalledPrograms = winget list -s winget | Select-Object -skip 3 | ConvertFrom-String -PropertyNames "Name", "Id", "Version", "Available" -Delimiter '\s{2,}'
        [Console]::OutputEncoding = $originalEncoding

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).winget -split ";")

            if ($dependencies[-1] -in $sync.InstalledPrograms.Id) {
                Write-Output $psitem.name
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $appxKeys = $entry.appx
            $invokeScript = $entry.InvokeScript
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            } else {
                if ($invokeScript -or $appxKeys) {
                    Write-Debug "Skipping $Config in Get Installed: no detectable registry, scheduled task, or service state."
                }
            }
        }
    }
}
function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
function Invoke-WinUtilFeatureInstall {
    <#

    .SYNOPSIS
        Converts all the values from the tweaks.json and routes them to the appropriate function

    #>

    param(
        $CheckBox
    )

    if($sync.configs.feature.$CheckBox.feature) {
        Foreach( $feature in $sync.configs.feature.$CheckBox.feature ) {
            try {
                Write-Host "Installing $feature"
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            } catch {
                if ($CheckBox.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {

                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $CheckBox.Exception.StackTrace
                }
            }
        }
    }
    if($sync.configs.feature.$CheckBox.InvokeScript) {
        Foreach( $script in $sync.configs.feature.$CheckBox.InvokeScript ) {
            try {
                $Scriptblock = [scriptblock]::Create($script)

                Write-Host "Running Script for $CheckBox"
                Invoke-Command $scriptblock -ErrorAction stop
            } catch {
                if ($CheckBox.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $CheckBox.Exception.StackTrace
                }
            }
        }
    }
}
function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
                Write-Debug "Scaled $resourceName from original $originalValue to $newValue (factor: $ScaleFactor)"
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }

    Write-Debug "Font scaling applied with factor: $ScaleFactor"
}


function Write-Win11ISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "Pronto. Seleziona una ISO di Windows 11 per iniziare.") {
            $sync["WPFWin11ISOStatusLog"].Text = "[$ts] $Message"
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $Message"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "Select Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "File size: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-Win11ISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "Nessuna ISO selezionata...") {
        [System.Windows.MessageBox]::Show("Seleziona prima un file ISO.", "Nessuna ISO selezionata", "OK", "Warning")
        return
    }

    Write-Win11ISOLog "Mounting ISO: $isoPath"
    Set-WinUtilProgressBar -Label "Mounting ISO..." -Percent 10

    try {
        Mount-DiskImage -ImagePath $isoPath

        do {
            Start-Sleep -Milliseconds 500
        } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

        $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
        Write-Win11ISOLog "Mounted at drive $driveLetter"

        Set-WinUtilProgressBar -Label "Verifying ISO contents..." -Percent 30

        $wimPath = Join-Path $driveLetter "sources\install.wim"
        $esdPath = Join-Path $driveLetter "sources\install.esd"

        if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: install.wim/install.esd not found — not a valid Windows ISO."
            [System.Windows.MessageBox]::Show(
                "This does not appear to be a valid Windows ISO.`n`ninstall.wim / install.esd was not found.",
                "Invalid ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

        Set-WinUtilProgressBar -Label "Reading image metadata..." -Percent 55
        $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

        if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: No 'Windows 11' edition found in the image."
            [System.Windows.MessageBox]::Show(
                "No Windows 11 edition was found in this ISO.`n`nOnly official Windows 11 ISOs are supported.",
                "Not a Windows 11 ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $sync["Win11ISOImageInfo"] = $imageInfo

        $sync["WPFWin11ISOMountDriveLetter"].Text = "Mounted at: $driveLetter   |   Image file: $(Split-Path $activeWim -Leaf)"
        $sync["WPFWin11ISOEditionComboBox"].Dispatcher.Invoke([action]{
            $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
            foreach ($img in $imageInfo) {
                [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
            }
            if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                $proIndex = -1
                for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                    if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                        $proIndex = $i; break
                    }
                }
                $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
            }
        })
        $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"

        $sync["Win11ISODriveLetter"] = $driveLetter
        $sync["Win11ISOWimPath"]     = $activeWim
        $sync["Win11ISOImagePath"]   = $isoPath
        $sync["WPFWin11ISOModifySection"].Visibility = "Visible"

        Set-WinUtilProgressBar -Label "ISO verified" -Percent 100
        Write-Win11ISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
    } catch {
        Write-Win11ISOLog "ERROR during mount/verify: $_"
        [System.Windows.MessageBox]::Show(
            "An error occurred while mounting or verifying the ISO:`n`n$_",
            "Error", "OK", "Error")
    } finally {
        Start-Sleep -Milliseconds 800
        Set-WinUtilProgressBar -Label "" -Percent 0
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "No verified ISO found. Please complete Steps 1 and 2 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-Win11ISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    $workDir = if ($existingWorkDir) {
        Write-Win11ISOLog "Reusing existing temp directory: $($existingWorkDir.FullName)"
        $existingWorkDir.FullName
    } else {
        Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true

    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n"       + ${function:Write-Win11ISOLog}.ToString()       + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            $mountDir    = Join-Path $workDir "wim_mount"
            New-Item -ItemType Directory -Path $isoContents, $mountDir -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Mounting install.wim..." 25

            $localWim = Join-Path $isoContents "sources\install.wim"
            if (-not (Test-Path $localWim)) { $localWim = Join-Path $isoContents "sources\install.esd" }
            Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false

            Log "Mounting install.wim (Index ${selectedWimIndex}: $selectedEditionName) at $mountDir..."
            Mount-WindowsImage -ImagePath $localWim -Index $selectedWimIndex -Path $mountDir
            SetProgress "Modifying install.wim..." 45

            Log "Applying WinUtil modifications to install.wim..."
            Invoke-WinUtilISOScript -ScratchDir $mountDir -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -Log { param($m) Log $m }

            SetProgress "Cleaning up component store (WinSxS)..." 56
            Log "Running DISM component store cleanup (/ResetBase)..."
            & dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | ForEach-Object { Log $_ }
            Log "Component store cleanup complete."

            SetProgress "Saving modified install.wim..." 65
            Log "Dismounting and saving install.wim. This will take several minutes..."
            Dismount-WindowsImage -Path $mountDir -Save
            Log "install.wim saved."

            SetProgress "Removing unused editions from install.wim..." 70
            Log "Exporting edition '$selectedEditionName' (Index $selectedWimIndex) to a single-edition install.wim..."
            $exportWim = Join-Path $isoContents "sources\install_export.wim"
            Export-WindowsImage -SourceImagePath $localWim -SourceIndex $selectedWimIndex -DestinationImagePath $exportWim
            Remove-Item -Path $localWim -Force
            Rename-Item -Path $exportWim -NewName "install.wim" -Force
            $localWim = Join-Path $isoContents "sources\install.wim"
            Log "Unused editions removed. install.wim now contains only '$selectedEditionName'."

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                if (Test-Path $mountDir) {
                    $mountedImages = Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }
                    if ($mountedImages) {
                        Log "Cleaning up: dismounting install.wim (discarding changes)..."
                        Dismount-WindowsImage -Path $mountDir -Discard
                    }
                }
            } catch { Log "Warning: could not dismount install.wim during cleanup: $_" }

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "An error occurred during install.wim modification:`n`n$_",
                    "Modification Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-Win11ISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-Win11ISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-Win11ISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "A previous WinUtil ISO working directory was found:`n`n$($existingWorkDir.FullName)`n`n(Last modified: $modified)`n`nStep 4 (output options) has been restored so you can save the already-modified image.`n`nClick 'Clean & Reset' in Step 4 if you want to start over.",
        "Existing Work Found", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "This will delete the temporary working directory:`n`n$workDir`n`nAnd reset the interface back to the start.`n`nContinue?",
            "Clean & Reset", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch {}
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch {}

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found — resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "Nessuna ISO selezionata..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "Pronto. Seleziona una ISO di Windows 11 per iniziare."
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "No modified ISO content found.  Please complete Steps 1-3 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "Save Modified Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-Win11ISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-Win11ISOLog "winget output: $result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-Win11ISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-Win11ISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "oscdimg.exe could not be found or installed automatically.`n`nPlease install it manually:`n  winget install -e --id Microsoft.OSCDIMG`n`nOr install the Windows ADK from:`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "oscdimg Not Found", "OK", "Warning")
            return
        }
        Write-Win11ISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n" + ${function:Write-Win11ISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-Win11ISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-Win11ISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-Win11ISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-Win11ISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-Win11ISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO exported successfully!`n`n$outputISO", "Export Complete", "OK", "Info")
                })
            } else {
                Write-Win11ISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg exited with code $($proc.ExitCode).`nCheck the status log for details.",
                        "Export Error", "OK", "Error")
                })
            }
        } catch {
            Write-Win11ISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO export failed:`n`n$_", "Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}
function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Applies WinUtil modifications to a mounted Windows 11 install.wim image.

    .DESCRIPTION
        Removes AppX bloatware and OneDrive, optionally injects all drivers exported from
        the running system into install.wim and boot.wim (controlled by the
        -InjectCurrentSystemDrivers switch), applies offline registry tweaks (hardware
        bypass, privacy, OOBE, telemetry, update suppression), deletes CEIP/WU
        scheduled-task definition files, and optionally writes autounattend.xml to the ISO
        root and removes the support\ folder from the ISO contents directory.

        All setup scripts embedded in the autounattend.xml <Extensions><File> nodes are
        written directly into the WIM at their target paths under C:\Windows\Setup\Scripts\
        to ensure they survive Windows Setup stripping unrecognised-namespace XML elements
        from the Panther copy of the answer file.

        Mounting/dismounting the WIM is the caller's responsibility (e.g. Invoke-WinUtilISO).

    .PARAMETER ScratchDir
        Mandatory. Full path to the directory where the Windows image is currently mounted.

    .PARAMETER ISOContentsDir
        Optional. Root directory of the extracted ISO contents. When supplied,
        autounattend.xml is written here and the support\ folder is removed.

    .PARAMETER AutoUnattendXml
        Optional. Full XML content for autounattend.xml. If empty, the OOBE bypass
        file is skipped and a warning is logged.

    .PARAMETER InjectCurrentSystemDrivers
        Optional. When $true, exports all drivers from the running system and injects
        them into install.wim and boot.wim index 2 (Windows Setup PE).
        Defaults to $false.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.

    .EXAMPLE
        Invoke-WinUtilISOScript -ScratchDir "C:\Temp\wim_mount"

    .EXAMPLE
        Invoke-WinUtilISOScript `
            -ScratchDir      $mountDir `
            -ISOContentsDir  $isoRoot `
            -AutoUnattendXml (Get-Content .\tools\autounattend.xml -Raw) `
            -Log             { param($m) Write-Host $m }

    .NOTES
        WinRUtil — https://github.com/rtecnocopy89/WinRUtil
        Based on ChrisTitusTech/winutil (MIT)
    #>
    param (
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$ISOContentsDir = "",
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )

    $adminSID   = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])

    function Set-ISOScriptReg {
        param ([string]$path, [string]$name, [string]$type, [string]$value)
        try {
            & reg add $path /v $name /t $type /d $value /f
            & $Log "Set registry value: $path\$name"
        } catch {
            & $Log "Error setting registry value: $_"
        }
    }

    function Remove-ISOScriptReg {
        param ([string]$path)
        try {
            & reg delete $path /f
            & $Log "Removed registry key: $path"
        } catch {
            & $Log "Error removing registry key: $_"
        }
    }

    function Add-DriversToImage {
        param ([string]$MountPath, [string]$DriverDir, [string]$Label = "image", [scriptblock]$Logger)
        & dism /English "/image:$MountPath" /Add-Driver "/Driver:$DriverDir" /Recurse |
            ForEach-Object { & $Logger "  dism[$Label]: $_" }
    }

    function Invoke-BootWimInject {
        param ([string]$BootWimPath, [string]$DriverDir, [scriptblock]$Logger)
        Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false
        $mountDir = Join-Path $env:TEMP "WinUtil_BootMount_$(Get-Random)"
        New-Item -Path $mountDir -ItemType Directory -Force
        try {
            & $Logger "Mounting boot.wim (index 2) for driver injection..."
            Mount-WindowsImage -ImagePath $BootWimPath -Index 2 -Path $mountDir
            Add-DriversToImage -MountPath $mountDir -DriverDir $DriverDir -Label "boot" -Logger $Logger
            & $Logger "Saving boot.wim..."
            Dismount-WindowsImage -Path $mountDir -Save
            & $Logger "boot.wim driver injection complete."
        } catch {
            & $Logger "Warning: boot.wim driver injection failed: $_"
            try { Dismount-WindowsImage -Path $mountDir -Discard } catch {}
        } finally {
            Remove-Item -Path $mountDir -Recurse -Force
        }
    }

    # ── 1. Remove provisioned AppX packages ──────────────────────────────────
    & $Log "Removing provisioned AppX packages..."

    $packages = & dism /English "/image:$ScratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @(
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams'
    )

    $packages | Where-Object { $pkg = $_; $packagePrefixes | Where-Object { $pkg -like "*$_*" } } |
        ForEach-Object { & dism /English "/image:$ScratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$_" }

    # ── 2. Inject current system drivers (optional) ───────────────────────────
    if ($InjectCurrentSystemDrivers) {
        & $Log "Exporting all drivers from running system..."
        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Random)"
        New-Item -Path $driverExportRoot -ItemType Directory -Force
        try {
            Export-WindowsDriver -Online -Destination $driverExportRoot

            & $Log "Injecting current system drivers into install.wim..."
            Add-DriversToImage -MountPath $ScratchDir -DriverDir $driverExportRoot -Label "install" -Logger $Log
            & $Log "install.wim driver injection complete."

            if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
                $bootWim = Join-Path $ISOContentsDir "sources\boot.wim"
                if (Test-Path $bootWim) {
                    & $Log "Injecting current system drivers into boot.wim..."
                    Invoke-BootWimInject -BootWimPath $bootWim -DriverDir $driverExportRoot -Logger $Log
                } else {
                    & $Log "Warning: boot.wim not found — skipping boot.wim driver injection."
                }
            }
        } catch {
            & $Log "Error during driver export/injection: $_"
        } finally {
            Remove-Item -Path $driverExportRoot -Recurse -Force
        }
    } else {
        & $Log "Driver injection skipped."
    }

    # ── 3. Registry tweaks ────────────────────────────────────────────────────
    & $Log "Loading offline registry hives..."
    reg load HKLM\zCOMPONENTS "$ScratchDir\Windows\System32\config\COMPONENTS"
    reg load HKLM\zDEFAULT    "$ScratchDir\Windows\System32\config\default"
    reg load HKLM\zNTUSER     "$ScratchDir\Users\Default\ntuser.dat"
    reg load HKLM\zSOFTWARE   "$ScratchDir\Windows\System32\config\SOFTWARE"
    reg load HKLM\zSYSTEM     "$ScratchDir\Windows\System32\config\SYSTEM"

    & $Log "Bypassing system requirements..."
    Set-ISOScriptReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV1' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache'  'SV2' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck'   'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck'       'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSYSTEM\Setup\MoSetup'   'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'

    & $Log "Disabling sponsored apps..."
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled'  'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled'     'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled'  'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed'      'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled'    'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled'          'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled'    'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\MRT'           'DontOfferThroughWUAU' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent'       'REG_DWORD' '1'

    & $Log "Enabling local accounts on OOBE..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'

    if ($AutoUnattendXml) {
        try {
            $xmlDoc = [xml]::new()
            $xmlDoc.LoadXml($AutoUnattendXml)

            $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
            $nsMgr.AddNamespace("sg", "https://schneegans.de/windows/unattend-generator/")

            $fileNodes = $xmlDoc.SelectNodes("//sg:File", $nsMgr)
            if ($fileNodes -and $fileNodes.Count -gt 0) {
                foreach ($fileNode in $fileNodes) {
                    $absPath  = $fileNode.GetAttribute("path")
                    $relPath  = $absPath -replace '^[A-Za-z]:[/\\]', ''
                    $destPath = Join-Path $ScratchDir $relPath
                    New-Item -Path (Split-Path $destPath -Parent) -ItemType Directory -Force

                    $ext = [IO.Path]::GetExtension($destPath).ToLower()
                    $encoding = switch ($ext) {
                        { $_ -in '.ps1', '.xml' }        { [System.Text.Encoding]::UTF8 }
                        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true) }
                        default                          { [System.Text.Encoding]::Default }
                    }
                    [System.IO.File]::WriteAllBytes($destPath, ($encoding.GetPreamble() + $encoding.GetBytes($fileNode.InnerText.Trim())))
                    & $Log "Pre-staged setup script: $relPath"
                }
            } else {
                & $Log "Warning: no <Extensions><File> nodes found in autounattend.xml — setup scripts not pre-staged."
            }
        } catch {
            & $Log "Warning: could not pre-stage setup scripts from autounattend.xml: $_"
        }

        if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
            $isoDest = Join-Path $ISOContentsDir "autounattend.xml"
            Set-Content -Path $isoDest -Value $AutoUnattendXml -Encoding UTF8 -Force
            & $Log "Written autounattend.xml to ISO root ($isoDest)."
        }
    } else {
        & $Log "Warning: autounattend.xml content is empty — skipping OOBE bypass file."
    }

    & $Log "Disabling reserved storage..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

    & $Log "Disabling BitLocker device encryption..."
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

    & $Log "Disabling Chat icon..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
    Set-ISOScriptReg 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

    & $Log "Disabling OneDrive folder backup..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 'REG_DWORD' '1'

    & $Log "Disabling telemetry..."
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection'  'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

    & $Log "Preventing installation of DevHome and Outlook..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate'      'workCompleted' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate'      'workCompleted' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

    & $Log "Disabling Copilot..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'      'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Edge'                   'HubsSidebarEnabled'          'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer'       'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

    & $Log "Disabling Windows Update during OOBE (re-enabled on first logon via FirstLogon.ps1)..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate'              'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions'                 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer'               'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'WUServer'                  'REG_SZ'    'http://localhost:8080'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'    'WUStatusServer'            'REG_SZ'    'http://localhost:8080'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 'REG_DWORD' '0'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\BITS'         'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv'     'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc'       'Start' 'REG_DWORD' '4'
    Set-ISOScriptReg 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSvc' 'Start' 'REG_DWORD' '4'

    & $Log "Preventing installation of Teams..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

    & $Log "Preventing installation of new Outlook..."
    Set-ISOScriptReg 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

    & $Log "Unloading offline registry hives..."
    reg unload HKLM\zCOMPONENTS
    reg unload HKLM\zDEFAULT
    reg unload HKLM\zNTUSER
    reg unload HKLM\zSOFTWARE
    reg unload HKLM\zSYSTEM

    # ── 4. Delete scheduled task definition files ─────────────────────────────
    & $Log "Deleting scheduled task definition files..."
    $tasksPath = "$ScratchDir\Windows\System32\Tasks"
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program"                  -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater"               -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Chkdsk\Proxy"                                            -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"                  -Force
    Remove-Item "$tasksPath\Microsoft\Windows\InstallService"                                          -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateOrchestrator"                                      -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateAssistant"                                         -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WaaSMedic"                                               -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WindowsUpdate"                                           -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\WindowsUpdate"                                                   -Recurse -Force
    & $Log "Scheduled task files deleted."

    # ── 5. Remove ISO support folder ─────────────────────────────────────────
    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        & $Log "Removing ISO support\ folder..."
        Remove-Item -Path (Join-Path $ISOContentsDir "support") -Recurse -Force
        & $Log "ISO support\ folder removed."
    }
}
function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("No USB drives detected.")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-Win11ISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-Win11ISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("No modified ISO content found. Please complete Steps 1-3 first.", "Not Ready", "OK", "Warning")
        return
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("Please select a USB drive from the dropdown.", "No Drive Selected", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "ALL data on Disk $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) will be PERMANENTLY ERASED.`n`nAre you sure you want to continue?",
        "Confirm USB Erase", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-Win11ISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    Write-Win11ISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch {}
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB drive created successfully!`n`nYou can now boot from this drive to install Windows 11.",
                    "USB Ready", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB write failed:`n`n$_", "USB Write Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}
function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }

}
function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time"
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}
function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($_ in $themeProperties) {
            # Apply properties that deal with colors
            if ($_.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($_.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($_.Name)" -Value $_.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($_.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($_.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($_.Name -like "*Thickness*") -or ($_.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($_.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-Preferences -save
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Set FOSS Highlight Color
    $fossEnabled = $true
    if ($sync.WPFToggleFOSSHighlight) {
        $fossEnabled = $sync.WPFToggleFOSSHighlight.IsChecked
    }

    if ($fossEnabled) {
         $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(76, 175, 80)) # #4CAF50
    } else {
         $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}
function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    Write-Debug "Tweaks: $($CheckBox)"
    if($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        Write-Debug "Service $($service.Name) was changed in the past to $($service.StartType.ToString()) from it's original type of $($psitem.$($values.OriginalService)), will not change it to $($psitem.$($values.service))"
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if($changeservice) {
                Write-Debug "$($psitem.Name) and state is $($psitem.$($values.service))"
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            if (($psitem.Path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
                if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                    Write-Debug "HKU drive created successfully."
                } else {
                    Write-Debug "Failed to create HKU drive."
                }
            }
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if(!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Write-Debug "UNDO $($psitem.Name)"
                Remove-WinUtilAPPX -Name $psitem
            }
        }

    }
}
function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $Name | Remove-AppxProvisionedPackage -Online
}
function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures
    $CheckBoxes = ($sync.GetEnumerator()).where{ $_.Value -is [System.Windows.Controls.CheckBox] -and $_.Name -notlike "WPFToggle*" -and $_.Name -like "$checkboxfilterpattern"}
    Write-Debug "Getting checkboxes to set, number of checkboxes: $($CheckBoxes.Count)"

    if ($CheckBoxesToCheck -ne "") {
        $debugMsg = "CheckBoxes to Check are: "
        $CheckBoxesToCheck | ForEach-Object { $debugMsg += "$_, " }
        $debugMsg = $debugMsg -replace (',\s*$', '')
        Write-Debug "$debugMsg"
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
            Write-Debug "$checkboxName is checked"
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
            Write-Debug "$checkboxName is not checked"
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "App selezionate: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import — toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
                Write-Debug "Restoring toggle: $($toggle.Key) = checked"
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}
function Set-Preferences{

    param(
        [switch]$save=$false
    )

    # TODO delete this function sometime later
    function Clean-OldPrefs{
        if (Test-Path -Path "$winutildir\LightTheme.ini") {
            $sync.preferences.theme = "Light"
            Remove-Item -Path "$winutildir\LightTheme.ini"
        }

        if (Test-Path -Path "$winutildir\DarkTheme.ini") {
            $sync.preferences.theme = "Dark"
            Remove-Item -Path "$winutildir\DarkTheme.ini"
        }

        # check old prefs, if its first line has no =, then absorb it as pm
        if (Test-Path -Path $iniPath) {
            $oldPM = Get-Content $iniPath
            if ($oldPM -notlike "*=*") {
                $sync.preferences.packagemanager = $oldPM
            }
        }

        if (Test-Path -Path "$winutildir\preferChocolatey.ini") {
            $sync.preferences.packagemanager = "Choco"
            Remove-Item -Path "$winutildir\preferChocolatey.ini"
        }
    }

    function Save-Preferences{
        $ini = ""
        foreach($key in $sync.preferences.Keys) {
            $pref = "$($key)=$($sync.preferences.$key)"
            Write-Debug "Saving pref: $($pref)"
            $ini = $ini + $pref + "`r`n"
        }
        $ini | Out-File $iniPath
    }

    function Load-Preferences{
        Clean-OldPrefs
        if (Test-Path -Path $iniPath) {
            $iniData = Get-Content "$winutildir\preferences.ini"
            foreach ($line in $iniData) {
                if ($line -like "*=*") {
                    $arr = $line -split "=",-2
                    $key = $arr[0] -replace "\s",""
                    $value = $arr[1] -replace "\s",""
                    Write-Debug "Preference: Key = '$($key)' Value ='$($value)'"
                    $sync.preferences.$key = $value
                }
            }
        }

        # write defaults in case preferences dont exist
        if ($null -eq $sync.preferences.theme) {
            $sync.preferences.theme = "Auto"
        }
        if ($null -eq $sync.preferences.packagemanager) {
            $sync.preferences.packagemanager = "Winget"
        }

        # convert packagemanager to enum
        if ($sync.preferences.packagemanager -eq "Choco") {
            $sync.preferences.packagemanager = [PackageManagers]::Choco
        }
        elseif ($sync.preferences.packagemanager -eq "Winget") {
            $sync.preferences.packagemanager = [PackageManagers]::Winget
        }
    }

    $iniPath = "$winutildir\preferences.ini"

    if ($save) {
        Save-Preferences
    }
    else {
        Load-Preferences
    }
}
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)
    if($DNSProvider -eq "Default") {return}
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary)", "$($sync.configs.dns.$DNSProvider.Secondary)")
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary6)", "$($sync.configs.dns.$DNSProvider.Secondary6)")
            }
        }
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlaid onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    if($PARAM_NOUI) {
        return;
    }

    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.Text = $label}
    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.ToolTip = $label}
    if ($percent -lt 5 ) {
        $percent = 5 # Ensure the progress bar is not empty, as it looks weird
    }
    Invoke-WPFUIThread -ScriptBlock { $sync.ProgressBar.Value = $percent}

}
function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }
}
Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
    } catch [System.ServiceProcess.ServiceNotFoundException] {
        Write-Warning "Service $Name was not found."
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $_.Exception.Message
    }

}
function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "Winutil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($sender, $args)
            Start-Process $sender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($sender, $args)
            $sender.Foreground = $LinkHoverForegroundColor
            $sender.FontSize = ($FontSize + ($FontSize / 4))
            $sender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($sender, $args)
            $sender.Foreground = $LinkForegroundColor
            $sender.FontSize = $FontSize
            $sender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}
function Show-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Displays a busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall is in progress.
        Dynamically updates the size of the overlay based on the app area on each invocation.
    .PARAMETER text
        The text to display in the busy overlay. Defaults to "Installing apps...".
    #>
    param (
        $text = "Installing apps..."
    )
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Visible
        $sync.InstallAppAreaOverlay.Width = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlay.Height = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlayText.Text = $text
        $sync.InstallAppAreaBorder.IsEnabled = $false
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 5
    }
}
function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}
function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.
    #>

    param (
        $flatJson
    )

    Write-Debug "JSON to import: $($flatJson)"

    foreach ($item in $flatJson) {
        # Ensure each item is treated as a string to handle PSCustomObject from JSON deserialization
        $cbkey = [string]$item
        $group = if ($cbkey.StartsWith("WPFInstall")) { "Install" }
                    elseif ($cbkey.StartsWith("WPFTweaks")) { "Tweaks" }
                    elseif ($cbkey.StartsWith("WPFToggle")) { "Toggle" }
                    elseif ($cbkey.StartsWith("WPFFeature")) { "Feature" }
                    else { "na" }

        switch ($group) {
            "Install" {
                if (!$sync.selectedApps.Contains($cbkey)) {
                    $sync.selectedApps.Add($cbkey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            "Tweaks" {
                if (!$sync.selectedTweaks.Contains($cbkey)) {
                    $sync.selectedTweaks.Add($cbkey)
                }
            }
            "Toggle" {
                if (!$sync.selectedToggles.Contains($cbkey)) {
                    $sync.selectedToggles.Add($cbkey)
                }
            }
            "Feature" {
                if (!$sync.selectedFeatures.Contains($cbkey)) {
                    $sync.selectedFeatures.Add($cbkey)
                }
            }
            default {
                Write-Host "Unknown group for checkbox: $($cbkey)"
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Seconds 5
        while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }
    }

    BusyWait

    Write-Host "Applying tweaks..."
    Invoke-WPFtweaksbutton
    BusyWait

    Write-Host "Applying toggles..."
    $handle = Invoke-WPFRunspace -ScriptBlock {
        $Toggles = $sync.selectedToggles
        Write-Debug "Inside Number of toggles to process: $($Toggles.Count)"

        $sync.ProcessRunning = $true

        for ($i = 0; $i -lt $Tweaks.Count; $i++) {
            Invoke-WinUtilTweaks $Toggles[$i]
        }

        $sync.ProcessRunning = $false
        Write-Host "================================="
        Write-Host "--     Toggles are Finished    ---"
        Write-Host "================================="
    }
    BusyWait

    Write-Host "Applying features..."
    Invoke-WPFFeatureInstall
    BusyWait

    Write-Host "Installing applications..."
    Invoke-WPFInstall
    BusyWait

    Write-Host "Done."
}
function Invoke-WinUtilRemoveEdge {
  New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force

  $Path = Resolve-Path -Path "$Env:ProgramFiles (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" | Select-Object -Last 1
  Start-Process -FilePath $Path -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' -Wait

  Write-Host "Microsoft Edge was removed" -ForegroundColor Green
}
function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","WinRUtil","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Expression $script
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Do}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFPrinterRefresh" {Invoke-WPFPrinterRefresh}
        "WPFPrinterRestartSpooler" {Invoke-WPFPrinterSpooler -Action "Restart"}
        "WPFPrinterClearQueue" {Invoke-WPFPrinterSpooler -Action "ClearQueue"}
        "WPFPrinterInstallDriver" {Invoke-WPFPrinterDriver -Action "Install"}
        "WPFPrinterRemoveDriver" {Invoke-WPFPrinterDriver -Action "Remove"}
        "WPFWifiRefresh" {Invoke-WPFWifiRefresh}
        "WPFWifiCopyAll" {Invoke-WPFWifiCopyAll}
        "WPFSystemInfoRefresh" {Invoke-WPFSystemInfoRefresh}
        "WPFSystemInfoExport" {Invoke-WPFSystemInfoExport}
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
        "WPFToggleFOSSHighlight" {
            if ($sync.WPFToggleFOSSHighlight.IsChecked) {
                 $sync.Form.Resources["FOSSColor"] = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(76, 175, 80)) # #4CAF50
            } else {
                 $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
            }
        }
    }
}
function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $handle = Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$CheckBox.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}
function Invoke-WPFFixesNetwork {
    <#

    .SYNOPSIS
        Resets various network configurations

    #>

    Write-Host "Resetting Network with netsh"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo"
    # Reset WinSock catalog to a clean state
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.35 -overlay "logo"
    # Resets WinHTTP proxy setting to DIRECT
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.7 -overlay "logo"
    # Removes all user configured IP settings
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    Write-Host "Process complete. Please reboot your computer."

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Network Reset "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "=========================================="
    Write-Host "-- Network Configuration has been Reset --"
    Write-Host "=========================================="
}
function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}
function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}
function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}
function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("managerPreference", $managerPreference),("checkbox", $checkbox)) -ScriptBlock {
        param (
            [string]$checkbox,
            [PackageManagers]$managerPreference
        )
        $sync.ProcessRunning = $true
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            switch ($managerPreference) {
                "Choco"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco"; break}
                "Winget"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox; break}
            }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })

        Write-Host "Done..."
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" }
    }
}
function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "No settings are selected to export. Please select at least one app, tweak, toggle, or feature before exporting.",
                            "Nothing to Export", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/main/winrutil.ps1) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "The selected file contains no settings to import. No changes have been made.",
                            "Empty Configuration", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if (!$PARAM_NOUI) {
                        # Set flag so toggle Checked/Unchecked events don't trigger registry writes
                        # while we're programmatically restoring UI state from the imported config
                        $sync.ImportInProgress = $true
                        try {
                            Reset-WPFCheckBoxes -doToggles $true
                        } finally {
                            $sync.ImportInProgress = $false
                        }
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>

    $PackagesToInstall = $sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ }


    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager

    $handle = Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Show-WPFInstallAppBusy -text "Installing apps..."
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False
    }
}
function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}
function Invoke-WPFOOSU {
    <#
    .SYNOPSIS
        Downloads and runs OO Shutup 10
    #>
    try {
        $OOSU_filepath = "$ENV:temp\OOSU10.exe"
        $Initial_ProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue" # Disables the Progress Bar to drasticly speed up Invoke-WebRequest
        Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $OOSU_filepath
        Write-Host "Starting OO Shutup 10 ..."
        Start-Process $OOSU_filepath
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
function Invoke-WPFPanelAutologin {
    <#

    .SYNOPSIS
        Enables autologin using Sysinternals Autologon.exe

    #>

    # Official Microsoft recommendation: https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile "$env:temp\autologin.exe"
    cmd /c "$env:temp\autologin.exe" /accepteula
}
function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}
function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}
function Write-WinUtilPrinterLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Printers tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFPrinterStatusLog
    if (-not $logBox) {
        Write-Host $line
        return
    }

    $action = {
        if ([string]::IsNullOrWhiteSpace($logBox.Text) -or $logBox.Text -like "Pronto.*") {
            $logBox.Text = $line
        } else {
            $logBox.AppendText("`r`n$line")
        }
        $logBox.ScrollToEnd()
    }

    if ($logBox.Dispatcher.CheckAccess()) {
        & $action
    } else {
        $logBox.Dispatcher.Invoke($action)
    }
}

function Invoke-WPFPrinterRefresh {
    <#
        .SYNOPSIS
            Detects installed printers and fills the Printers DataGrid with driver, port, status and queued jobs.
    #>
    Write-WinUtilPrinterLog "Scansione delle stampanti installate..."
    try {
        $rows = New-Object System.Collections.Generic.List[PSObject]
        $printers = Get-Printer -ErrorAction Stop

        foreach ($printer in $printers) {
            $jobCount = 0
            try {
                $jobCount = @(Get-PrintJob -PrinterName $printer.Name -ErrorAction Stop).Count
            } catch {
                $jobCount = 0
            }

            $rows.Add([PSCustomObject]@{
                Name   = $printer.Name
                Driver = $printer.DriverName
                Port   = $printer.PortName
                Status = [string]$printer.PrinterStatus
                Jobs   = $jobCount
            })
        }

        $sync.WPFPrinterList.ItemsSource = $rows
        Write-WinUtilPrinterLog ("Trovate {0} stampante/i." -f $rows.Count) -Level Success
    } catch {
        Write-WinUtilPrinterLog "Impossibile elencare le stampanti: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFPrinterSpooler {
    <#
        .SYNOPSIS
            Manages the Windows print spooler: restart the service or clear the print queue.
        .PARAMETER Action
            "Restart" restarts the Spooler service. "ClearQueue" purges all queued jobs.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Restart", "ClearQueue")]
        [string]$Action
    )

    switch ($Action) {
        "Restart" {
            Write-WinUtilPrinterLog "Riavvio del servizio Spooler di stampa..."
            try {
                Restart-Service -Name Spooler -Force -ErrorAction Stop
                Write-WinUtilPrinterLog "Spooler di stampa riavviato." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Riavvio dello spooler non riuscito: $($_.Exception.Message)" -Level Error
            }
        }
        "ClearQueue" {
            Write-WinUtilPrinterLog "Svuotamento della coda di stampa..."
            $spoolPath = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
            try {
                Stop-Service -Name Spooler -Force -ErrorAction Stop
                if (Test-Path $spoolPath) {
                    Get-ChildItem -Path $spoolPath -File -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
                Start-Service -Name Spooler -ErrorAction Stop
                Write-WinUtilPrinterLog "Coda di stampa svuotata e spooler riavviato." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Svuotamento della coda non riuscito: $($_.Exception.Message)" -Level Error
                try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch {}
            }
            Invoke-WPFPrinterRefresh
        }
    }
}

function Invoke-WPFPrinterDriver {
    <#
        .SYNOPSIS
            Installs a printer driver from an INF package, or removes the driver of the selected printer.
        .PARAMETER Action
            "Install" prompts for an .inf file and stages it with pnputil. "Remove" removes the
            driver used by the printer selected in the list.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Install", "Remove")]
        [string]$Action
    )

    switch ($Action) {
        "Install" {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title  = "Seleziona un file di installazione driver (.inf)"
            $dialog.Filter = "File driver (*.inf)|*.inf|Tutti i file (*.*)|*.*"
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
                Write-WinUtilPrinterLog "Installazione del driver annullata." -Level Warning
                return
            }

            $inf = $dialog.FileName
            Write-WinUtilPrinterLog "Installazione del driver da: $inf"
            try {
                $output = & pnputil.exe /add-driver "$inf" /install 2>&1
                $output | ForEach-Object { Write-WinUtilPrinterLog $_ }
                if ($LASTEXITCODE -eq 0) {
                    Write-WinUtilPrinterLog "Driver installato correttamente." -Level Success
                } else {
                    Write-WinUtilPrinterLog "pnputil e' terminato con codice $LASTEXITCODE." -Level Warning
                }
            } catch {
                Write-WinUtilPrinterLog "Installazione del driver non riuscita: $($_.Exception.Message)" -Level Error
            }
            Invoke-WPFPrinterRefresh
        }
        "Remove" {
            $selected = $sync.WPFPrinterList.SelectedItem
            if (-not $selected) {
                Write-WinUtilPrinterLog "Seleziona prima una stampante nell'elenco, poi clicca Rimuovi driver." -Level Warning
                return
            }

            $driverName = $selected.Driver
            Write-WinUtilPrinterLog "Rimozione del driver '$driverName' (stampante '$($selected.Name)')..."
            try {
                Remove-PrinterDriver -Name $driverName -ErrorAction Stop
                Write-WinUtilPrinterLog "Driver '$driverName' rimosso." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Impossibile rimuovere il driver (potrebbe essere ancora in uso): $($_.Exception.Message)" -Level Error
            }
            Invoke-WPFPrinterRefresh
        }
    }
}
function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    # Create a PowerShell instance
    $script:powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    $script:powershell.AddScript($ScriptBlock)
    $script:powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        $script:powershell.AddParameter($parameter[0], $parameter[1])
    }

    $script:powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $script:handle = $script:powershell.BeginInvoke()

    # Clean up the RunspacePool threads when they are complete, and invoke the garbage collector to clean up the memory
    if ($script:handle.IsCompleted) {
        $script:powershell.EndInvoke($script:handle)
        $script:powershell.Dispose()
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
    }
    # Return the handle
    return $handle
}
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

    # Get the actual Name from the selectedAppLabel inside the Checkbox
    $appKey = $checkboxName
    $group = if ($appKey.StartsWith("WPFInstall")) { "Install" }
                elseif ($appKey.StartsWith("WPFTweaks")) { "Tweaks" }
                elseif ($appKey.StartsWith("WPFToggle")) { "Toggle" }
                elseif ($appKey.StartsWith("WPFFeature")) { "Feature" }
                else { "na" }

    switch ($group) {
        "Install" {
            if ($type -eq "Add") {
               if (!$sync.selectedApps.Contains($appKey)) {
                    $sync.selectedApps.Add($appKey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            else{
                $sync.selectedApps.Remove($appKey)
            }

            $count = $sync.SelectedApps.Count
            $sync.WPFselectedAppsButton.Content = "App selezionate: $count"
            # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
            $sync.selectedAppsstackPanel.Children.Clear()
            $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
        }
        "Tweaks" {
            if ($type -eq "Add") {
                if (!$sync.selectedTweaks.Contains($appKey)) {
                    $sync.selectedTweaks.Add($appKey)
                }
            }
            else{
                $sync.selectedTweaks.Remove($appKey)
            }
        }
        "Toggle" {
            if ($type -eq "Add") {
                if (!$sync.selectedToggles.Contains($appKey)) {
                    $sync.selectedToggles.Add($appKey)
                }
            }
            else{
                $sync.selectedToggles.Remove($appKey)
            }
        }
        "Feature" {
            if ($type -eq "Add") {
                if (!$sync.selectedFeatures.Contains($appKey)) {
                    $sync.selectedFeatures.Add($appKey)
                }
            }
            else{
                $sync.selectedFeatures.Remove($appKey)
            }
        }
        default {
            Write-Host "Unknown group for checkbox: $($appKey)"
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
}
function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}
function Write-WinUtilSystemLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the System tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFSystemLog
    if (-not $logBox) {
        Write-Host $line
        return
    }

    $action = {
        if ([string]::IsNullOrWhiteSpace($logBox.Text) -or $logBox.Text -like "Pronto.*") {
            $logBox.Text = $line
        } else {
            $logBox.AppendText("`r`n$line")
        }
        $logBox.ScrollToEnd()
    }

    if ($logBox.Dispatcher.CheckAccess()) {
        & $action
    } else {
        $logBox.Dispatcher.Invoke($action)
    }
}

function Get-WinUtilSystemReport {
    <#
        .SYNOPSIS
            Gathers OS, activation, hardware, CPU, RAM, storage (with SMART health),
            GPU, network and battery information via CIM/WMI. Returns a hashtable of
            preformatted strings (plus numeric percentages for the progress bars).
            Every section is isolated so a single failing query never aborts the report.
    #>

    $r = @{}

    # Helpers (local) ----------------------------------------------------------
    $toGB = { param($bytes) try { [math]::Round([double]$bytes / 1GB, 1) } catch { 0 } }
    $nd   = "Non disponibile"

    # OS / build ---------------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $r.OSCaption = ($os.Caption -replace 'Microsoft ', '').Trim()
        $display = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        $buildStr = "$($os.Version)"
        if ($ubr) { $buildStr = "$($os.Version).$ubr" }
        $verPart = if ($display) { "versione $display" } else { "" }
        $r.OSBuild = ("{0}  ·  build {1}  ·  {2}" -f $verPart, $buildStr, $os.OSArchitecture).TrimStart(' ·').Trim()
        $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = try { (Get-Date $os.InstallDate -Format 'dd/MM/yyyy') } catch { $nd }
        $boot = $os.LastBootUpTime
        $up = (Get-Date) - $boot
        $r.Uptime = if ($up.Days -gt 0) { "{0}g {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes } else { "{0}h {1}m" -f $up.Hours, $up.Minutes }
    } catch {
        $r.OSCaption = "Windows"; $r.OSBuild = $nd; $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = $nd; $r.Uptime = $nd
    }

    # Activation ---------------------------------------------------------------
    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
            -ErrorAction Stop | Select-Object -First 1
        switch ([int]$lic.LicenseStatus) {
            1       { $r.ActivationText = "Windows attivato";        $r.ActivationColor = "#3DF5A0" }
            2       { $r.ActivationText = "Periodo di prova (OOB)";  $r.ActivationColor = "#F5A623" }
            3       { $r.ActivationText = "Periodo di prova (OOT)";  $r.ActivationColor = "#F5A623" }
            4       { $r.ActivationText = "Copia non genuina";       $r.ActivationColor = "#EF4444" }
            5       { $r.ActivationText = "Non attivato";            $r.ActivationColor = "#EF4444" }
            6       { $r.ActivationText = "Tolleranza estesa";       $r.ActivationColor = "#F5A623" }
            default { $r.ActivationText = "Non attivato";            $r.ActivationColor = "#EF4444" }
        }
    } catch {
        $r.ActivationText = "Stato sconosciuto"; $r.ActivationColor = "#8A93A6"
    }

    # Hardware -----------------------------------------------------------------
    try {
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $r.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { $nd }
        $r.Model = if ($cs.Model) { $cs.Model.Trim() } else { $nd }
        $r.Serial = if ($bios -and $bios.SerialNumber -and $bios.SerialNumber -notmatch '^(0+|To be filled.*|Default.*|System Serial.*)$') { $bios.SerialNumber.Trim() } else { $nd }
        $r.Bios = if ($bios) { ("{0}" -f $bios.SMBIOSBIOSVersion).Trim() } else { $nd }
    } catch {
        $r.Manufacturer = $nd; $r.Model = $nd; $r.Serial = $nd; $r.Bios = $nd
    }

    # Secure Boot
    $r.SecureBoot = try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { "Attivo" } else { "Disattivato" }
    } catch { $nd }

    # TPM
    $r.Tpm = try {
        $t = Get-Tpm -ErrorAction Stop
        if (-not $t.TpmPresent) { "Assente" }
        elseif ($t.TpmEnabled) { "Presente e attivo" }
        else                    { "Presente (disattivato)" }
    } catch {
        try {
            $tc = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -Class Win32_Tpm -ErrorAction Stop
            if ($tc.IsEnabled_InitialValue) { "Presente e attivo" } else { "Presente (disattivato)" }
        } catch { $nd }
    }

    # CPU ----------------------------------------------------------------------
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $cpu = $cpus[0]
        $r.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $r.CpuCores = "$cores core / $threads thread"
        $r.CpuClock = "{0:N2} GHz" -f ([double]$cpu.MaxClockSpeed / 1000)
        $load = [math]::Round(($cpus | Measure-Object -Property LoadPercentage -Average).Average)
        $r.CpuLoadPct = [double]$load
        $r.CpuLoad = "$load%"
    } catch {
        $r.CpuName = $nd; $r.CpuCores = $nd; $r.CpuClock = $nd; $r.CpuLoadPct = 0; $r.CpuLoad = "-"
    }

    # RAM ----------------------------------------------------------------------
    try {
        if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        $totalGB = & $toGB $cs.TotalPhysicalMemory
        $freeGB  = [math]::Round(([double]$os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $r.RamText = "{0:N1} / {1:N1} GB" -f $usedGB, $totalGB
        $r.RamUsedPct = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100) } else { 0 }
        $r.RamFree = "{0:N1} GB" -f $freeGB
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($mods.Count -gt 0) {
            $speed = ($mods | Select-Object -First 1).Speed
            $r.RamModules = "{0} modulo/i @ {1} MHz" -f $mods.Count, $speed
        } else { $r.RamModules = $nd }
    } catch {
        $r.RamText = $nd; $r.RamUsedPct = 0; $r.RamFree = $nd; $r.RamModules = $nd
    }

    # Storage ------------------------------------------------------------------
    $disks = New-Object System.Collections.Generic.List[object]
    try {
        $vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
        foreach ($v in ($vols | Select-Object -First 4)) {
            if (-not $v.Size -or $v.Size -eq 0) { continue }
            $sizeGB = & $toGB $v.Size
            $freeGB = & $toGB $v.FreeSpace
            $usedPct = [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100)
            $label = $v.DeviceID
            if ($v.VolumeName) { $label = "{0}  {1}" -f $v.DeviceID, $v.VolumeName }
            $disks.Add(@{
                Label   = $label
                Text    = ("{0:N0} GB liberi su {1:N0} GB" -f $freeGB, $sizeGB)
                UsedPct = $usedPct
                Warn    = ($usedPct -ge 90)
            })
        }
    } catch { }
    $r.Disks = $disks

    # SMART / physical-disk health
    try {
        $health = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -ExpandProperty HealthStatus -Unique)
        if ($health -contains 'Unhealthy') { $r.DiskHealthText = "Salute: Critico";    $r.DiskHealthColor = "#EF4444" }
        elseif ($health -contains 'Warning') { $r.DiskHealthText = "Salute: Attenzione"; $r.DiskHealthColor = "#F5A623" }
        elseif ($health -contains 'Healthy') { $r.DiskHealthText = "Salute: OK";         $r.DiskHealthColor = "#3DF5A0" }
        else                                 { $r.DiskHealthText = "Salute: n/d";        $r.DiskHealthColor = "#8A93A6" }
    } catch {
        $r.DiskHealthText = "Salute: n/d"; $r.DiskHealthColor = "#8A93A6"
    }

    # GPU ----------------------------------------------------------------------
    $r.GpuName = $nd; $r.GpuVram = $nd; $r.GpuDriver = $nd; $r.GpuResolution = $nd
    try {
        $allGpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        # Prefer real adapters, but keep the basic/remote one if it is all we have
        $real = @($allGpus | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Mirror|Basic Display|DameWare|Meta Virtual' })
        $gpus = if ($real.Count -gt 0) { $real } else { $allGpus }

        $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) { $r.GpuName = ($names -join "  ·  ") }

        $g0 = $gpus | Select-Object -First 1
        if ($g0) {
            # VRAM: Win32_VideoController.AdapterRAM is a 32-bit value capped at ~4 GB,
            # so prefer the accurate qwMemorySize from the display-adapter registry key.
            $vramBytes = 0
            try {
                $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                Get-ChildItem $base -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                    $q = (Get-ItemProperty -Path $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
                    if ($q -and [double]$q -gt $vramBytes) { $vramBytes = [double]$q }
                }
            } catch { }
            try {
                if ($vramBytes -le 0 -and $g0.AdapterRAM) { $vramBytes = [double]$g0.AdapterRAM }
                if ($vramBytes -gt 0) {
                    $vramGB = [math]::Round($vramBytes / 1GB, 0)
                    if ($vramGB -ge 1) { $r.GpuVram = "{0:N0} GB" -f $vramGB }
                }
            } catch { }
            if ($g0.DriverVersion) { $r.GpuDriver = $g0.DriverVersion }
        }

        $active = $gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($active) { $r.GpuResolution = "{0} x {1}" -f $active.CurrentHorizontalResolution, $active.CurrentVerticalResolution }
    } catch { }

    # Network ------------------------------------------------------------------
    try {
        $cfg = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4Address -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($cfg) {
            $r.NetAdapter = $cfg.InterfaceAlias
            $r.NetIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
            $r.NetMac = if ($cfg.NetAdapter.MacAddress) { $cfg.NetAdapter.MacAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } else { throw "no up adapter" }
    } catch {
        try {
            $na = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop | Select-Object -First 1
            $r.NetAdapter = $na.Description
            $r.NetIp = ($na.IPAddress | Where-Object { $_ -match '\.' } | Select-Object -First 1)
            $r.NetMac = if ($na.MACAddress) { $na.MACAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } catch {
            $r.NetAdapter = $nd; $r.NetIp = "n/d"; $r.NetMac = $nd; $r.NetStatus = "Non connesso"
        }
    }

    # Battery ------------------------------------------------------------------
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($batt) {
            $r.HasBattery = $true
            $r.BatteryPct = [double]$batt.EstimatedChargeRemaining
            $r.BatteryCharge = "{0}%" -f [int]$batt.EstimatedChargeRemaining
            $r.BatteryStatus = switch ([int]$batt.BatteryStatus) {
                1 { "In uso (a batteria)" }
                2 { "Alimentazione di rete" }
                3 { "Carica completa" }
                4 { "Bassa" }
                5 { "Critica" }
                6 { "In carica" }
                7 { "In carica (alta)" }
                8 { "In carica (bassa)" }
                9 { "In carica (critica)" }
                default { "Sconosciuto" }
            }
            $r.BatteryHealth = $nd
            try {
                $static = Get-CimInstance -Namespace root/wmi -Class BatteryStaticData -ErrorAction Stop | Select-Object -First 1
                $full   = Get-CimInstance -Namespace root/wmi -Class BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($static.DesignedCapacity -gt 0 -and $full.FullChargedCapacity -gt 0) {
                    $wear = [math]::Round((1 - ($full.FullChargedCapacity / $static.DesignedCapacity)) * 100, 1)
                    if ($wear -lt 0) { $wear = 0 }
                    $r.BatteryHealth = "{0:N0}% usura" -f $wear
                }
            } catch { }
        } else { $r.HasBattery = $false }
    } catch { $r.HasBattery = $false }

    return $r
}

function Invoke-WPFSystemInfoRefresh {
    <#
        .SYNOPSIS
            Refreshes the System dashboard. Gathers the report on a background runspace
            and pushes every value to the WPF controls on the UI thread, so the window
            never freezes while data is collected.
    #>

    if ($sync.SystemInfoLoading) { return }
    $sync.SystemInfoLoading = $true
    Write-WinUtilSystemLog "Raccolta delle informazioni di sistema in corso..."

    Invoke-WPFRunspace -ScriptBlock {
        try {
            $report = Get-WinUtilSystemReport
            $sync.SystemReport = $report

            Invoke-WPFUIThread -ScriptBlock {
                $r = $sync.SystemReport

                # Local helper: paint one of the star-grid progress bars.
                function Set-SysBar($grid, $pct, $warn) {
                    if (-not $grid) { return }
                    $p = [double][math]::Max(0, [math]::Min(100, $pct))
                    $grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new($p, [System.Windows.GridUnitType]::Star)
                    $grid.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new((100 - $p), [System.Windows.GridUnitType]::Star)
                    $hex = if ($warn) { "#EF4444" } else { "#3DF5A0" }
                    $col = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                    $grid.Children[0].Background = [System.Windows.Media.SolidColorBrush]::new($col)
                }
                function New-SysBrush($hex) {
                    $col = [System.Windows.Media.Color]([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
                    [System.Windows.Media.SolidColorBrush]::new($col)
                }

                # Hero
                $sync.WPFSysOSCaption.Text   = $r.OSCaption
                $sync.WPFSysOSBuild.Text      = $r.OSBuild
                $sync.WPFSysHostname.Text     = $r.Hostname
                $sync.WPFSysUptime.Text       = $r.Uptime
                $sync.WPFSysInstallDate.Text  = $r.InstallDate
                $sync.WPFSysActivation.Text   = $r.ActivationText
                $sync.WPFSysActivation.Foreground = New-SysBrush $r.ActivationColor
                $sync.WPFSysActivationDot.Fill    = New-SysBrush $r.ActivationColor

                # Hardware
                $sync.WPFSysManufacturer.Text = $r.Manufacturer
                $sync.WPFSysModel.Text        = $r.Model
                $sync.WPFSysSerial.Text       = $r.Serial
                $sync.WPFSysBios.Text         = $r.Bios
                $sync.WPFSysSecureBoot.Text   = $r.SecureBoot
                $sync.WPFSysTpm.Text          = $r.Tpm

                # CPU
                $sync.WPFSysCpuName.Text  = $r.CpuName
                $sync.WPFSysCpuCores.Text = $r.CpuCores
                $sync.WPFSysCpuClock.Text = $r.CpuClock
                $sync.WPFSysCpuLoad.Text  = $r.CpuLoad
                Set-SysBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                # RAM
                $sync.WPFSysRamText.Text    = $r.RamText
                $sync.WPFSysRamFree.Text    = $r.RamFree
                $sync.WPFSysRamModules.Text = $r.RamModules
                Set-SysBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)

                # Storage
                $sync.WPFSysDiskHealth.Text       = $r.DiskHealthText
                $sync.WPFSysDiskHealth.Foreground = New-SysBrush $r.DiskHealthColor
                for ($i = 0; $i -lt 4; $i++) {
                    $panel = $sync["WPFSysDisk$i"]
                    if (-not $panel) { continue }
                    if ($i -lt $r.Disks.Count) {
                        $d = $r.Disks[$i]
                        $sync["WPFSysDisk${i}Label"].Text = $d.Label
                        $sync["WPFSysDisk${i}Text"].Text  = $d.Text
                        Set-SysBar $sync["WPFSysDisk${i}Bar"] $d.UsedPct $d.Warn
                        $panel.Visibility = "Visible"
                    } else {
                        $panel.Visibility = "Collapsed"
                    }
                }

                # GPU
                $sync.WPFSysGpuName.Text       = $r.GpuName
                $sync.WPFSysGpuVram.Text       = $r.GpuVram
                $sync.WPFSysGpuResolution.Text = $r.GpuResolution
                $sync.WPFSysGpuDriver.Text     = $r.GpuDriver

                # Network
                $sync.WPFSysNetAdapter.Text = $r.NetAdapter
                $sync.WPFSysNetIp.Text      = $r.NetIp
                $sync.WPFSysNetMac.Text     = $r.NetMac
                $sync.WPFSysNetStatus.Text  = $r.NetStatus

                # Battery
                if ($r.HasBattery) {
                    $sync.WPFSysBatteryCard.Visibility = "Visible"
                    $sync.WPFSysBatteryCharge.Text = $r.BatteryCharge
                    $sync.WPFSysBatteryStatus.Text = $r.BatteryStatus
                    $sync.WPFSysBatteryHealth.Text = $r.BatteryHealth
                    Set-SysBar $sync.WPFSysBatteryBar $r.BatteryPct ($r.BatteryPct -le 15)
                } else {
                    $sync.WPFSysBatteryCard.Visibility = "Collapsed"
                }
            }

            Write-WinUtilSystemLog "Informazioni di sistema aggiornate." -Level Success
        } catch {
            Write-WinUtilSystemLog "Errore durante la lettura del sistema: $($_.Exception.Message)" -Level Error
        } finally {
            $sync.SystemInfoLoading = $false
        }
    }
}

function Invoke-WPFSystemInfoExport {
    <#
        .SYNOPSIS
            Writes the current system report to a timestamped .txt file on the Desktop.
    #>

    Write-WinUtilSystemLog "Creazione del report di sistema..."
    Invoke-WPFRunspace -ScriptBlock {
        try {
            $r = $sync.SystemReport
            if (-not $r) { $r = Get-WinUtilSystemReport; $sync.SystemReport = $r }

            $sb = New-Object System.Text.StringBuilder
            $null = $sb.AppendLine("WinRUtil - Report di sistema")
            $null = $sb.AppendLine("Generato il $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
            $null = $sb.AppendLine(("=" * 56))
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ WINDOWS ]")
            $null = $sb.AppendLine("  Edizione        : $($r.OSCaption)")
            $null = $sb.AppendLine("  Build           : $($r.OSBuild)")
            $null = $sb.AppendLine("  Attivazione     : $($r.ActivationText)")
            $null = $sb.AppendLine("  Nome PC         : $($r.Hostname)")
            $null = $sb.AppendLine("  Installato il   : $($r.InstallDate)")
            $null = $sb.AppendLine("  Acceso da       : $($r.Uptime)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ HARDWARE ]")
            $null = $sb.AppendLine("  Produttore      : $($r.Manufacturer)")
            $null = $sb.AppendLine("  Modello         : $($r.Model)")
            $null = $sb.AppendLine("  N. di serie     : $($r.Serial)")
            $null = $sb.AppendLine("  BIOS / UEFI     : $($r.Bios)")
            $null = $sb.AppendLine("  Secure Boot     : $($r.SecureBoot)")
            $null = $sb.AppendLine("  TPM             : $($r.Tpm)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ PROCESSORE ]")
            $null = $sb.AppendLine("  Modello         : $($r.CpuName)")
            $null = $sb.AppendLine("  Core / Thread   : $($r.CpuCores)")
            $null = $sb.AppendLine("  Frequenza base  : $($r.CpuClock)")
            $null = $sb.AppendLine("  Carico attuale  : $($r.CpuLoad)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ MEMORIA ]")
            $null = $sb.AppendLine("  Utilizzo        : $($r.RamText)")
            $null = $sb.AppendLine("  Disponibile     : $($r.RamFree)")
            $null = $sb.AppendLine("  Moduli          : $($r.RamModules)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ ARCHIVIAZIONE ]$($r.DiskHealthText)")
            foreach ($d in $r.Disks) {
                $null = $sb.AppendLine("  $($d.Label)  -  $($d.Text)  ($($d.UsedPct)% usato)")
            }
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ GRAFICA ]")
            $null = $sb.AppendLine("  Scheda          : $($r.GpuName)")
            $null = $sb.AppendLine("  Memoria video   : $($r.GpuVram)")
            $null = $sb.AppendLine("  Risoluzione     : $($r.GpuResolution)")
            $null = $sb.AppendLine("  Driver          : $($r.GpuDriver)")
            $null = $sb.AppendLine("")
            $null = $sb.AppendLine("[ RETE ]")
            $null = $sb.AppendLine("  Scheda          : $($r.NetAdapter)")
            $null = $sb.AppendLine("  Indirizzo IPv4  : $($r.NetIp)")
            $null = $sb.AppendLine("  Indirizzo MAC   : $($r.NetMac)")
            $null = $sb.AppendLine("  Stato           : $($r.NetStatus)")
            if ($r.HasBattery) {
                $null = $sb.AppendLine("")
                $null = $sb.AppendLine("[ BATTERIA ]")
                $null = $sb.AppendLine("  Carica          : $($r.BatteryCharge)")
                $null = $sb.AppendLine("  Stato           : $($r.BatteryStatus)")
                $null = $sb.AppendLine("  Salute          : $($r.BatteryHealth)")
            }

            $fileName = "WinRUtil-Sistema_{0}_{1}.txt" -f $r.Hostname, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $path = Join-Path ([Environment]::GetFolderPath('Desktop')) $fileName
            $sb.ToString() | Out-File -FilePath $path -Encoding UTF8 -Force
            Write-WinUtilSystemLog "Report salvato sul Desktop: $fileName" -Level Success
        } catch {
            Write-WinUtilSystemLog "Impossibile creare il report: $($_.Exception.Message)" -Level Error
        }
    }
}
function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}
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
            "Win11ISO" = "Crea Win11"
            "System"   = "Sistema"
            "WiFi"     = "Password Wi-Fi"
        }
        $display = $titleMap[[string]$sync.currentTab]
        if (-not $display) { $display = $sync.currentTab }
        $sync.WPFCurrentTabTitle.Text = $display
    }

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "System") {
        # Auto-populate the System dashboard when it is opened
        Invoke-WPFSystemInfoRefresh
    }

    # Show search bar in Install and Tweaks tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1) {
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
function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}
function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  Write-Debug "Number of tweaks to process: $($Tweaks.Count)"

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilProgressBar -Label "Creating restore point" -Percent 0
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  $handle = Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)
    Write-Debug "Inside Number of tweaks to process: $($Tweaks.Count)"

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    Set-WinUtilDNS -DNSProvider $dnsProvider

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilProgressBar -Label "Applying $($tweaks[$i])" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
  }
}
function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        if ($entryInfo.Name -eq "WPFToggleFOSSHighlight") {
                             if ($entryInfo.Checked -eq $true) {
                                 $sync[$entryInfo.Name].IsChecked = $true
                             }

                             $sync[$entryInfo.Name].Add_Checked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                             $sync[$entryInfo.Name].Add_Unchecked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                        } else {
                            $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                            $sync[$entryInfo.Name].Add_Checked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                                # Skip applying tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtilTweaks $Sender.name
                                }
                            })

                            $sync[$entryInfo.Name].Add_Unchecked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                                # Skip undoing tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtiltweaks $Sender.name -undo $true
                                }
                            })
                        }
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkbox $Sender.name
                        })
                    }
                }
            }
        }
    }
}
function Invoke-WPFUIThread {
    <#

    .SYNOPSIS
        Creates and runs a task on Winutil's WPF Forms thread.

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the thread
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock
    )

    if ($PARAM_NOUI) {
        return;
    }

    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}
function Invoke-WPFUltimatePerformance {
    param(
        [switch]$Do
    )

    if ($Do) {
        if (-not (powercfg /list | Select-String "WinRUtil - Ultimate Power Plan")) {
            if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                powercfg /restoredefaultschemes
                if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                    Write-Host "Failed to restore High Performance plan. Default plans do not include high performance. If you are on a laptop, do NOT use High Performance or Ultimate Performance plans." -ForegroundColor Red
                    return
                }
            }
            $guid = ((powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) -split '\s+')[3]
            powercfg /changename $guid "WinRUtil - Ultimate Power Plan"
            powercfg /setacvalueindex $guid SUB_PROCESSOR IDLEDISABLE 1
            powercfg /setacvalueindex $guid 54533251-82be-4824-96c1-47b60b740d00 4d2b0152-7d5c-498b-88e2-34345392a2c5 1
            powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100
            powercfg /setactive $guid
            Write-Host "WinRUtil - Ultimate Power Plan plan installed and activated." -ForegroundColor Green
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is already installed." -ForegroundColor Red
            return
        }
    } else {
        if (powercfg /list | Select-String "WinRUtil - Ultimate Power Plan") {
            powercfg /setactive SCHEME_BALANCED
            powercfg /delete ((powercfg /list | Select-String "WinRUtil - Ultimate Power Plan").ToString().Split()[3])
            Write-Host "WinRUtil - Ultimate Power Plan plan was removed." -ForegroundColor Red
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is not installed." -ForegroundColor Yellow
        }
    }
}
function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] Install process is currently running."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilProgressBar -Label "Undoing $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilProgressBar -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="

    }
}
function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        [System.Windows.MessageBox]::Show($WarningMsg, $AppTitle, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "Uninstalling apps..."

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
           Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False

    }
}
function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Removing Windows Update policy settings..." -ForegroundColor Green

    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic"
    Start-Service -Name UsoSvc
    Set-Service -Name UsoSvc -StartupType Automatic

    Write-Host "Restored WaaSMedicSvc to Manual"
    Set-Service -Name WaaSMedicSvc -StartupType Manual

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Windows Local Policies Reset to Default"
    secedit /configure /cfg "$Env:SystemRoot\inf\defltbase.inf" /db defltbase.sdb

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
}
function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    Write-Host "Disabled BITS Service"
    Set-Service -Name BITS -StartupType Disabled

    Write-Host "Disabled wuauserv Service"
    Set-Service -Name wuauserv -StartupType Disabled

    Write-Host "Disabled UsoSvc Service"
    Stop-Service -Name UsoSvc -Force
    Set-Service -Name UsoSvc -StartupType Disabled

    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force
    Write-Host "Cleared SoftwareDistribution folder"

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "---   Updates Are Disabled    ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
}
function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>

    Write-Host "Disabling driver offering through Windows Update..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Setting cumulative updates back by 1 year and security updates by 4 days"

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    Write-Host "Disabling Windows Update automatic restart..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
}
function Write-WinUtilWifiLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Wi-Fi tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFWifiStatusLog
    if (-not $logBox) {
        Write-Host $line
        return
    }

    $action = {
        if ([string]::IsNullOrWhiteSpace($logBox.Text) -or $logBox.Text -like "Pronto.*") {
            $logBox.Text = $line
        } else {
            $logBox.AppendText("`r`n$line")
        }
        $logBox.ScrollToEnd()
    }

    if ($logBox.Dispatcher.CheckAccess()) {
        & $action
    } else {
        $logBox.Dispatcher.Invoke($action)
    }
}

function Get-WinRUtilWifiProfiles {
    <#
    .SYNOPSIS
        Lists saved Wi-Fi profiles (SSID, plaintext password, security type, autoconnect).
    .DESCRIPTION
        Locale independent: exports every WLAN profile to XML via
        "netsh wlan export profile key=clear" and parses the XML elements
        (name, authentication, keyMaterial, connectionMode) instead of reading
        the localized console output of "netsh wlan show profile ... key=clear".
        Works on Windows PowerShell 5.1+ and PowerShell 7. ASCII-only source.
    .OUTPUTS
        Array of [PSCustomObject] with properties: Ssid, Password, Security, AutoConnect.
    #>
    [CmdletBinding()]
    param()

    # Unique temp working folder; removed in finally.
    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    $results = New-Object System.Collections.Generic.List[object]
    $skipped = 0

    try {
        # Bail out gracefully if the WLAN AutoConfig service is not running.
        $svc = Get-Service -Name 'Wlansvc' -ErrorAction SilentlyContinue
        if ($null -eq $svc -or $svc.Status -ne 'Running') {
            return @()
        }

        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null

        # Export ALL profiles at once with cleartext keys. Names with spaces /
        # special chars are handled by netsh; SSIDs are read from the XML below,
        # never from the (mangled, locale-affected) file names.
        $null = netsh wlan export profile key=clear folder="$work" 2>&1

        $xmlFiles = @(Get-ChildItem -Path $work -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($xmlFiles.Count -eq 0) {
            return @()
        }

        foreach ($file in $xmlFiles) {
            try {
                # Read raw text first; used both for XML load and regex fallback.
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

                $ssid          = $null
                $authentication = $null
                $keyMaterial    = $null
                $hasKeyElement  = $false
                $connectionMode = $null

                # Primary path: parse as XML using namespace-agnostic local-name()
                # XPath so the default v1 namespace (and nested v3/v4) do not matter.
                $parsedXml = $false
                try {
                    $doc = New-Object System.Xml.XmlDocument
                    $doc.PreserveWhitespace = $false
                    $doc.LoadXml($raw)

                    $nameNode = $doc.SelectSingleNode("//*[local-name()='WLANProfile']/*[local-name()='name']")
                    if ($null -eq $nameNode) {
                        $nameNode = $doc.SelectSingleNode("//*[local-name()='name']")
                    }
                    if ($nameNode) { $ssid = $nameNode.InnerText }

                    $authNode = $doc.SelectSingleNode("//*[local-name()='authentication']")
                    if ($authNode) { $authentication = $authNode.InnerText }

                    $keyNode = $doc.SelectSingleNode("//*[local-name()='keyMaterial']")
                    if ($keyNode) {
                        $hasKeyElement = $true
                        $keyMaterial = $keyNode.InnerText
                    }

                    $cmNode = $doc.SelectSingleNode("//*[local-name()='connectionMode']")
                    if ($cmNode) { $connectionMode = $cmNode.InnerText }

                    # transitionMode (WPA2<->WPA3 mixed) lives in the v4 namespace.
                    $transNode = $doc.SelectSingleNode("//*[local-name()='transitionMode']")
                    $transitionMode = $false
                    if ($transNode -and $transNode.InnerText -match '^(true|1)$') {
                        $transitionMode = $true
                    }

                    $parsedXml = $true
                }
                catch {
                    $parsedXml = $false
                }

                # Robust fallback: regex the inner text of the elements if XML
                # parsing failed for any reason (e.g. unexpected encoding).
                if (-not $parsedXml) {
                    $transitionMode = $false
                    if ($raw -match '(?s)<name>(.*?)</name>') { $ssid = $matches[1] }
                    if ($raw -match '(?s)<authentication>(.*?)</authentication>') { $authentication = $matches[1] }
                    if ($raw -match '(?s)<keyMaterial>(.*?)</keyMaterial>') {
                        $hasKeyElement = $true
                        $keyMaterial = $matches[1]
                    }
                    if ($raw -match '(?s)<connectionMode>(.*?)</connectionMode>') { $connectionMode = $matches[1] }
                    if ($raw -match '(?s)<transitionMode[^>]*>(.*?)</transitionMode>') {
                        if ($matches[1] -match '^(true|1)$') { $transitionMode = $true }
                    }
                    # Decode the handful of XML entities that appear in SSIDs.
                    if ($null -ne $ssid) {
                        $ssid = $ssid -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&apos;', "'"
                    }
                }

                if ([string]::IsNullOrEmpty($ssid)) {
                    $skipped++
                    continue
                }

                # Normalize values.
                if ($null -eq $authentication) { $authentication = '' }
                $authUpper = $authentication.ToUpperInvariant()

                # Password: empty string for open networks (no keyMaterial element).
                if (-not $hasKeyElement -or $null -eq $keyMaterial) {
                    $password = ''
                }
                else {
                    $password = $keyMaterial
                }

                # AutoConnect: Italian Si / No based on connectionMode.
                if ($connectionMode -and $connectionMode.Trim().ToLowerInvariant() -eq 'auto') {
                    $autoConnect = 'Si'
                }
                else {
                    $autoConnect = 'No'
                }

                # Map the raw authentication token to a human-readable label.
                $security = switch -Regex ($authUpper) {
                    '^OPEN$'        { 'Aperta'; break }
                    '^SHARED$'      { 'WEP'; break }            # legacy shared-key WEP
                    '^WPA3SAE$'     { if ($transitionMode) { 'WPA2/WPA3' } else { 'WPA3-SAE' }; break }
                    '^WPA3ENT.*'    { 'WPA3-Enterprise'; break }
                    '^WPA3$'        { 'WPA3-Enterprise'; break }
                    '^WPA2PSK$'     { 'WPA2-Personal'; break }
                    '^WPA2$'        { 'WPA2-Enterprise'; break }
                    '^WPAPSK$'      { 'WPA-Personal'; break }
                    '^WPA$'         { 'WPA-Enterprise'; break }
                    'OWE'           { 'OWE'; break }            # Enhanced Open
                    default {
                        if ([string]::IsNullOrEmpty($authentication)) {
                            if ($hasKeyElement) { 'Sconosciuta' } else { 'Aperta' }
                        }
                        else {
                            $authentication
                        }
                    }
                }

                # If there is genuinely no key element and auth says open, force Aperta.
                if (-not $hasKeyElement -and ($authUpper -eq 'OPEN' -or $authUpper -eq '')) {
                    $security = 'Aperta'
                    $password = ''
                }

                $results.Add([PSCustomObject]@{
                    Ssid        = $ssid
                    Password    = $password
                    Security    = $security
                    AutoConnect = $autoConnect
                })
            }
            catch {
                $skipped++
                continue
            }
        }
    }
    catch {
        # Any unexpected failure: return whatever we have (possibly empty), never throw.
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($skipped -gt 0) {
        Write-Verbose ("Get-WinRUtilWifiProfiles: skipped {0} profile(s) that failed to parse." -f $skipped)
    }

    # Sort by Ssid and always return an array.
    return @($results | Sort-Object -Property Ssid)
}

function Invoke-WPFWifiRefresh {
    <#
        .SYNOPSIS
            Scans saved Wi-Fi networks and fills the Wi-Fi DataGrid (SSID, password, security, autoconnect).
    #>
    Write-WinUtilWifiLog "Scansione delle reti Wi-Fi salvate..."
    try {
        $profiles = @(Get-WinRUtilWifiProfiles)
        $sync.WPFWifiList.ItemsSource = $profiles
        $withPwd = @($profiles | Where-Object { $_.Password -ne "" }).Count
        Write-WinUtilWifiLog ("Trovate {0} rete/i Wi-Fi ({1} con password)." -f $profiles.Count, $withPwd) -Level Success
    } catch {
        Write-WinUtilWifiLog "Impossibile leggere le reti Wi-Fi: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFWifiCopyAll {
    <#
        .SYNOPSIS
            Copies all scanned Wi-Fi networks (SSID, password, security) to the clipboard as tab-separated text.
    #>
    $items = @($sync.WPFWifiList.ItemsSource)
    if ($items.Count -eq 0) {
        Write-WinUtilWifiLog "Nessuna rete da copiare. Esegui prima una scansione." -Level Warning
        return
    }

    $lines = foreach ($it in $items) {
        "{0}`t{1}`t{2}" -f $it.Ssid, $it.Password, $it.Security
    }
    $text = "SSID`tPassword`tSicurezza`r`n" + ($lines -join "`r`n")

    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        Write-WinUtilWifiLog ("Copiate {0} rete/i negli appunti." -f $items.Count) -Level Success
    } catch {
        Write-WinUtilWifiLog "Copia negli appunti non riuscita: $($_.Exception.Message)" -Level Error
    }
}
Function Show-WinRUtilLogo {
    <#
        .SYNOPSIS
            Displays the WinRUtil logo in ASCII art.
        .DESCRIPTION
            Prints the WinRUtil banner with a green gradient based on the
            project's #3DF5A0 accent color when the console supports ANSI
            escape sequences (Windows Terminal, PowerShell 7+), falling back
            to standard console colors elsewhere.
        .EXAMPLE
            Show-WinRUtilLogo
    #>

    $logo = @(
        '██╗    ██╗██╗███╗   ██╗██████╗ ██╗   ██╗████████╗██╗██╗'
        '██║    ██║██║████╗  ██║██╔══██╗██║   ██║╚══██╔══╝██║██║'
        '██║ █╗ ██║██║██╔██╗ ██║██████╔╝██║   ██║   ██║   ██║██║'
        '██║███╗██║██║██║╚██╗██║██╔══██╗██║   ██║   ██║   ██║██║'
        '╚███╔███╔╝██║██║ ╚████║██║  ██║╚██████╔╝   ██║   ██║███████╗'
        ' ╚══╝╚══╝ ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚══════╝'
    )

    $width = 60
    $tagline = 'WinRUtil  •  Windows Toolkit'
    if ($sync.version) { $tagline += "  •  v$($sync.version)" }
    $rule = [string][char]0x2500 * $width
    $centered = (' ' * [math]::Max(0, [math]::Floor(($width - $tagline.Length) / 2))) + $tagline

    $supportsAnsi = ($null -ne $env:WT_SESSION) -or
                    ($PSVersionTable.PSVersion.Major -ge 7) -or
                    ($Host.UI.PSObject.Properties['SupportsVirtualTerminal'] -and $Host.UI.SupportsVirtualTerminal)

    Write-Host ''
    if ($supportsAnsi) {
        $esc = [char]27
        # Gradient: theme accent #3DF5A0 (top) -> darker green #1EA86C (bottom)
        $gradient = @('61;245;160', '55;230;150', '49;214;139', '42;199;129', '36;183;119', '30;168;108')
        for ($i = 0; $i -lt $logo.Count; $i++) {
            Write-Host "$esc[1m$esc[38;2;$($gradient[$i])m$($logo[$i])$esc[0m"
        }
        # Rules use the theme's secondary green #2BD389
        Write-Host "$esc[38;2;43;211;137m$rule$esc[0m"
        Write-Host "$esc[1m$esc[97m$centered$esc[0m"
        Write-Host "$esc[38;2;43;211;137m$rule$esc[0m"
    } else {
        foreach ($line in $logo) { Write-Host $line -ForegroundColor Green }
        Write-Host $rule -ForegroundColor DarkGreen
        Write-Host $centered -ForegroundColor White
        Write-Host $rule -ForegroundColor DarkGreen
    }
    Write-Host ''
}
$sync.configs.applications = @'
{
    "WPFInstall1password":  {
                                "category":  "Utilities",
                                "choco":  "1password",
                                "content":  "1Password",
                                "description":  "1Password is a password manager that allows you to store and manage your passwords securely.",
                                "link":  "https://1password.com/",
                                "winget":  "AgileBits.1Password",
                                "foss":  false
                            },
    "WPFInstall7zip":  {
                           "category":  "Utilities",
                           "choco":  "7zip",
                           "content":  "7-Zip",
                           "description":  "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
                           "link":  "https://www.7-zip.org/",
                           "winget":  "7zip.7zip",
                           "foss":  true
                       },
    "WPFInstalladobe":  {
                            "category":  "Multimedia Tools",
                            "choco":  "adobereader",
                            "content":  "Adobe Acrobat Reader",
                            "description":  "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
                            "link":  "https://www.adobe.com/acrobat/pdf-reader.html",
                            "winget":  "Adobe.Acrobat.Reader.64-bit",
                            "foss":  false
                        },
    "WPFInstalladvancedip":  {
                                 "category":  "Pro Tools",
                                 "choco":  "advanced-ip-scanner",
                                 "content":  "Advanced IP Scanner",
                                 "description":  "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
                                 "link":  "https://www.advanced-ip-scanner.com/",
                                 "winget":  "Famatech.AdvancedIPScanner",
                                 "foss":  false
                             },
    "WPFInstallaimp":  {
                           "category":  "Multimedia Tools",
                           "choco":  "aimp",
                           "content":  "AIMP (Music Player)",
                           "description":  "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
                           "link":  "https://www.aimp.ru/",
                           "winget":  "AIMP.AIMP",
                           "foss":  false
                       },
    "WPFInstallangryipscanner":  {
                                     "category":  "Pro Tools",
                                     "choco":  "angryip",
                                     "content":  "Angry IP Scanner",
                                     "description":  "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
                                     "link":  "https://angryip.org/",
                                     "winget":  "angryziber.AngryIPScanner",
                                     "foss":  true
                                 },
    "WPFInstallanydesk":  {
                              "category":  "Utilities",
                              "choco":  "anydesk",
                              "content":  "AnyDesk",
                              "description":  "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
                              "link":  "https://anydesk.com/",
                              "winget":  "AnyDesk.AnyDesk",
                              "foss":  false
                          },
    "WPFInstallaudacity":  {
                               "category":  "Multimedia Tools",
                               "choco":  "audacity",
                               "content":  "Audacity",
                               "description":  "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
                               "link":  "https://www.audacityteam.org/",
                               "winget":  "Audacity.Audacity",
                               "foss":  true
                           },
    "WPFInstallautoruns":  {
                               "category":  "Microsoft Tools",
                               "choco":  "autoruns",
                               "content":  "Autoruns",
                               "description":  "This utility shows you what programs are configured to run during system bootup or login.",
                               "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
                               "winget":  "Microsoft.Sysinternals.Autoruns",
                               "foss":  false
                           },
    "WPFInstallrdcman":  {
                             "category":  "Microsoft Tools",
                             "choco":  "rdcman",
                             "content":  "RDCMan",
                             "description":  "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
                             "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
                             "winget":  "Microsoft.Sysinternals.RDCMan",
                             "foss":  false
                         },
    "WPFInstallautohotkey":  {
                                 "category":  "Utilities",
                                 "choco":  "autohotkey",
                                 "content":  "AutoHotkey",
                                 "description":  "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
                                 "link":  "https://www.autohotkey.com/",
                                 "winget":  "AutoHotkey.AutoHotkey",
                                 "foss":  true
                             },
    "WPFInstallbitwarden":  {
                                "category":  "Utilities",
                                "choco":  "bitwarden",
                                "content":  "Bitwarden",
                                "description":  "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
                                "link":  "https://bitwarden.com/",
                                "winget":  "Bitwarden.Bitwarden",
                                "foss":  true
                            },
    "WPFInstallblender":  {
                              "category":  "Multimedia Tools",
                              "choco":  "blender",
                              "content":  "Blender (3D Graphics)",
                              "description":  "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
                              "link":  "https://www.blender.org/",
                              "winget":  "BlenderFoundation.Blender",
                              "foss":  true
                          },
    "WPFInstallbrave":  {
                            "category":  "Browsers",
                            "choco":  "brave",
                            "content":  "Brave",
                            "description":  "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
                            "link":  "https://www.brave.com",
                            "winget":  "Brave.Brave",
                            "foss":  true
                        },
    "WPFInstallbulkcrapuninstaller":  {
                                          "category":  "Utilities",
                                          "choco":  "bulk-crap-uninstaller",
                                          "content":  "Bulk Crap Uninstaller",
                                          "description":  "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
                                          "link":  "https://www.bcuninstaller.com/",
                                          "winget":  "Klocman.BulkCrapUninstaller",
                                          "foss":  true
                                      },
    "WPFInstallblurautoclicker":  {
                                      "category":  "Utilities",
                                      "choco":  "na",
                                      "content":  "BlurAutoClicker",
                                      "description":  "An Auto-clicker with a few advanced features and generally better performance than popular alternatives.",
                                      "link":  "https://blur009.vercel.app/projects/blur-autoclicker/",
                                      "winget":  "Blur009.BlurAutoClicker",
                                      "foss":  true
                                  },
    "WPFInstallcalibre":  {
                              "category":  "Multimedia Tools",
                              "choco":  "calibre",
                              "content":  "Calibre",
                              "description":  "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
                              "link":  "https://calibre-ebook.com/",
                              "winget":  "calibre.calibre",
                              "foss":  true
                          },
    "WPFInstallcemu":  {
                           "category":  "Games",
                           "choco":  "cemu",
                           "content":  "Cemu",
                           "description":  "Cemu is a highly experimental software to emulate Wii U applications on PC.",
                           "link":  "https://cemu.info/",
                           "winget":  "Cemu.Cemu",
                           "foss":  true
                       },
    "WPFInstallchatterino":  {
                                 "category":  "Communications",
                                 "choco":  "chatterino",
                                 "content":  "Chatterino",
                                 "description":  "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
                                 "link":  "https://www.chatterino.com/",
                                 "winget":  "ChatterinoTeam.Chatterino",
                                 "foss":  true
                             },
    "WPFInstallchrome":  {
                             "category":  "Browsers",
                             "choco":  "googlechrome",
                             "content":  "Chrome",
                             "description":  "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
                             "link":  "https://www.google.com/chrome/",
                             "winget":  "Google.Chrome",
                             "foss":  false
                         },
    "WPFInstallchromium":  {
                               "category":  "Browsers",
                               "choco":  "chromium",
                               "content":  "Chromium",
                               "description":  "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
                               "link":  "https://github.com/Hibbiki/chromium-win64",
                               "winget":  "Hibbiki.Chromium",
                               "foss":  true
                           },
    "WPFInstallcmake":  {
                            "category":  "Development",
                            "choco":  "cmake",
                            "content":  "CMake",
                            "description":  "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
                            "link":  "https://cmake.org/",
                            "winget":  "Kitware.CMake",
                            "foss":  true
                        },
    "WPFInstallcpuz":  {
                           "category":  "Pro Tools",
                           "choco":  "cpu-z",
                           "content":  "CPU-Z",
                           "description":  "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer\u0027s hardware components, including the CPU, memory, and motherboard.",
                           "link":  "https://www.cpuid.com/softwares/cpu-z.html",
                           "winget":  "CPUID.CPU-Z",
                           "foss":  false
                       },
    "WPFInstallcrystaldiskinfo":  {
                                      "category":  "Utilities",
                                      "choco":  "crystaldiskinfo",
                                      "content":  "Crystal Disk Info",
                                      "description":  "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskinfo/",
                                      "winget":  "CrystalDewWorld.CrystalDiskInfo",
                                      "foss":  true
                                  },
    "WPFInstallcrystaldiskmark":  {
                                      "category":  "Utilities",
                                      "choco":  "crystaldiskmark",
                                      "content":  "Crystal Disk Mark",
                                      "description":  "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskmark/",
                                      "winget":  "CrystalDewWorld.CrystalDiskMark",
                                      "foss":  true
                                  },
    "WPFInstallcursor":  {
                             "category":  "Development",
                             "choco":  "cursoride",
                             "content":  "Cursor",
                             "description":  "AI-powered code editor (VS Code-based) with agentic coding features and integrated AI assistance for development workflows.",
                             "link":  "https://cursor.com/",
                             "winget":  "Anysphere.Cursor",
                             "foss":  false
                         },
    "WPFInstallddu":  {
                          "category":  "Pro Tools",
                          "choco":  "ddu",
                          "content":  "Display Driver Uninstaller",
                          "description":  "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
                          "link":  "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
                          "winget":  "Wagnardsoft.DisplayDriverUninstaller",
                          "foss":  true
                      },
    "WPFInstalldiscord":  {
                              "category":  "Communications",
                              "choco":  "discord",
                              "content":  "Discord",
                              "description":  "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
                              "link":  "https://discord.com/",
                              "winget":  "Discord.Discord",
                              "foss":  false
                          },
    "WPFInstalldismtools":  {
                                "category":  "Microsoft Tools",
                                "choco":  "dismtools",
                                "content":  "DISMTools",
                                "description":  "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
                                "link":  "https://github.com/CodingWonders/DISMTools",
                                "winget":  "CodingWondersSoftware.DISMTools.Stable",
                                "foss":  true
                            },
    "WPFInstallntlite":  {
                             "category":  "Microsoft Tools",
                             "choco":  "ntlite-free",
                             "content":  "NTLite",
                             "description":  "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
                             "link":  "https://ntlite.com",
                             "winget":  "Nlitesoft.NTLite",
                             "foss":  false
                         },
    "WPFInstalldorion":  {
                             "category":  "Communications",
                             "choco":  "dorion",
                             "content":  "Dorion",
                             "description":  "Tiny alternative Discord client with a smaller footprint, snappier startup, themes, plugins and more!",
                             "link":  "https://github.com/SpikeHD/Dorion",
                             "winget":  "SpikeHD.Dorion",
                             "foss":  true
                         },
    "WPFInstalldotnet6":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-6.0-runtime",
                              "content":  ".NET Desktop Runtime 6",
                              "description":  ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/6.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.6",
                              "foss":  true
                          },
    "WPFInstalldotnet8":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-8.0-runtime",
                              "content":  ".NET Desktop Runtime 8",
                              "description":  ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/8.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.8",
                              "foss":  true
                          },
    "WPFInstalldotnet9":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-9.0-runtime",
                              "content":  ".NET Desktop Runtime 9",
                              "description":  ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/9.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.9",
                              "foss":  true
                          },
    "WPFInstalldotnet10":  {
                               "category":  "Microsoft Tools",
                               "choco":  "dotnet-10.0-runtime",
                               "content":  ".NET Desktop Runtime 10",
                               "description":  ".NET Desktop Runtime 10 is a runtime environment required for running applications developed with .NET 10.",
                               "link":  "https://dotnet.microsoft.com/download/dotnet/10.0",
                               "winget":  "Microsoft.DotNet.DesktopRuntime.10",
                               "foss":  true
                           },
    "WPFInstalleaapp":  {
                            "category":  "Games",
                            "choco":  "ea-app",
                            "content":  "EA App",
                            "description":  "EA App is a platform for accessing and playing Electronic Arts games.",
                            "link":  "https://www.ea.com/ea-app",
                            "winget":  "ElectronicArts.EADesktop",
                            "foss":  false
                        },
    "WPFInstalleartrumpet":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "eartrumpet",
                                 "content":  "EarTrumpet (Audio)",
                                 "description":  "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
                                 "link":  "https://eartrumpet.app/",
                                 "winget":  "File-New-Project.EarTrumpet",
                                 "foss":  true
                             },
    "WPFInstalledge":  {
                           "category":  "Browsers",
                           "choco":  "microsoft-edge",
                           "content":  "Edge",
                           "description":  "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
                           "link":  "https://www.microsoft.com/edge",
                           "winget":  "Microsoft.Edge",
                           "foss":  false
                       },
    "WPFInstallenteauth":  {
                               "category":  "Utilities",
                               "choco":  "ente-auth",
                               "content":  "Ente Auth",
                               "description":  "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
                               "link":  "https://ente.io/auth/",
                               "winget":  "ente-io.auth-desktop",
                               "foss":  true
                           },
    "WPFInstallepicgames":  {
                                "category":  "Games",
                                "choco":  "epicgameslauncher",
                                "content":  "Epic Games Launcher",
                                "description":  "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
                                "link":  "https://www.epicgames.com/store/en-US/",
                                "winget":  "EpicGames.EpicGamesLauncher",
                                "foss":  false
                            },
    "WPFInstallfiles":  {
                            "category":  "Utilities",
                            "choco":  "files",
                            "content":  "Files",
                            "description":  "Alternative file explorer.",
                            "link":  "https://github.com/files-community/Files",
                            "winget":  "FilesCommunity.Files",
                            "foss":  true
                        },
    "WPFInstallfirefox":  {
                              "category":  "Browsers",
                              "choco":  "firefox",
                              "content":  "Firefox",
                              "description":  "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
                              "link":  "https://www.mozilla.org/en-US/firefox/new/",
                              "winget":  "Mozilla.Firefox",
                              "foss":  true
                          },
    "WPFInstallfirefoxesr":  {
                                 "category":  "Browsers",
                                 "choco":  "FirefoxESR",
                                 "content":  "Firefox ESR",
                                 "description":  "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
                                 "link":  "https://www.mozilla.org/en-US/firefox/enterprise/",
                                 "winget":  "Mozilla.Firefox.ESR",
                                 "foss":  true
                             },
    "WPFInstallfloorp":  {
                             "category":  "Browsers",
                             "choco":  "floorp",
                             "content":  "Floorp",
                             "description":  "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
                             "link":  "https://floorp.app/",
                             "winget":  "Ablaze.Floorp",
                             "foss":  true
                         },
    "WPFInstallflux":  {
                           "category":  "Utilities",
                           "choco":  "flux",
                           "content":  "F.lux",
                           "description":  "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
                           "link":  "https://justgetflux.com/",
                           "winget":  "flux.flux",
                           "foss":  false
                       },
    "WPFInstallgeforcenow":  {
                                 "category":  "Games",
                                 "choco":  "nvidia-geforce-now",
                                 "content":  "GeForce NOW",
                                 "description":  "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
                                 "link":  "https://www.nvidia.com/en-us/geforce-now/",
                                 "winget":  "Nvidia.GeForceNow",
                                 "foss":  false
                             },
    "WPFInstallgimp":  {
                           "category":  "Multimedia Tools",
                           "choco":  "gimp",
                           "content":  "GIMP (Image Editor)",
                           "description":  "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
                           "link":  "https://www.gimp.org/",
                           "winget":  "GIMP.GIMP.3",
                           "foss":  true
                       },
    "WPFInstallgit":  {
                          "category":  "Development",
                          "choco":  "git",
                          "content":  "Git",
                          "description":  "Git is a distributed version control system widely used for tracking changes in source code during software development.",
                          "link":  "https://git-scm.com/",
                          "winget":  "Git.Git",
                          "foss":  true
                      },
    "WPFInstallgithubdesktop":  {
                                    "category":  "Development",
                                    "choco":  "git;github-desktop",
                                    "content":  "GitHub Desktop",
                                    "description":  "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
                                    "link":  "https://desktop.github.com/",
                                    "winget":  "GitHub.GitHubDesktop",
                                    "foss":  true
                                },
    "WPFInstallgog":  {
                          "category":  "Games",
                          "choco":  "goggalaxy",
                          "content":  "GOG Galaxy",
                          "description":  "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
                          "link":  "https://www.gog.com/galaxy",
                          "winget":  "GOG.Galaxy",
                          "foss":  false
                      },
    "WPFInstallgolang":  {
                             "category":  "Development",
                             "choco":  "golang",
                             "content":  "Go",
                             "description":  "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
                             "link":  "https://go.dev/",
                             "winget":  "GoLang.Go",
                             "foss":  true
                         },
    "WPFInstallgoogledrive":  {
                                  "category":  "Utilities",
                                  "choco":  "googledrive",
                                  "content":  "Google Drive",
                                  "description":  "File syncing across devices all tied to your Google account.",
                                  "link":  "https://www.google.com/drive/",
                                  "winget":  "Google.GoogleDrive",
                                  "foss":  false
                              },
    "WPFInstallgpuz":  {
                           "category":  "Pro Tools",
                           "choco":  "gpu-z",
                           "content":  "GPU-Z",
                           "description":  "GPU-Z provides detailed information about your graphics card and GPU.",
                           "link":  "https://www.techpowerup.com/gpuz/",
                           "winget":  "TechPowerUp.GPU-Z",
                           "foss":  false
                       },
    "WPFInstallhelium":  {
                             "category":  "Browsers",
                             "choco":  "helium",
                             "content":  "Helium",
                             "description":  "Private, fast, and honest web browser.",
                             "link":  "https://github.com/imputnet/helium/",
                             "winget":  "ImputNet.Helium",
                             "foss":  true
                         },
    "WPFInstallhugo":  {
                           "category":  "Utilities",
                           "choco":  "hugo-extended",
                           "content":  "Hugo",
                           "description":  "The world\u0027s fastest framework for building websites.",
                           "link":  "https://github.com/gohugoio/hugo/",
                           "winget":  "Hugo.Hugo.Extended",
                           "foss":  true
                       },
    "WPFInstallhandbrake":  {
                                "category":  "Multimedia Tools",
                                "choco":  "handbrake",
                                "content":  "HandBrake",
                                "description":  "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
                                "link":  "https://handbrake.fr/",
                                "winget":  "HandBrake.HandBrake",
                                "foss":  true
                            },
    "WPFInstallheroiclauncher":  {
                                     "category":  "Games",
                                     "choco":  "na",
                                     "content":  "Heroic Games Launcher",
                                     "description":  "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
                                     "link":  "https://heroicgameslauncher.com/",
                                     "winget":  "HeroicGamesLauncher.HeroicGamesLauncher",
                                     "foss":  true
                                 },
    "WPFInstallhwinfo":  {
                             "category":  "Pro Tools",
                             "choco":  "hwinfo",
                             "content":  "HWiNFO",
                             "description":  "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
                             "link":  "https://www.hwinfo.com/",
                             "winget":  "REALiX.HWiNFO",
                             "foss":  false
                         },
    "WPFInstallhwmonitor":  {
                                "category":  "Pro Tools",
                                "choco":  "hwmonitor",
                                "content":  "HWMonitor",
                                "description":  "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
                                "link":  "https://www.cpuid.com/softwares/hwmonitor.html",
                                "winget":  "CPUID.HWMonitor",
                                "foss":  false
                            },
    "WPFInstallimageglass":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "imageglass",
                                 "content":  "ImageGlass (Image Viewer)",
                                 "description":  "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
                                 "link":  "https://imageglass.org/",
                                 "winget":  "DuongDieuPhap.ImageGlass",
                                 "foss":  true
                             },
    "WPFInstallirfanview":  {
                                "category":  "Multimedia Tools",
                                "choco":  "irfanview",
                                "content":  "IrfanView",
                                "description":  "IrfanView is a lightweight, fast, and free image viewer and editor. Supports multiple formats, batch processing, and powerful plugins.",
                                "link":  "https://irfanview.com/",
                                "winget":  "IrfanSkiljan.IrfanView"
                            },
    "WPFInstallitch":  {
                           "category":  "Games",
                           "choco":  "itch",
                           "content":  "Itch.io",
                           "description":  "Itch.io is a digital distribution platform for indie games and creative projects.",
                           "link":  "https://itch.io/",
                           "winget":  "ItchIo.Itch",
                           "foss":  true
                       },
    "WPFInstallitunes":  {
                             "category":  "Multimedia Tools",
                             "choco":  "itunes",
                             "content":  "iTunes",
                             "description":  "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
                             "link":  "https://www.apple.com/itunes/",
                             "winget":  "Apple.iTunes",
                             "foss":  false
                         },
    "WPFInstalljava8":  {
                            "category":  "Development",
                            "choco":  "corretto8jdk",
                            "content":  "Amazon Corretto 8 (LTS)",
                            "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                            "link":  "https://aws.amazon.com/corretto",
                            "winget":  "Amazon.Corretto.8.JDK",
                            "foss":  true
                        },
    "WPFInstalljava21":  {
                             "category":  "Development",
                             "choco":  "corretto21jdk",
                             "content":  "Amazon Corretto 21 (LTS)",
                             "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.21.JDK",
                             "foss":  true
                         },
    "WPFInstalljava25":  {
                             "category":  "Development",
                             "choco":  "corretto25jdk",
                             "content":  "Amazon Corretto 25 (LTS)",
                             "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.25.JDK",
                             "foss":  true
                         },
    "WPFInstalljellyfinmediaplayer":  {
                                          "category":  "Selfhosted Tools",
                                          "choco":  "jellyfin-media-player",
                                          "content":  "Jellyfin Media Player",
                                          "description":  "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
                                          "link":  "https://github.com/jellyfin/jellyfin-media-player",
                                          "winget":  "Jellyfin.JellyfinMediaPlayer",
                                          "foss":  true
                                      },
    "WPFInstalljellyfinserver":  {
                                     "category":  "Selfhosted Tools",
                                     "choco":  "jellyfin",
                                     "content":  "Jellyfin Server",
                                     "description":  "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
                                     "link":  "https://jellyfin.org/",
                                     "winget":  "Jellyfin.Server",
                                     "foss":  true
                                 },
    "WPFInstalljetbrains":  {
                                "category":  "Development",
                                "choco":  "jetbrainstoolbox",
                                "content":  "Jetbrains Toolbox",
                                "description":  "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
                                "link":  "https://www.jetbrains.com/toolbox/",
                                "winget":  "JetBrains.Toolbox",
                                "foss":  false
                            },
    "WPFInstalljpegview":  {
                               "category":  "Utilities",
                               "choco":  "jpegview",
                               "content":  "JPEG View",
                               "description":  "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF and TIFF images with a minimal GUI.",
                               "link":  "https://github.com/sylikc/jpegview",
                               "winget":  "sylikc.JPEGView",
                               "foss":  true
                           },
    "WPFInstallklite":  {
                            "category":  "Multimedia Tools",
                            "choco":  "k-litecodecpack-standard",
                            "content":  "K-Lite Codec Standard",
                            "description":  "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
                            "link":  "https://www.codecguide.com/",
                            "winget":  "CodecGuide.K-LiteCodecPack.Standard",
                            "foss":  false
                        },
    "WPFInstallkodi":  {
                           "category":  "Selfhosted Tools",
                           "choco":  "kodi",
                           "content":  "Kodi Media Center",
                           "description":  "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
                           "link":  "https://kodi.tv/",
                           "winget":  "XBMCFoundation.Kodi",
                           "foss":  true
                       },
    "WPFInstalllazygit":  {
                              "category":  "Development",
                              "choco":  "lazygit",
                              "content":  "Lazygit",
                              "description":  "Simple terminal UI for git commands.",
                              "link":  "https://github.com/jesseduffield/lazygit/",
                              "winget":  "JesseDuffield.lazygit",
                              "foss":  true
                          },
    "WPFInstalllibreoffice":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "libreoffice-fresh",
                                  "content":  "LibreOffice",
                                  "description":  "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
                                  "link":  "https://www.libreoffice.org/",
                                  "winget":  "TheDocumentFoundation.LibreOffice",
                                  "foss":  true
                              },
    "WPFInstalllibrewolf":  {
                                "category":  "Browsers",
                                "choco":  "librewolf",
                                "content":  "LibreWolf",
                                "description":  "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
                                "link":  "https://librewolf-community.gitlab.io/",
                                "winget":  "LibreWolf.LibreWolf",
                                "foss":  true
                            },
    "WPFInstalllocalsend":  {
                                "category":  "Selfhosted Tools",
                                "choco":  "localsend.install",
                                "content":  "LocalSend",
                                "description":  "An open-source cross-platform alternative to AirDrop.",
                                "link":  "https://localsend.org/",
                                "winget":  "LocalSend.LocalSend",
                                "foss":  true
                            },
    "WPFInstallmpc-qt":  {
                             "category":  "Multimedia Tools",
                             "choco":  "mediainfo",
                             "content":  "mpc-qt",
                             "description":  "MPC-HC (Media Player Classic Home Cinema) is considered by many to be the quintessential media player for the Windows desktop. MPC-QT (Media Player Classic Qute Theater) aims to reproduce most of the interface and functionality of MPC-HC while using libmpv to play video instead of DirectShow.",
                             "link":  "https://github.com/mpc-qt/mpc-qt",
                             "winget":  "mpc-qt.mpc-qt",
                             "foss":  true
                         },
    "WPFInstallmatrix":  {
                             "category":  "Communications",
                             "choco":  "element-desktop",
                             "content":  "Element",
                             "description":  "Element is a client for Matrix; an open network for secure, decentralized communication.",
                             "link":  "https://element.io/",
                             "winget":  "Element.Element",
                             "foss":  true
                         },
    "WPFInstallmodrinth":  {
                               "category":  "Games",
                               "choco":  "na",
                               "content":  "Modrinth App",
                               "description":  "Modrinth App is a desktop application for managing Minecraft mods and modpacks.",
                               "link":  "https://modrinth.com/app",
                               "winget":  "Modrinth.ModrinthApp",
                               "foss":  true
                           },
    "WPFInstallmoonlight":  {
                                "category":  "Selfhosted Tools",
                                "choco":  "moonlight-qt",
                                "content":  "Moonlight/GameStream Client",
                                "description":  "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
                                "link":  "https://moonlight-stream.org/",
                                "winget":  "MoonlightGameStreamingProject.Moonlight",
                                "foss":  true
                            },
    "WPFInstallmpchc":  {
                            "category":  "Multimedia Tools",
                            "choco":  "mpc-hc-clsid2",
                            "content":  "Media Player Classic - Home Cinema",
                            "description":  "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
                            "link":  "https://github.com/clsid2/mpc-hc/",
                            "winget":  "clsid2.mpc-hc",
                            "foss":  true
                        },
    "WPFInstallmsedgeredirect":  {
                                     "category":  "Utilities",
                                     "choco":  "msedgeredirect",
                                     "content":  "MSEdgeRedirect",
                                     "description":  "A Tool to Redirect News, Search, Widgets, Weather, and More to your default browser.",
                                     "link":  "https://github.com/rcmaehl/MSEdgeRedirect",
                                     "winget":  "rcmaehl.MSEdgeRedirect",
                                     "foss":  true
                                 },
    "WPFInstallmsiafterburner":  {
                                     "category":  "Utilities",
                                     "choco":  "msiafterburner",
                                     "content":  "MSI Afterburner",
                                     "description":  "MSI Afterburner is a graphics card overclocking utility with advanced features.",
                                     "link":  "https://www.msi.com/Landing/afterburner",
                                     "winget":  "Guru3D.Afterburner",
                                     "foss":  false
                                 },
    "WPFInstallmullvadvpn":  {
                                 "category":  "Pro Tools",
                                 "choco":  "mullvad-app",
                                 "content":  "Mullvad VPN",
                                 "description":  "This is the VPN client software for the Mullvad VPN service.",
                                 "link":  "https://github.com/mullvad/mullvadvpn-app",
                                 "winget":  "MullvadVPN.MullvadVPN",
                                 "foss":  true
                             },
    "WPFInstallmullvadbrowser":  {
                                     "category":  "Browsers",
                                     "choco":  "na",
                                     "content":  "Mullvad Browser",
                                     "description":  "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
                                     "link":  "https://mullvad.net/browser",
                                     "winget":  "MullvadVPN.MullvadBrowser",
                                     "foss":  true
                                 },
    "WPFInstallnanazip":  {
                              "category":  "Utilities",
                              "choco":  "nanazip",
                              "content":  "NanaZip",
                              "description":  "NanaZip is a fast and efficient file compression and decompression tool.",
                              "link":  "https://github.com/M2Team/NanaZip",
                              "winget":  "M2Team.NanaZip",
                              "foss":  true
                          },
    "WPFInstallnetbird":  {
                              "category":  "Selfhosted Tools",
                              "choco":  "netbird",
                              "content":  "NetBird",
                              "description":  "NetBird is a open-source alternative comparable to TailScale that can be connected to a self-hosted server.",
                              "link":  "https://netbird.io/",
                              "winget":  "Netbird.Netbird",
                              "foss":  true
                          },
    "WPFInstallnaps2":  {
                            "category":  "Multimedia Tools",
                            "choco":  "naps2",
                            "content":  "NAPS2 (Document Scanner)",
                            "description":  "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
                            "link":  "https://www.naps2.com/",
                            "winget":  "Cyanfish.NAPS2",
                            "foss":  true
                        },
    "WPFInstallneovim":  {
                             "category":  "Development",
                             "choco":  "neovim",
                             "content":  "Neovim",
                             "description":  "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
                             "link":  "https://neovim.io/",
                             "winget":  "Neovim.Neovim",
                             "foss":  true
                         },
    "WPFInstallnextclouddesktop":  {
                                       "category":  "Selfhosted Tools",
                                       "choco":  "nextcloud-client",
                                       "content":  "Nextcloud Desktop",
                                       "description":  "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
                                       "link":  "https://nextcloud.com/install/#install-clients",
                                       "winget":  "Nextcloud.NextcloudDesktop",
                                       "foss":  true
                                   },
    "WPFInstallnmap":  {
                           "category":  "Pro Tools",
                           "choco":  "nmap",
                           "content":  "Nmap",
                           "description":  "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
                           "link":  "https://nmap.org/",
                           "winget":  "Insecure.Nmap",
                           "foss":  true
                       },
    "WPFInstallnodejs":  {
                             "category":  "Development",
                             "choco":  "nodejs",
                             "content":  "NodeJS",
                             "description":  "NodeJS is a JavaScript runtime built on Chrome\u0027s V8 JavaScript engine for building server-side and networking applications.",
                             "link":  "https://nodejs.org/",
                             "winget":  "OpenJS.NodeJS",
                             "foss":  true
                         },
    "WPFInstallnodejslts":  {
                                "category":  "Development",
                                "choco":  "nodejs-lts",
                                "content":  "NodeJS LTS",
                                "description":  "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
                                "link":  "https://nodejs.org/",
                                "winget":  "OpenJS.NodeJS.LTS",
                                "foss":  true
                            },
    "WPFInstallnotepadplus":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "notepadplusplus",
                                  "content":  "Notepad++",
                                  "description":  "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
                                  "link":  "https://notepad-plus-plus.org/",
                                  "winget":  "Notepad++.Notepad++",
                                  "foss":  true
                              },
    "WPFInstallnuget":  {
                            "category":  "Microsoft Tools",
                            "choco":  "nuget.commandline",
                            "content":  "NuGet",
                            "description":  "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
                            "link":  "https://www.nuget.org/",
                            "winget":  "Microsoft.NuGet",
                            "foss":  true
                        },
    "WPFInstallnvclean":  {
                              "category":  "Utilities",
                              "choco":  "na",
                              "content":  "NVCleanstall",
                              "description":  "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
                              "link":  "https://www.techpowerup.com/nvcleanstall/",
                              "winget":  "TechPowerUp.NVCleanstall",
                              "foss":  false
                          },
    "WPFInstallobs":  {
                          "category":  "Multimedia Tools",
                          "choco":  "obs-studio",
                          "content":  "OBS Studio",
                          "description":  "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
                          "link":  "https://obsproject.com/",
                          "winget":  "OBSProject.OBSStudio",
                          "foss":  true
                      },
    "WPFInstallobsidian":  {
                               "category":  "Multimedia Tools",
                               "choco":  "obsidian",
                               "content":  "Obsidian",
                               "description":  "Obsidian is a powerful note-taking and knowledge management application.",
                               "link":  "https://obsidian.md/",
                               "winget":  "Obsidian.Obsidian",
                               "foss":  false
                           },
    "WPFInstallonedrive":  {
                               "category":  "Microsoft Tools",
                               "choco":  "onedrive",
                               "content":  "OneDrive",
                               "description":  "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
                               "link":  "https://onedrive.live.com/",
                               "winget":  "Microsoft.OneDrive",
                               "foss":  false
                           },
    "WPFInstallonlyoffice":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "onlyoffice",
                                 "content":  "ONLYOffice Desktop",
                                 "description":  "ONLYOffice Desktop is a comprehensive office suite for document editing and collaboration.",
                                 "link":  "https://www.onlyoffice.com/desktop.aspx",
                                 "winget":  "ONLYOFFICE.DesktopEditors",
                                 "foss":  true
                             },
    "WPFInstallOPAutoClicker":  {
                                    "category":  "Utilities",
                                    "choco":  "autoclicker",
                                    "content":  "OPAutoClicker",
                                    "description":  "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
                                    "link":  "https://www.opautoclicker.com",
                                    "winget":  "OPAutoClicker.OPAutoClicker",
                                    "foss":  false
                                },
    "WPFInstallopenrgb":  {
                              "category":  "Utilities",
                              "choco":  "openrgb",
                              "content":  "OpenRGB",
                              "description":  "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
                              "link":  "https://openrgb.org/",
                              "winget":  "OpenRGB.OpenRGB",
                              "foss":  true
                          },
    "WPFInstallOpenVPN":  {
                              "category":  "Pro Tools",
                              "choco":  "openvpn-connect",
                              "content":  "OpenVPN Connect",
                              "description":  "OpenVPN Connect is an open-source VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
                              "link":  "https://openvpn.net/",
                              "winget":  "OpenVPNTechnologies.OpenVPNConnect",
                              "foss":  true
                          },
    "WPFInstallOVirtualBox":  {
                                  "category":  "Utilities",
                                  "choco":  "virtualbox",
                                  "content":  "Oracle VirtualBox",
                                  "description":  "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
                                  "link":  "https://www.virtualbox.org/",
                                  "winget":  "Oracle.VirtualBox",
                                  "foss":  true
                              },
    "WPFInstallpolicyplus":  {
                                 "category":  "Utilities",
                                 "choco":  "na",
                                 "content":  "Policy Plus",
                                 "description":  "Local Group Policy Editor plus more, for all Windows editions.",
                                 "link":  "https://github.com/Fleex255/PolicyPlus",
                                 "winget":  "Fleex255.PolicyPlus",
                                 "foss":  true
                             },
    "WPFInstallprocessexplorer":  {
                                      "category":  "Microsoft Tools",
                                      "choco":  "na",
                                      "content":  "Process Explorer",
                                      "description":  "Process Explorer is a task manager and system monitor.",
                                      "link":  "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
                                      "winget":  "Microsoft.Sysinternals.ProcessExplorer",
                                      "foss":  false
                                  },
    "WPFInstallPaintdotnet":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "paint.net",
                                  "content":  "Paint.NET",
                                  "description":  "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
                                  "link":  "https://www.getpaint.net/",
                                  "winget":  "dotPDN.PaintDotNet",
                                  "foss":  false
                              },
    "WPFInstallparsec":  {
                             "category":  "Utilities",
                             "choco":  "parsec",
                             "content":  "Parsec",
                             "description":  "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
                             "link":  "https://parsec.app/",
                             "winget":  "Parsec.Parsec",
                             "foss":  false
                         },
    "WPFInstallpeazip":  {
                             "category":  "Utilities",
                             "choco":  "peazip",
                             "content":  "PeaZip",
                             "description":  "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
                             "link":  "https://peazip.github.io/",
                             "winget":  "Giorgiotani.Peazip",
                             "foss":  true
                         },
    "WPFInstallplex":  {
                           "category":  "Selfhosted Tools",
                           "choco":  "plexmediaserver",
                           "content":  "Plex Media Server",
                           "description":  "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
                           "link":  "https://www.plex.tv/your-media/",
                           "winget":  "Plex.PlexMediaServer",
                           "foss":  false
                       },
    "WPFInstallplexdesktop":  {
                                  "category":  "Selfhosted Tools",
                                  "choco":  "plex",
                                  "content":  "Plex Desktop",
                                  "description":  "Plex Desktop for Windows is the front end for Plex Media Server.",
                                  "link":  "https://www.plex.tv",
                                  "winget":  "Plex.Plex",
                                  "foss":  false
                              },
    "WPFInstallposh":  {
                           "category":  "Development",
                           "choco":  "oh-my-posh",
                           "content":  "Oh My Posh (Prompt)",
                           "description":  "Oh My Posh is a cross-platform prompt theme engine for any shell.",
                           "link":  "https://ohmyposh.dev/",
                           "winget":  "JanDeDobbeleer.OhMyPosh",
                           "foss":  true
                       },
    "WPFInstallpowershell":  {
                                 "category":  "Microsoft Tools",
                                 "choco":  "powershell-core",
                                 "content":  "PowerShell",
                                 "description":  "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
                                 "link":  "https://github.com/PowerShell/PowerShell",
                                 "winget":  "Microsoft.PowerShell",
                                 "foss":  true
                             },
    "WPFInstallpowertoys":  {
                                "category":  "Microsoft Tools",
                                "choco":  "powertoys",
                                "content":  "PowerToys",
                                "description":  "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
                                "link":  "https://github.com/microsoft/PowerToys",
                                "winget":  "Microsoft.PowerToys",
                                "foss":  true
                            },
    "WPFInstallprismlauncher":  {
                                    "category":  "Games",
                                    "choco":  "prismlauncher",
                                    "content":  "Prism Launcher",
                                    "description":  "Prism Launcher is an open-source Minecraft launcher with the ability to manage multiple instances, accounts and mods.",
                                    "link":  "https://prismlauncher.org/",
                                    "winget":  "PrismLauncher.PrismLauncher",
                                    "foss":  true
                                },
    "WPFInstallprocesslasso":  {
                                   "category":  "Utilities",
                                   "choco":  "plasso",
                                   "content":  "Process Lasso",
                                   "description":  "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
                                   "link":  "https://bitsum.com/",
                                   "winget":  "BitSum.ProcessLasso",
                                   "foss":  false
                               },
    "WPFInstallprotonauth":  {
                                 "category":  "Utilities",
                                 "choco":  "protonauth",
                                 "content":  "Proton Authenticator",
                                 "description":  "2FA app from Proton to securely sync and backup 2FA codes.",
                                 "link":  "https://proton.me/authenticator",
                                 "winget":  "Proton.ProtonAuthenticator",
                                 "foss":  true
                             },
    "WPFInstallprotonmail":  {
                                 "category":  "Communications",
                                 "choco":  "protonmail",
                                 "content":  "Proton Mail",
                                 "description":  "Proton Mail is an end-to-end encrypted email service by Proton, protecting your privacy with zero-access encryption.",
                                 "link":  "https://proton.me/mail",
                                 "winget":  "Proton.ProtonMail",
                                 "foss":  true
                             },
    "WPFInstallprotondrive":  {
                                  "category":  "Utilities",
                                  "choco":  "protondrive",
                                  "content":  "Proton Drive",
                                  "description":  "Proton Drive is an end-to-end encrypted Swiss vault for your files that protects your data.",
                                  "link":  "https://proton.me/drive",
                                  "winget":  "Proton.ProtonDrive",
                                  "foss":  true
                              },
    "WPFInstallprotonpass":  {
                                 "category":  "Utilities",
                                 "choco":  "protonpass",
                                 "content":  "Proton Pass",
                                 "description":  "Proton Pass is a cloud-based password manager with end-to-end encryption and unique email aliases.",
                                 "link":  "https://proton.me/pass",
                                 "winget":  "Proton.ProtonPass",
                                 "foss":  true
                             },
    "WPFInstallprotonvpn":  {
                                "category":  "Pro Tools",
                                "choco":  "protonvpn",
                                "content":  "Proton VPN",
                                "description":  "Proton VPN is a no-logs VPN service that protects your privacy online with features like Secure Core and Tor over VPN.",
                                "link":  "https://protonvpn.com/",
                                "winget":  "Proton.ProtonVPN",
                                "foss":  true
                            },
    "WPFInstallprocessmonitor":  {
                                     "category":  "Microsoft Tools",
                                     "choco":  "procexp",
                                     "content":  "SysInternals Process Monitor",
                                     "description":  "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
                                     "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
                                     "winget":  "Microsoft.Sysinternals.ProcessMonitor",
                                     "foss":  false
                                 },
    "WPFInstallputty":  {
                            "category":  "Pro Tools",
                            "choco":  "putty",
                            "content":  "PuTTY",
                            "description":  "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
                            "link":  "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
                            "winget":  "PuTTY.PuTTY",
                            "foss":  true
                        },
    "WPFInstallpython3":  {
                              "category":  "Development",
                              "choco":  "python",
                              "content":  "Python3",
                              "description":  "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
                              "link":  "https://www.python.org/",
                              "winget":  "Python.Python.3.14",
                              "foss":  true
                          },
    "WPFInstallqbittorrent":  {
                                  "category":  "Utilities",
                                  "choco":  "qbittorrent",
                                  "content":  "qBittorrent",
                                  "description":  "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
                                  "link":  "https://www.qbittorrent.org/",
                                  "winget":  "qBittorrent.qBittorrent",
                                  "foss":  true
                              },
    "WPFInstallqtox":  {
                           "category":  "Communications",
                           "choco":  "qtox",
                           "content":  "QTox",
                           "description":  "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
                           "link":  "https://qtox.github.io/",
                           "winget":  "Tox.qTox",
                           "foss":  true
                       },
    "WPFInstallrevo":  {
                           "category":  "Utilities",
                           "choco":  "revo-uninstaller",
                           "content":  "Revo Uninstaller",
                           "description":  "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
                           "link":  "https://www.revouninstaller.com/",
                           "winget":  "RevoUninstaller.RevoUninstaller",
                           "foss":  false
                       },
    "WPFInstallWiseProgramUninstaller":  {
                                             "category":  "Utilities",
                                             "choco":  "na",
                                             "content":  "Wise Program Uninstaller (WiseCleaner)",
                                             "description":  "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
                                             "link":  "https://www.wisecleaner.com/wise-program-uninstaller.html",
                                             "winget":  "WiseCleaner.WiseProgramUninstaller",
                                             "foss":  false
                                         },
    "WPFInstallrufus":  {
                            "category":  "Utilities",
                            "choco":  "rufus",
                            "content":  "Rufus Imager",
                            "description":  "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
                            "link":  "https://rufus.ie/",
                            "winget":  "Rufus.Rufus",
                            "foss":  true
                        },
    "WPFInstallrustdesk":  {
                               "category":  "Pro Tools",
                               "choco":  "rustdesk.portable",
                               "content":  "RustDesk",
                               "description":  "RustDesk is a free and open-source remote desktop application. It provides a secure way to connect to remote machines and access desktop environments.",
                               "link":  "https://rustdesk.com/",
                               "winget":  "RustDesk.RustDesk",
                               "foss":  true
                           },
    "WPFInstallrustlang":  {
                               "category":  "Development",
                               "choco":  "rust",
                               "content":  "Rust",
                               "description":  "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
                               "link":  "https://www.rust-lang.org/",
                               "winget":  "Rustlang.Rust.MSVC",
                               "foss":  true
                           },
    "WPFInstallsdio":  {
                           "category":  "Utilities",
                           "choco":  "sdio",
                           "content":  "Snappy Driver Installer Origin",
                           "description":  "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
                           "link":  "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
                           "winget":  "GlennDelahoy.SnappyDriverInstallerOrigin",
                           "foss":  true
                       },
    "WPFInstallsharex":  {
                             "category":  "Multimedia Tools",
                             "choco":  "sharex",
                             "content":  "ShareX (Screenshots)",
                             "description":  "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
                             "link":  "https://getsharex.com/",
                             "winget":  "ShareX.ShareX",
                             "foss":  true
                         },
    "WPFInstallnilesoftShell":  {
                                    "category":  "Utilities",
                                    "choco":  "nilesoft-shell",
                                    "content":  "Nilesoft Shell",
                                    "description":  "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
                                    "link":  "https://nilesoft.org/",
                                    "winget":  "Nilesoft.Shell",
                                    "foss":  false
                                },
    "WPFInstallsysteminformer":  {
                                     "category":  "Development",
                                     "choco":  "systeminformer",
                                     "content":  "System Informer",
                                     "description":  "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
                                     "link":  "https://systeminformer.com/",
                                     "winget":  "WinsiderSS.SystemInformer",
                                     "foss":  true
                                 },
    "WPFInstallsignal":  {
                             "category":  "Communications",
                             "choco":  "signal",
                             "content":  "Signal",
                             "description":  "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
                             "link":  "https://signal.org/",
                             "winget":  "OpenWhisperSystems.Signal",
                             "foss":  true
                         },
    "WPFInstallsignalrgb":  {
                                "category":  "Utilities",
                                "choco":  "na",
                                "content":  "SignalRGB",
                                "description":  "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
                                "link":  "https://www.signalrgb.com/",
                                "winget":  "WhirlwindFX.SignalRgb",
                                "foss":  false
                            },
    "WPFInstallsimplewall":  {
                                 "category":  "Pro Tools",
                                 "choco":  "simplewall",
                                 "content":  "Simplewall",
                                 "description":  "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
                                 "link":  "https://github.com/henrypp/simplewall",
                                 "winget":  "Henry++.simplewall",
                                 "foss":  true
                             },
    "WPFInstallslack":  {
                            "category":  "Communications",
                            "choco":  "slack",
                            "content":  "Slack",
                            "description":  "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
                            "link":  "https://slack.com/",
                            "winget":  "SlackTechnologies.Slack",
                            "foss":  false
                        },
    "WPFInstallsteam":  {
                            "category":  "Games",
                            "choco":  "steam-client",
                            "content":  "Steam",
                            "description":  "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
                            "link":  "https://store.steampowered.com/about/",
                            "winget":  "Valve.Steam",
                            "foss":  false
                        },
    "WPFInstallsublimetext":  {
                                  "category":  "Development",
                                  "choco":  "sublimetext4",
                                  "content":  "Sublime Text",
                                  "description":  "Sublime Text is a sophisticated text editor for code, markup, and prose.",
                                  "link":  "https://www.sublimetext.com/",
                                  "winget":  "SublimeHQ.SublimeText.4",
                                  "foss":  false
                              },
    "WPFInstallsunshine":  {
                               "category":  "Selfhosted Tools",
                               "choco":  "sunshine",
                               "content":  "Sunshine/GameStream Server",
                               "description":  "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
                               "link":  "https://github.com/LizardByte/Sunshine",
                               "winget":  "LizardByte.Sunshine",
                               "foss":  true
                           },
    "WPFInstalltcpview":  {
                              "category":  "Microsoft Tools",
                              "choco":  "tcpview",
                              "content":  "SysInternals TCPView",
                              "description":  "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
                              "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
                              "winget":  "Microsoft.Sysinternals.TCPView",
                              "foss":  false
                          },
    "WPFInstallteams":  {
                            "category":  "Communications",
                            "choco":  "microsoft-teams",
                            "content":  "Teams",
                            "description":  "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
                            "link":  "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
                            "winget":  "Microsoft.Teams",
                            "foss":  false
                        },
    "WPFInstallteamviewer":  {
                                 "category":  "Utilities",
                                 "choco":  "teamviewer9",
                                 "content":  "TeamViewer",
                                 "description":  "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
                                 "link":  "https://www.teamviewer.com/",
                                 "winget":  "TeamViewer.TeamViewer",
                                 "foss":  false
                             },
    "WPFInstallteamspeak3":  {
                                 "category":  "Communications",
                                 "choco":  "teamspeak",
                                 "content":  "TeamSpeak 3",
                                 "description":  "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your team mates cross-platform with military-grade security, lag-free performance \u0026 unparalleled reliability and uptime.",
                                 "link":  "https://www.teamspeak.com/",
                                 "winget":  "TeamSpeakSystems.TeamSpeakClient",
                                 "foss":  false
                             },
    "WPFInstalltelegram":  {
                               "category":  "Communications",
                               "choco":  "telegram",
                               "content":  "Telegram",
                               "description":  "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
                               "link":  "https://telegram.org/",
                               "winget":  "Telegram.TelegramDesktop",
                               "foss":  true
                           },
    "WPFInstallterminal":  {
                               "category":  "Microsoft Tools",
                               "choco":  "microsoft-windows-terminal",
                               "content":  "Windows Terminal",
                               "description":  "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
                               "link":  "https://aka.ms/terminal",
                               "winget":  "Microsoft.WindowsTerminal",
                               "foss":  true
                           },
    "WPFInstallthunderbird":  {
                                  "category":  "Communications",
                                  "choco":  "thunderbird",
                                  "content":  "Thunderbird",
                                  "description":  "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
                                  "link":  "https://www.thunderbird.net/",
                                  "winget":  "Mozilla.Thunderbird",
                                  "foss":  true
                              },
    "WPFInstallbetterbird":  {
                                 "category":  "Communications",
                                 "choco":  "betterbird",
                                 "content":  "Betterbird",
                                 "description":  "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
                                 "link":  "https://www.betterbird.eu/",
                                 "winget":  "Betterbird.Betterbird",
                                 "foss":  true
                             },
    "WPFInstalltor":  {
                          "category":  "Browsers",
                          "choco":  "tor-browser",
                          "content":  "Tor Browser",
                          "description":  "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
                          "link":  "https://www.torproject.org/",
                          "winget":  "TorProject.TorBrowser",
                          "foss":  true
                      },
    "WPFInstalltotalcommander":  {
                                     "category":  "Utilities",
                                     "choco":  "TotalCommander",
                                     "content":  "Total Commander",
                                     "description":  "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
                                     "link":  "https://www.ghisler.com/",
                                     "winget":  "Ghisler.TotalCommander",
                                     "foss":  false
                                 },
    "WPFInstalltreesize":  {
                               "category":  "Utilities",
                               "choco":  "treesizefree",
                               "content":  "TreeSize Free",
                               "description":  "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
                               "link":  "https://www.jam-software.com/treesize_free/",
                               "winget":  "JAMSoftware.TreeSize.Free",
                               "foss":  false
                           },
    "WPFInstallttaskbar":  {
                               "category":  "Utilities",
                               "choco":  "translucenttb",
                               "content":  "TranslucentTB",
                               "description":  "TranslucentTB is a tool that allows you to customize the transparency of the Windows Taskbar.",
                               "link":  "https://github.com/TranslucentTB/TranslucentTB",
                               "winget":  "CharlesMilette.TranslucentTB",
                               "foss":  true
                           },
    "WPFInstallubisoft":  {
                              "category":  "Games",
                              "choco":  "ubisoft-connect",
                              "content":  "Ubisoft Connect",
                              "description":  "Ubisoft Connect is Ubisoft\u0027s digital distribution and online gaming service, providing access to Ubisoft\u0027s games and services.",
                              "link":  "https://ubisoftconnect.com/",
                              "winget":  "Ubisoft.Connect",
                              "foss":  false
                          },
    "WPFInstallungoogled":  {
                                "category":  "Browsers",
                                "choco":  "ungoogled-chromium",
                                "content":  "Ungoogled",
                                "description":  "Ungoogled Chromium is a version of Chromium without Google\u0027s integration for enhanced privacy and control.",
                                "link":  "https://github.com/Eloston/ungoogled-chromium",
                                "winget":  "eloston.ungoogled-chromium",
                                "foss":  true
                            },
    "WPFInstallunity":  {
                            "category":  "Development",
                            "choco":  "unityhub",
                            "content":  "Unity Game Engine",
                            "description":  "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
                            "link":  "https://unity.com/",
                            "winget":  "Unity.UnityHub",
                            "foss":  false
                        },
    "WPFInstallvc2015_32":  {
                                "category":  "Microsoft Tools",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 32-bit",
                                "description":  "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x86",
                                "foss":  false
                            },
    "WPFInstallvc2015_64":  {
                                "category":  "Microsoft Tools",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 64-bit",
                                "description":  "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x64",
                                "foss":  false
                            },
    "WPFInstallventoy":  {
                             "category":  "Pro Tools",
                             "choco":  "ventoy",
                             "content":  "Ventoy",
                             "description":  "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
                             "link":  "https://www.ventoy.net/",
                             "winget":  "Ventoy.Ventoy",
                             "foss":  true
                         },
    "WPFInstallvesktop":  {
                              "category":  "Communications",
                              "choco":  "na",
                              "content":  "Vesktop",
                              "description":  "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
                              "link":  "https://github.com/Vencord/Vesktop",
                              "winget":  "Vencord.Vesktop",
                              "foss":  true
                          },
    "WPFInstallviber":  {
                            "category":  "Communications",
                            "choco":  "viber",
                            "content":  "Viber",
                            "description":  "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
                            "link":  "https://www.viber.com/",
                            "winget":  "Rakuten.Viber",
                            "foss":  false
                        },
    "WPFInstallvisualstudio2022":  {
                                       "category":  "Development",
                                       "choco":  "visualstudio2022community",
                                       "content":  "Visual Studio 2022",
                                       "description":  "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.2022.Community",
                                       "foss":  false
                                   },
    "WPFInstallvisualstudio2026":  {
                                       "category":  "Development",
                                       "choco":  "visualstudio2026community",
                                       "content":  "Visual Studio 2026",
                                       "description":  "Visual Studio 2026 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.Community",
                                       "foss":  false
                                   },
    "WPFInstallvivaldi":  {
                              "category":  "Browsers",
                              "choco":  "vivaldi",
                              "content":  "Vivaldi",
                              "description":  "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
                              "link":  "https://vivaldi.com/",
                              "winget":  "Vivaldi.Vivaldi",
                              "foss":  false
                          },
    "WPFInstallvlc":  {
                          "category":  "Multimedia Tools",
                          "choco":  "vlc",
                          "content":  "VLC (Video Player)",
                          "description":  "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
                          "link":  "https://www.videolan.org/vlc/",
                          "winget":  "VideoLAN.VLC",
                          "foss":  true
                      },
    "WPFInstallvrdesktopstreamer":  {
                                        "category":  "Games",
                                        "choco":  "na",
                                        "content":  "Virtual Desktop Streamer",
                                        "description":  "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
                                        "link":  "https://www.vrdesktop.net/",
                                        "winget":  "VirtualDesktop.Streamer",
                                        "foss":  false
                                    },
    "WPFInstallvscode":  {
                             "category":  "Development",
                             "choco":  "vscode",
                             "content":  "VS Code",
                             "description":  "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
                             "link":  "https://code.visualstudio.com/",
                             "winget":  "Microsoft.VisualStudioCode",
                             "foss":  true
                         },
    "WPFInstallvscodium":  {
                               "category":  "Development",
                               "choco":  "vscodium",
                               "content":  "VS Codium",
                               "description":  "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft\u0027s VS Code.",
                               "link":  "https://vscodium.com/",
                               "winget":  "VSCodium.VSCodium",
                               "foss":  true
                           },
    "WPFInstallwaterfox":  {
                               "category":  "Browsers",
                               "choco":  "waterfox",
                               "content":  "Waterfox",
                               "description":  "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
                               "link":  "https://www.waterfox.net/",
                               "winget":  "Waterfox.Waterfox",
                               "foss":  true
                           },
    "WPFInstallwingetui":  {
                               "category":  "Utilities",
                               "choco":  "wingetui",
                               "content":  "UniGetUI",
                               "description":  "UniGetUI is a GUI for WinGet, Chocolatey, and other Windows CLI package managers.",
                               "link":  "https://devolutions.net/unigetui/",
                               "winget":  "Devolutions.UniGetUI",
                               "foss":  true
                           },
    "WPFInstallwinrar":  {
                             "category":  "Utilities",
                             "choco":  "winrar",
                             "content":  "WinRAR",
                             "description":  "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
                             "link":  "https://www.win-rar.com/",
                             "winget":  "RARLab.WinRAR",
                             "foss":  false
                         },
    "WPFInstallwinscp":  {
                             "category":  "Pro Tools",
                             "choco":  "winscp",
                             "content":  "WinSCP",
                             "description":  "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
                             "link":  "https://winscp.net/",
                             "winget":  "WinSCP.WinSCP",
                             "foss":  true
                         },
    "WPFInstallwireguard":  {
                                "category":  "Pro Tools",
                                "choco":  "wireguard",
                                "content":  "WireGuard",
                                "description":  "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
                                "link":  "https://www.wireguard.com/",
                                "winget":  "WireGuard.WireGuard",
                                "foss":  true
                            },
    "WPFInstallwireshark":  {
                                "category":  "Pro Tools",
                                "choco":  "wireshark",
                                "content":  "Wireshark",
                                "description":  "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
                                "link":  "https://www.wireshark.org/",
                                "winget":  "WiresharkFoundation.Wireshark",
                                "foss":  true
                            },
    "WPFInstallwiztree":  {
                              "category":  "Utilities",
                              "choco":  "wiztree",
                              "content":  "WizTree",
                              "description":  "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
                              "link":  "https://wiztreefree.com/",
                              "winget":  "AntibodySoftware.WizTree",
                              "foss":  false
                          },
    "WPFInstallxeheditor":  {
                                "category":  "Utilities",
                                "choco":  "HxD",
                                "content":  "HxD Hex Editor",
                                "description":  "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
                                "link":  "https://mh-nexus.de/en/hxd/",
                                "winget":  "MHNexus.HxD",
                                "foss":  false
                            },
    "WPFInstallyarn":  {
                           "category":  "Development",
                           "choco":  "yarn",
                           "content":  "Yarn",
                           "description":  "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
                           "link":  "https://yarnpkg.com/",
                           "winget":  "Yarn.Yarn",
                           "foss":  true
                       },
    "WPFInstallzoom":  {
                           "category":  "Communications",
                           "choco":  "zoom",
                           "content":  "Zoom",
                           "description":  "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
                           "link":  "https://zoom.us/",
                           "winget":  "Zoom.Zoom",
                           "foss":  false
                       },
    "WPFInstalluv":  {
                         "category":  "Development",
                         "choco":  "uv",
                         "content":  "uv",
                         "description":  "uv is a fast Python package and project manager written in Rust.",
                         "link":  "https://docs.astral.sh/uv/getting-started/installation/",
                         "winget":  "astral-sh.uv",
                         "foss":  true
                     },
    "WPFInstalltightvnc":  {
                               "category":  "Utilities",
                               "choco":  "TightVNC",
                               "content":  "TightVNC",
                               "description":  "TightVNC is a free and open-source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there.",
                               "link":  "https://www.tightvnc.com/",
                               "winget":  "GlavSoft.TightVNC",
                               "foss":  true
                           },
    "WPFInstallglazewm":  {
                              "category":  "Utilities",
                              "choco":  "glazewm",
                              "content":  "GlazeWM",
                              "description":  "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar.",
                              "link":  "https://github.com/glzr-io/glazewm",
                              "winget":  "glzr-io.glazewm",
                              "foss":  true
                          },
    "WPFInstallOverwolf":  {
                               "category":  "Games",
                               "choco":  "overwolf",
                               "content":  "Overwolf",
                               "description":  "Popular platform for game overlays and companion apps (mod managers, trackers, etc.), widely used by gamers.",
                               "link":  "https://www.overwolf.com/app/overwolf-curseforge",
                               "winget":  "Overwolf.CurseForge",
                               "foss":  false
                           },
    "WPFInstallOFGB":  {
                           "category":  "Utilities",
                           "choco":  "ofgb",
                           "content":  "OFGB (Oh Frick Go Back)",
                           "description":  "GUI Tool to remove ads from various places around Windows 11",
                           "link":  "https://github.com/xM4ddy/OFGB",
                           "winget":  "xM4ddy.OFGB",
                           "foss":  true
                       },
    "WPFInstallZenBrowser":  {
                                 "category":  "Browsers",
                                 "choco":  "zen-browser",
                                 "content":  "Zen Browser",
                                 "description":  "The modern, privacy-focused, performance-driven browser built on Firefox.",
                                 "link":  "https://zen-browser.app/",
                                 "winget":  "Zen-Team.Zen-Browser",
                                 "foss":  true
                             },
    "WPFInstallZed":  {
                          "category":  "Development",
                          "choco":  "zed",
                          "content":  "Zed",
                          "description":  "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
                          "link":  "https://zed.dev/",
                          "winget":  "ZedIndustries.Zed",
                          "foss":  true
                      },
    "WPFInstallRuby":  {
                           "category":  "Development",
                           "choco":  "ruby",
                           "winget":  "RubyInstallerTeam.Ruby.4.0",
                           "description":  "A Ruby language execution environment with a MSYS2 installation.",
                           "content":  "Ruby",
                           "link":  "https://rubyinstaller.org/",
                           "foss":  true
                       },
    "WPFInstallLua":  {
                          "category":  "Development",
                          "choco":  "lua",
                          "winget":  "rjpcomputing.luaforwindows",
                          "description":  "A \u0027batteries included environment\u0027 for the Lua scripting language on Windows.",
                          "content":  "Lua",
                          "link":  "https://github.com/rjpcomputing/luaforwindows",
                          "foss":  true
                      }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
    "WPFInstall":  {
                       "Content":  "Installa/Aggiorna applicazioni",
                       "Category":  "____Azioni",
                       "Type":  "Button",
                       "Order":  "1",
                       "Description":  "Installa o aggiorna le applicazioni selezionate"
                   },
    "WPFUninstall":  {
                         "Content":  "Disinstalla applicazioni",
                         "Category":  "____Azioni",
                         "Type":  "Button",
                         "Order":  "2",
                         "Description":  "Disinstalla le applicazioni selezionate"
                     },
    "WPFInstallUpgrade":  {
                              "Content":  "Aggiorna tutte le applicazioni",
                              "Category":  "____Azioni",
                              "Type":  "Button",
                              "Order":  "3",
                              "Description":  "Aggiorna tutte le applicazioni all\u0027ultima versione"
                          },
    "WingetRadioButton":  {
                              "Content":  "WinGet",
                              "Category":  "__Gestore pacchetti",
                              "Type":  "RadioButton",
                              "GroupName":  "PackageManagerGroup",
                              "Checked":  true,
                              "Order":  "1",
                              "Description":  "Usa WinGet per la gestione dei pacchetti"
                          },
    "ChocoRadioButton":  {
                             "Content":  "Chocolatey",
                             "Category":  "__Gestore pacchetti",
                             "Type":  "RadioButton",
                             "GroupName":  "PackageManagerGroup",
                             "Checked":  false,
                             "Order":  "2",
                             "Description":  "Usa Chocolatey per la gestione dei pacchetti"
                         },
    "WPFCollapseAllCategories":  {
                                     "Content":  "Comprimi tutte le categorie",
                                     "Category":  "__Selezione",
                                     "Type":  "Button",
                                     "Order":  "1",
                                     "Description":  "Comprimi tutte le categorie di applicazioni"
                                 },
    "WPFExpandAllCategories":  {
                                   "Content":  "Espandi tutte le categorie",
                                   "Category":  "__Selezione",
                                   "Type":  "Button",
                                   "Order":  "2",
                                   "Description":  "Espandi tutte le categorie di applicazioni"
                               },
    "WPFClearInstallSelection":  {
                                     "Content":  "Azzera selezione",
                                     "Category":  "__Selezione",
                                     "Type":  "Button",
                                     "Order":  "3",
                                     "Description":  "Azzera la selezione delle applicazioni"
                                 },
    "WPFGetInstalled":  {
                            "Content":  "Mostra app installate",
                            "Category":  "__Selezione",
                            "Type":  "Button",
                            "Order":  "4",
                            "Description":  "Mostra le applicazioni installate"
                        },
    "WPFselectedAppsButton":  {
                                  "Content":  "App selezionate: 0",
                                  "Category":  "__Selezione",
                                  "Type":  "Button",
                                  "Order":  "5",
                                  "Description":  "Mostra le applicazioni selezionate"
                              },
    "WPFToggleFOSSHighlight":  {
                                   "Content":  "Evidenzia FOSS",
                                   "Category":  "__Selezione",
                                   "Type":  "Toggle",
                                   "Checked":  true,
                                   "Order":  "6",
                                   "Description":  "Attiva/disattiva l\u0027evidenziazione verde per le applicazioni FOSS"
                               }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
    "Google":  {
                   "Primary":  "8.8.8.8",
                   "Secondary":  "8.8.4.4",
                   "Primary6":  "2001:4860:4860::8888",
                   "Secondary6":  "2001:4860:4860::8844"
               },
    "Cloudflare":  {
                       "Primary":  "1.1.1.1",
                       "Secondary":  "1.0.0.1",
                       "Primary6":  "2606:4700:4700::1111",
                       "Secondary6":  "2606:4700:4700::1001"
                   },
    "Cloudflare_Malware":  {
                               "Primary":  "1.1.1.2",
                               "Secondary":  "1.0.0.2",
                               "Primary6":  "2606:4700:4700::1112",
                               "Secondary6":  "2606:4700:4700::1002"
                           },
    "Cloudflare_Malware_Adult":  {
                                     "Primary":  "1.1.1.3",
                                     "Secondary":  "1.0.0.3",
                                     "Primary6":  "2606:4700:4700::1113",
                                     "Secondary6":  "2606:4700:4700::1003"
                                 },
    "Open_DNS":  {
                     "Primary":  "208.67.222.222",
                     "Secondary":  "208.67.220.220",
                     "Primary6":  "2620:119:35::35",
                     "Secondary6":  "2620:119:53::53"
                 },
    "Quad9":  {
                  "Primary":  "9.9.9.9",
                  "Secondary":  "149.112.112.112",
                  "Primary6":  "2620:fe::fe",
                  "Secondary6":  "2620:fe::9"
              },
    "AdGuard_Ads_Trackers":  {
                                 "Primary":  "94.140.14.14",
                                 "Secondary":  "94.140.15.15",
                                 "Primary6":  "2a10:50c0::ad1:ff",
                                 "Secondary6":  "2a10:50c0::ad2:ff"
                             },
    "AdGuard_Ads_Trackers_Malware_Adult":  {
                                               "Primary":  "94.140.14.15",
                                               "Secondary":  "94.140.15.16",
                                               "Primary6":  "2a10:50c0::bad1:ff",
                                               "Secondary6":  "2a10:50c0::bad2:ff"
                                           }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
    "WPFFeaturesdotnet":  {
                              "Content":  ".NET Framework (Versions 2, 3, 4) - Enable",
                              "Description":  ".NET and .NET Framework is a developer platform made up of tools, programming languages, and libraries for building many different types of applications.",
                              "category":  "Features",
                              "panel":  "1",
                              "feature":  [
                                              "NetFx4-AdvSrvs",
                                              "NetFx3"
                                          ],
                              "InvokeScript":  [

                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFixesNTPPool":  {
                            "Content":  "NTP Server - Enable",
                            "Description":  "Replaces the default Windows NTP server (time.windows.com) with pool.ntp.org for improved time synchronization accuracy and reliability.",
                            "category":  "Fixes",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNTPPool",
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFFeatureshyperv":  {
                              "Content":  "Hyper-V - Enable",
                              "Description":  "Hyper-V is a hardware virtualization product developed by Microsoft that allows users to create and manage virtual machines.",
                              "category":  "Features",
                              "panel":  "1",
                              "feature":  [
                                              "Microsoft-Hyper-V-All"
                                          ],
                              "InvokeScript":  [
                                                   "bcdedit /set hypervisorschedulertype classic"
                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFeatureslegacymedia":  {
                                   "Content":  "Legacy Media Components (WMP, DirectPlay) - Enable",
                                   "Description":  "Enables legacy programs from previous versions of Windows.",
                                   "category":  "Features",
                                   "panel":  "1",
                                   "feature":  [
                                                   "WindowsMediaPlayer",
                                                   "MediaPlayback",
                                                   "DirectPlay",
                                                   "LegacyComponents"
                                               ],
                                   "InvokeScript":  [

                                                    ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFFeaturewsl":  {
                          "Content":  "Windows Subsystem for Linux (WSL) - Enable",
                          "Description":  "Windows Subsystem for Linux is an optional feature of Windows that allows Linux programs to run natively on Windows without the need for a separate virtual machine or dual booting.",
                          "category":  "Features",
                          "panel":  "1",
                          "feature":  [
                                          "VirtualMachinePlatform",
                                          "Microsoft-Windows-Subsystem-Linux"
                                      ],
                          "InvokeScript":  [

                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFFeaturenfs":  {
                          "Content":  "Network File System (NFS) - Enable",
                          "Description":  "Network File System (NFS) is a mechanism for storing files on a network.",
                          "category":  "Features",
                          "panel":  "1",
                          "feature":  [
                                          "ServicesForNFS-ClientOnly",
                                          "ClientForNFS-Infrastructure",
                                          "NFS-Administration"
                                      ],
                          "InvokeScript":  [
                                               "nfsadmin client stop",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousUID\u0027 -Type DWord -Value 0",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousGID\u0027 -Type DWord -Value 0",
                                               "nfsadmin client start",
                                               "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFFeatureRegBackup":  {
                                "Content":  "Registry Backup (Daily Task 12:30am) - Enable",
                                "Description":  "Enables daily registry backup, previously disabled by Microsoft in Windows 10 1803.",
                                "category":  "Features",
                                "panel":  "1",
                                "feature":  [

                                            ],
                                "InvokeScript":  [
                                                     "\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027EnablePeriodicBackup\u0027 -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027BackupCount\u0027 -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute \u0027schtasks\u0027 -Argument \u0027/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"\u0027\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName \u0027AutoRegBackup\u0027 -Description \u0027Create System Registry Backups\u0027 -User \u0027System\u0027\r\n      "
                                                 ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFFeatureEnableLegacyRecovery":  {
                                           "Content":  "Legacy F8 Boot Recovery - Enable",
                                           "Description":  "Enables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
                                           "category":  "Features",
                                           "panel":  "1",
                                           "feature":  [

                                                       ],
                                           "InvokeScript":  [
                                                                "bcdedit /set bootmenupolicy legacy"
                                                            ],
                                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                       },
    "WPFFeatureDisableLegacyRecovery":  {
                                            "Content":  "Legacy F8 Boot Recovery - Disable",
                                            "Description":  "Disables Advanced Boot Options screen that lets you start Windows in advanced troubleshooting modes.",
                                            "category":  "Features",
                                            "panel":  "1",
                                            "feature":  [

                                                        ],
                                            "InvokeScript":  [
                                                                 "bcdedit /set bootmenupolicy standard"
                                                             ],
                                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                        },
    "WPFFeaturesSandbox":  {
                               "Content":  "Windows Sandbox - Enable",
                               "Description":  "Windows Sandbox is a lightweight virtual machine that provides a temporary desktop environment to safely run applications and programs in isolation.",
                               "category":  "Features",
                               "panel":  "1",
                               "feature":  [
                                               "Containers-DisposableClientVM"
                                           ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFFeatureInstall":  {
                              "Content":  "Run Features",
                              "category":  "Features",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFFeatureInstall",
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFPanelAutologin":  {
                              "Content":  "AutoLogon - Run",
                              "category":  "Fixes",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFPanelAutologin",
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFixesUpdate":  {
                           "Content":  "Windows Update - Reset",
                           "category":  "Fixes",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesUpdate",
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFFixesNetwork":  {
                            "Content":  "Network - Reset",
                            "category":  "Fixes",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNetwork",
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelDISM":  {
                         "Content":  "System Corruption Scan - Run",
                         "category":  "Fixes",
                         "panel":  "1",
                         "Type":  "Button",
                         "ButtonWidth":  "300",
                         "function":  "Invoke-WPFSystemRepair",
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFFixesWinget":  {
                           "Content":  "WinGet - Reinstall",
                           "category":  "Fixes",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesWinget",
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelControl":  {
                            "Content":  "Control Panel",
                            "category":  "Legacy Windows Panels",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "control"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelComputer":  {
                             "Content":  "Computer Management",
                             "category":  "Legacy Windows Panels",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "compmgmt.msc"
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFPanelNetwork":  {
                            "Content":  "Network Connections",
                            "category":  "Legacy Windows Panels",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "ncpa.cpl"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelPower":  {
                          "Content":  "Power Panel",
                          "category":  "Legacy Windows Panels",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "powercfg.cpl"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFPanelPrinter":  {
                            "Content":  "Printer Panel",
                            "category":  "Legacy Windows Panels",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "Start-Process \u0027shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}\u0027"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelRegion":  {
                           "Content":  "Region",
                           "category":  "Legacy Windows Panels",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "intl.cpl"
                                            ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelRestore":  {
                            "Content":  "Windows Restore",
                            "category":  "Legacy Windows Panels",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "rstrui.exe"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelSound":  {
                          "Content":  "Sound Settings",
                          "category":  "Legacy Windows Panels",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "mmsys.cpl"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFPanelSystem":  {
                           "Content":  "System Properties",
                           "category":  "Legacy Windows Panels",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "sysdm.cpl"
                                            ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelTimedate":  {
                             "Content":  "Time and Date",
                             "category":  "Legacy Windows Panels",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "timedate.cpl"
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFWinUtilSSHServer":  {
                                "Content":  "OpenSSH Server - Enable",
                                "category":  "Remote Access",
                                "panel":  "2",
                                "Type":  "Button",
                                "ButtonWidth":  "300",
                                "function":  "Invoke-WPFSSHServer",
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
    "Standard":  [
                     "WPFTweaksActivity",
                     "WPFTweaksConsumerFeatures",
                     "WPFTweaksDisableExplorerAutoDiscovery",
                     "WPFTweaksWPBT",
                     "WPFTweaksDVR",
                     "WPFTweaksDeBloat",
                     "WPFTweaksLocation",
                     "WPFTweaksServices",
                     "WPFTweaksTelemetry",
                     "WPFTweaksDiskCleanup",
                     "WPFTweaksDeleteTempFiles",
                     "WPFTweaksEndTaskOnTaskbar",
                     "WPFTweaksRestorePoint",
                     "WPFTweaksPowershell7Tele"
                 ],
    "Minimal":  [
                    "WPFTweaksConsumerFeatures",
                    "WPFTweaksDeBloat",
                    "WPFTweaksWPBT",
                    "WPFTweaksServices",
                    "WPFTweaksTelemetry"
                ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
    "shared":  {
                   "AppEntryWidth":  "200",
                   "AppEntryFontSize":  "11",
                   "AppEntryMargin":  "1,0,1,0",
                   "AppEntryBorderThickness":  "0",
                   "CustomDialogFontSize":  "12",
                   "CustomDialogFontSizeHeader":  "14",
                   "CustomDialogLogoSize":  "25",
                   "CustomDialogWidth":  "400",
                   "CustomDialogHeight":  "200",
                   "FontSize":  "12",
                   "FontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "HeaderFontSize":  "16",
                   "HeaderFontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "CheckBoxBulletDecoratorSize":  "14",
                   "CheckBoxMargin":  "15,0,0,2",
                   "TabContentMargin":  "5",
                   "TabButtonFontSize":  "14",
                   "TabButtonWidth":  "110",
                   "TabButtonHeight":  "26",
                   "TabRowHeightInPixels":  "50",
                   "ToolTipWidth":  "300",
                   "IconFontSize":  "14",
                   "IconButtonSize":  "35",
                   "SettingsIconFontSize":  "18",
                   "CloseIconFontSize":  "18",
                   "GroupBorderBackgroundColor":  "#59161B26",
                   "ButtonFontSize":  "12",
                   "ButtonFontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "ButtonWidth":  "200",
                   "ButtonHeight":  "25",
                   "ConfigTabButtonFontSize":  "14",
                   "ConfigUpdateButtonFontSize":  "14",
                   "SearchBarWidth":  "200",
                   "SearchBarHeight":  "26",
                   "SearchBarTextBoxFontSize":  "12",
                   "SearchBarClearButtonFontSize":  "14",
                   "CheckboxMouseOverColor":  "#3DF5A0",
                   "ButtonBorderThickness":  "1",
                   "ButtonMargin":  "1",
                   "ButtonCornerRadius":  "8"
               },
    "Light":  {
                  "AppInstallUnselectedColor":  "#F7F7F7",
                  "AppInstallHighlightedColor":  "#CFCFCF",
                  "AppInstallSelectedColor":  "#C2C2C2",
                  "AppInstallOverlayBackgroundColor":  "#6A6D72",
                  "ComboBoxForegroundColor":  "#232629",
                  "ComboBoxBackgroundColor":  "#F7F7F7",
                  "LabelboxForegroundColor":  "#232629",
                  "MainForegroundColor":  "#232629",
                  "MainBackgroundColor":  "#F7F7F7",
                  "LabelBackgroundColor":  "#F7F7F7",
                  "LinkForegroundColor":  "#484848",
                  "LinkHoverForegroundColor":  "#232629",
                  "ScrollBarBackgroundColor":  "#4A4D52",
                  "ScrollBarHoverColor":  "#5A5D62",
                  "ScrollBarDraggingColor":  "#6A6D72",
                  "ProgressBarForegroundColor":  "#2E77FF",
                  "ProgressBarBackgroundColor":  "Transparent",
                  "ProgressBarTextColor":  "#232629",
                  "ButtonInstallBackgroundColor":  "#F7F7F7",
                  "ButtonTweaksBackgroundColor":  "#F7F7F7",
                  "ButtonConfigBackgroundColor":  "#F7F7F7",
                  "ButtonUpdatesBackgroundColor":  "#F7F7F7",
                  "ButtonWin11ISOBackgroundColor":  "#F7F7F7",
                  "ButtonInstallForegroundColor":  "#232629",
                  "ButtonTweaksForegroundColor":  "#232629",
                  "ButtonConfigForegroundColor":  "#232629",
                  "ButtonUpdatesForegroundColor":  "#232629",
                  "ButtonWin11ISOForegroundColor":  "#232629",
                  "ButtonBackgroundColor":  "#F5F5F5",
                  "ButtonBackgroundPressedColor":  "#1A1A1A",
                  "ButtonBackgroundMouseoverColor":  "#C2C2C2",
                  "ButtonBackgroundSelectedColor":  "#F0F0F0",
                  "ButtonForegroundColor":  "#232629",
                  "ToggleButtonOnColor":  "#2E77FF",
                  "ToggleButtonOffColor":  "#707070",
                  "ToolTipBackgroundColor":  "#F7F7F7",
                  "BorderColor":  "#232629",
                  "BorderOpacity":  "0.2"
              },
    "Dark":  {
                 "AppInstallUnselectedColor":  "#14FFFFFF",
                 "AppInstallHighlightedColor":  "#26FFFFFF",
                 "AppInstallSelectedColor":  "#403DF5A0",
                 "AppInstallOverlayBackgroundColor":  "#CC07090F",
                 "ComboBoxForegroundColor":  "#F8FAFC",
                 "ComboBoxBackgroundColor":  "#FF121724",
                 "LabelboxForegroundColor":  "#3DF5A0",
                 "MainForegroundColor":  "#F8FAFC",
                 "MainBackgroundColor":  "#E60B0E16",
                 "LabelBackgroundColor":  "#00FFFFFF",
                 "LinkForegroundColor":  "#3DF5A0",
                 "LinkHoverForegroundColor":  "#F8FAFC",
                 "ScrollBarBackgroundColor":  "#1AFFFFFF",
                 "ScrollBarHoverColor":  "#3DF5A0",
                 "ScrollBarDraggingColor":  "#2BD389",
                 "ProgressBarForegroundColor":  "#3DF5A0",
                 "ProgressBarBackgroundColor":  "Transparent",
                 "ProgressBarTextColor":  "#F8FAFC",
                 "ButtonInstallBackgroundColor":  "#59161B26",
                 "ButtonTweaksBackgroundColor":  "#59161B26",
                 "ButtonConfigBackgroundColor":  "#59161B26",
                 "ButtonUpdatesBackgroundColor":  "#59161B26",
                 "ButtonWin11ISOBackgroundColor":  "#59161B26",
                 "ButtonInstallForegroundColor":  "#F8FAFC",
                 "ButtonTweaksForegroundColor":  "#F8FAFC",
                 "ButtonConfigForegroundColor":  "#F8FAFC",
                 "ButtonUpdatesForegroundColor":  "#F8FAFC",
                 "ButtonWin11ISOForegroundColor":  "#F8FAFC",
                 "ButtonBackgroundColor":  "#1AFFFFFF",
                 "ButtonBackgroundPressedColor":  "#3DF5A0",
                 "ButtonBackgroundMouseoverColor":  "#26FFFFFF",
                 "ButtonBackgroundSelectedColor":  "#403DF5A0",
                 "ButtonForegroundColor":  "#F8FAFC",
                 "ToggleButtonOnColor":  "#3DF5A0",
                 "ToggleButtonOffColor":  "#4A5568",
                 "ToolTipBackgroundColor":  "#FF121724",
                 "BorderColor":  "#3DF5A0",
                 "BorderOpacity":  "0.10"
             }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
    "WPFTweaksActivity":  {
                              "Content":  "Activity History - Disable",
                              "Description":  "Erases recent docs, clipboard, and run history.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "EnableActivityFeed",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "PublishUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "UploadUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksHiber":  {
                           "Content":  "Hibernation - Disable",
                           "Description":  "Hibernation is really meant for laptops as it saves what\u0027s in memory before turning the PC off. It really should never be used.",
                           "category":  "Essential Tweaks",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
                                                "Name":  "HibernateEnabled",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            },
                                            {
                                                "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
                                                "Name":  "ShowHibernateOption",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            }
                                        ],
                           "InvokeScript":  [
                                                "powercfg.exe /hibernate off"
                                            ],
                           "UndoScript":  [
                                              "powercfg.exe /hibernate on"
                                          ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFTweaksWidget":  {
                            "Content":  "Widgets - Remove",
                            "Description":  "Removes the annoying widgets in the bottom left of the Taskbar.",
                            "category":  "Essential Tweaks",
                            "panel":  "1",
                            "InvokeScript":  [
                                                 "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
                                             ],
                            "UndoScript":  [
                                               "\r\n      Write-Host \"Restoring widgets AppxPackages\"\r\n\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\Microsoft.WidgetsPlatformRuntime*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\MicrosoftWindows.Client.WebExperience*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                           ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFTweaksRevertStartMenu":  {
                                     "Content":  "Start Menu Previous Layout - Enable",
                                     "Description":  "Bring back the old Start Menu layout from before the gradual rollout of the new one in 25H2.",
                                     "category":  "Essential Tweaks",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/disable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027Old start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                      ],
                                     "UndoScript":  [
                                                        "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/enable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027New start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                    ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksDisableStoreSearch":  {
                                        "Content":  "Microsoft Store Recommended Search Results - Disable",
                                        "Description":  "Will not display recommended Microsoft Store apps when searching for apps in the Start menu.",
                                        "category":  "Essential Tweaks",
                                        "panel":  "1",
                                        "InvokeScript":  [
                                                             "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
                                                         ],
                                        "UndoScript":  [
                                                           "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
                                                       ],
                                        "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                    },
    "WPFTweaksLocation":  {
                              "Content":  "Location Tracking - Disable",
                              "Description":  "Disables Location Tracking.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "lfsvc",
                                                  "StartupType":  "Disable",
                                                  "OriginalType":  "Manual"
                                              }
                                          ],
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
                                                   "Name":  "Value",
                                                   "Value":  "Deny",
                                                   "Type":  "String",
                                                   "OriginalValue":  "Allow"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
                                                   "Name":  "SensorPermissionState",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SYSTEM\\Maps",
                                                   "Name":  "AutoUpdateEnabled",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksServices":  {
                              "Content":  "Services - Set to Manual",
                              "Description":  "Turns a bunch of system services to manual that don\u0027t need to be running all the time. This is pretty harmless as if the service is needed, it will simply start on demand.",
                              "category":  "Essential Tweaks",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "CscService",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "DiagTrack",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "MapsBroker",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "RemoteAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              },
                                              {
                                                  "Name":  "RemoteRegistry",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              },
                                              {
                                                  "Name":  "StorSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "SharedAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "TermService",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "TroubleshootingSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "seclogon",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "ssh-agent",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              }
                                          ],
                              "InvokeScript":  [
                                                   "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksBraveDebloat":  {
                                  "Content":  "Brave Browser - Debloat",
                                  "Description":  "Disables various annoyances like Brave Rewards, Leo AI, Crypto Wallet and VPN.",
                                  "category":  "z__Advanced Tweaks - CAUTION",
                                  "panel":  "1",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveRewardsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveWalletDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveVPNDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveAIChatEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveStatsPingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveNewsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveTalkDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "TorDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveP3AEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "UrlKeyedAnonymizedDataCollectionEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "SafeBrowsingExtendedReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "MetricsReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFTweaksDisableWarningForUnsignedRdp":  {
                                                  "Content":  "RDP Unsigned File Warnings - Disable",
                                                  "Description":  "Disables warnings shown when launching unsigned RDP files introduced with the latest Windows 10 and 11 updates.",
                                                  "category":  "z__Advanced Tweaks - CAUTION",
                                                  "panel":  "1",
                                                  "registry":  [
                                                                   {
                                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
                                                                       "Name":  "RedirectionWarningDialogVersion",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   },
                                                                   {
                                                                       "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
                                                                       "Name":  "RdpLaunchConsentAccepted",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   }
                                                               ],
                                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                              },
    "WPFTweaksEdgeDebloat":  {
                                 "Content":  "Microsoft Edge - Debloat",
                                 "Description":  "Disables various telemetry options, popups, and other annoyances in Edge.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
                                                      "Name":  "CreateDesktopShortcutDefault",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "PersonalizationReportingEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
                                                      "Name":  "1",
                                                      "Value":  "ofefcgjbeghpigppfmkologfjadafddi",
                                                      "Type":  "String",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowRecommendationsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "HideFirstRunExperience",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "UserFeedbackAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ConfigureDoNotTrack",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "AlternateErrorPagesEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeCollectionsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeShoppingAssistantEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "MicrosoftEdgeInsiderPromotionEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowMicrosoftRewards",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WebWidgetAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DiagnosticData",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeAssetDeliveryServiceEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WalletDonationEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DefaultBrowserSettingsCampaignEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  }
                                              ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksConsumerFeatures":  {
                                      "Content":  "ConsumerFeatures - Disable",
                                      "Description":  "Windows will not automatically install any games, third-party apps, or application links from the Windows Store for the signed-in user. Some default Apps will be inaccessible (eg. Phone Link).",
                                      "category":  "Essential Tweaks",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
                                                           "Name":  "DisableWindowsConsumerFeatures",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFTweaksTelemetry":  {
                               "Content":  "Telemetry - Disable",
                               "Description":  "Disables Microsoft Telemetry.",
                               "category":  "Essential Tweaks",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
                                                    "Name":  "TailoredExperiencesWithDiagnosticDataEnabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
                                                    "Name":  "HasAccepted",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Input\\TIPC",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitInkCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitTextCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
                                                    "Name":  "HarvestContacts",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
                                                    "Name":  "AcceptedPrivacyPolicy",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
                                                    "Name":  "AllowTelemetry",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                    "Name":  "Start_TrackProgs",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "PublishUserActivities",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
                                                    "Name":  "NumberOfSIUFInPeriod",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
                                                ],
                               "UndoScript":  [
                                                  "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n      "
                                              ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFTweaksRemoveEdge":  {
                                "Content":  "Microsoft Edge - Remove",
                                "Description":  "Unblocks Microsoft Edge uninstaller restrictions then uses that uninstaller to remove Microsoft Edge.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "Invoke-WinUtilRemoveEdge"
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      Write-Host \u0027Installing Microsoft Edge...\u0027\r\n      winget install Microsoft.Edge --source winget\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksUTC":  {
                         "Content":  "Date \u0026 Time - Set Time to UTC",
                         "Description":  "Essential for computers that are dual booting. Fixes the time sync with Linux systems.",
                         "category":  "z__Advanced Tweaks - CAUTION",
                         "panel":  "1",
                         "registry":  [
                                          {
                                              "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
                                              "Name":  "RealTimeIsUniversal",
                                              "Value":  "1",
                                              "Type":  "QWord",
                                              "OriginalValue":  "0"
                                          }
                                      ],
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFTweaksRemoveOneDrive":  {
                                    "Content":  "Microsoft OneDrive - Remove",
                                    "Description":  "Denies permission to remove OneDrive user files, then uses its own uninstaller to remove it and restores the original permission afterward.",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process \u0027C:\\Windows\\System32\\OneDriveSetup.exe\u0027 -ArgumentList \u0027/uninstall\u0027 -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"C:\\ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
                                                   ],
                                    "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                },
    "WPFTweaksRemoveHome":  {
                                "Content":  "File Explorer Home - Disable",
                                "Description":  "Removes the Home from Explorer and sets This PC as default.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 1\r\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 0\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksRemoveGallery":  {
                                   "Content":  "File Explorer Gallery - Disable",
                                   "Description":  "Removes the Gallery from Explorer and sets This PC as default.",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksDisplay":  {
                             "Content":  "Visual Effects - Set to Best Performance",
                             "Description":  "Sets the system preferences to performance. You can do this manually with sysdm.cpl as well.",
                             "category":  "z__Advanced Tweaks - CAUTION",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "DragFullWindows",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "MenuShowDelay",
                                                  "Value":  "200",
                                                  "Type":  "String",
                                                  "OriginalValue":  "400"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
                                                  "Name":  "MinAnimate",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "KeyboardDelay",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewAlphaSelect",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewShadow",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarAnimations",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
                                                  "Name":  "VisualFXSetting",
                                                  "Value":  "3",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\DWM",
                                                  "Name":  "EnableAeroPeek",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarMn",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ShowTaskViewButton",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                  "Name":  "SearchboxTaskbarMode",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
                                              ],
                             "UndoScript":  [
                                                "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
                                            ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksXboxRemoval":  {
                                 "Content":  "Xbox \u0026 Gaming Components - Remove",
                                 "Description":  "Removes Xbox services, the Xbox app, Game Bar, and related authentication components.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
                                                      "Name":  "AppCaptureEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "1"
                                                  }
                                              ],
                                 "appx":  [
                                              "Microsoft.XboxIdentityProvider",
                                              "Microsoft.XboxSpeechToTextOverlay",
                                              "Microsoft.GamingApp",
                                              "Microsoft.Xbox.TCUI",
                                              "Microsoft.XboxGamingOverlay"
                                          ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDeBloat":  {
                             "Content":  "Unwanted Pre-Installed Apps - Remove",
                             "Description":  "This will remove a bunch of Windows pre-installed applications which most people dont want on there system.",
                             "category":  "Essential Tweaks",
                             "panel":  "1",
                             "appx":  [
                                          "Microsoft.WindowsFeedbackHub",
                                          "Microsoft.BingNews",
                                          "Microsoft.BingSearch",
                                          "Microsoft.BingWeather",
                                          "Clipchamp.Clipchamp",
                                          "Microsoft.Todos",
                                          "Microsoft.PowerAutomateDesktop",
                                          "Microsoft.MicrosoftSolitaireCollection",
                                          "Microsoft.WindowsSoundRecorder",
                                          "Microsoft.MicrosoftStickyNotes",
                                          "Microsoft.Windows.DevHome",
                                          "Microsoft.Paint",
                                          "Microsoft.OutlookForWindows",
                                          "Microsoft.WindowsAlarms",
                                          "Microsoft.StartExperiencesApp",
                                          "Microsoft.GetHelp",
                                          "Microsoft.ZuneMusic",
                                          "MicrosoftCorporationII.QuickAssist",
                                          "MSTeams"
                                      ],
                             "InvokeScript":  [
                                                  "\r\n      $TeamsPath = \"$Env:LocalAppData\\Microsoft\\Teams\\Update.exe\"\r\n\r\n      if (Test-Path $TeamsPath) {\r\n        Write-Host \"Uninstalling Teams\"\r\n        Start-Process $TeamsPath -ArgumentList -uninstall -wait\r\n\r\n        Write-Host \"Deleting Teams directory\"\r\n        Remove-Item $TeamsPath -Recurse -Force\r\n      }\r\n      "
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksRestorePoint":  {
                                  "Content":  "Restore Point - Create",
                                  "Description":  "Creates a restore point at runtime in case a revert is needed from WinUtil modifications.",
                                  "category":  "Essential Tweaks",
                                  "panel":  "1",
                                  "Checked":  "False",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
                                                       "Name":  "SystemRestorePointCreationFrequency",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "1440"
                                                   }
                                               ],
                                  "InvokeScript":  [
                                                       "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
                                                   ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFTweaksEndTaskOnTaskbar":  {
                                      "Content":  "End Task With Right Click - Enable",
                                      "Description":  "Enables option to end task when right clicking a program in the taskbar.",
                                      "category":  "Essential Tweaks",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
                                                           "Name":  "TaskbarEndTask",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFTweaksPowershell7Tele":  {
                                     "Content":  "PowerShell 7 Telemetry - Disable",
                                     "Description":  "Creates an Environment Variable called \u0027POWERSHELL_TELEMETRY_OPTOUT\u0027 with a value of \u00271\u0027 which will tell PowerShell 7 to not send Telemetry Data.",
                                     "category":  "Essential Tweaks",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u00271\u0027, \u0027Machine\u0027)"
                                                      ],
                                     "UndoScript":  [
                                                        "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u0027\u0027, \u0027Machine\u0027)"
                                                    ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksStorage":  {
                             "Content":  "Storage Sense - Disable",
                             "Description":  "Storage Sense deletes temp files automatically.",
                             "category":  "z__Advanced Tweaks - CAUTION",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
                                                  "Name":  "01",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksRemoveCopilot":  {
                                   "Content":  "Microsoft Copilot - Disable",
                                   "Description":  "Removes Copilot AppXPackages and related ai packages",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      Get-AppxPackage -AllUsers *Copilot* | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n      Remove-AppxPackage $Appx\r\n\r\n      Write-Host \"Copilot Removed\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      Write-Host \"Installing Copilot...\"\r\n      winget install --name Copilot --source msstore --accept-package-agreements --accept-source-agreements --silent\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksWPBT":  {
                          "Content":  "Windows Platform Binary Table (WPBT) - Disable",
                          "Description":  "If enabled, WPBT allows your computer vendor to execute programs at boot time, such as anti-theft software, software drivers, as well as force install software without user consent. Poses potential security risk.",
                          "category":  "Essential Tweaks",
                          "panel":  "1",
                          "registry":  [
                                           {
                                               "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
                                               "Name":  "DisableWpbtExecution",
                                               "Value":  "1",
                                               "Type":  "DWord",
                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                           }
                                       ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFTweaksRazerBlock":  {
                                "Content":  "Razer Software Auto-Install - Disable",
                                "Description":  "Blocks ALL Razer Software installations. The hardware works fine without any software.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
                                                     "Name":  "SearchOrderConfig",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1"
                                                 },
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
                                                     "Name":  "DisableCoInstallers",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "InvokeScript":  [
                                                     "\r\n      $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      icacls \"C:\\Windows\\Installer\\Razer\" /remove:d Everyone\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksDisableNotifications":  {
                                          "Content":  "System Tray Notifications \u0026 Calendar - Disable",
                                          "Description":  "Disables all Notifications INCLUDING Calendar.",
                                          "category":  "z__Advanced Tweaks - CAUTION",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
                                                               "Name":  "DisableNotificationCenter",
                                                               "Value":  "1",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
                                                               "Name":  "ToastEnabled",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "1"
                                                           }
                                                       ],
                                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                      },
    "WPFTweaksBlockAdobeNet":  {
                                   "Content":  "Adobe URL Block List - Enable",
                                   "Description":  "Reduces user interruptions by selectively blocking connections to Adobe\u0027s activation and telemetry servers. Credit: Ruddernation-Designs",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      $hostsUrl = \"https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\"\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Move-Item $hosts \"$hosts.bak\"\r\n      Invoke-WebRequest $hostsUrl -OutFile $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Added Adobe url block list from host file\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Remove-Item $hosts\r\n      Move-Item \"$hosts.bak\" $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Removed Adobe url block list from host file\"\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksRightClickMenu":  {
                                    "Content":  "Right-Click Menu Previous Layout - Enable",
                                    "Description":  "Restores the classic context menu when right-clicking in File Explorer, replacing the simplified Windows 11 version.",
                                    "category":  "z__Advanced Tweaks - CAUTION",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name \"InprocServer32\" -force -value \"\"\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse -Confirm:$false -Force\r\n      # Restarting Explorer in the Undo Script might not be necessary, as the Registry change without restarting Explorer does work, but just to make sure.\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                   ],
                                    "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                },
    "WPFTweaksDiskCleanup":  {
                                 "Content":  "Disk Cleanup - Run",
                                 "Description":  "Runs Disk Cleanup on Drive C: and removes old Windows Updates.",
                                 "category":  "Essential Tweaks",
                                 "panel":  "1",
                                 "InvokeScript":  [
                                                      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
                                                  ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDeleteTempFiles":  {
                                     "Content":  "Temporary Files - Remove",
                                     "Description":  "Erases TEMP Folders.",
                                     "category":  "Essential Tweaks",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
                                                      ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksIPv46":  {
                           "Content":  "IPv6 - Set IPv4 as Preferred",
                           "Description":  "Setting the IPv4 preference can have latency and security benefits on private networks where IPv6 is not configured.",
                           "category":  "z__Advanced Tweaks - CAUTION",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                "Name":  "DisabledComponents",
                                                "Value":  "32",
                                                "Type":  "DWord",
                                                "OriginalValue":  "0"
                                            }
                                        ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFTweaksTeredo":  {
                            "Content":  "Teredo - Disable",
                            "Description":  "Teredo network tunneling is an IPv6 feature that can cause additional latency, but may cause problems with some games.",
                            "category":  "z__Advanced Tweaks - CAUTION",
                            "panel":  "1",
                            "registry":  [
                                             {
                                                 "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                 "Name":  "DisabledComponents",
                                                 "Value":  "1",
                                                 "Type":  "DWord",
                                                 "OriginalValue":  "0"
                                             }
                                         ],
                            "InvokeScript":  [
                                                 "netsh interface teredo set state disabled"
                                             ],
                            "UndoScript":  [
                                               "netsh interface teredo set state default"
                                           ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFTweaksDisableIPv6":  {
                                 "Content":  "IPv6 - Disable",
                                 "Description":  "Disables IPv6.",
                                 "category":  "z__Advanced Tweaks - CAUTION",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                      "Name":  "DisabledComponents",
                                                      "Value":  "255",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                  ],
                                 "UndoScript":  [
                                                    "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDisableBGapps":  {
                                   "Content":  "Background Apps - Disable",
                                   "Description":  "Disables all Microsoft Store apps from running in the background, which has to be done individually since Windows 11.",
                                   "category":  "z__Advanced Tweaks - CAUTION",
                                   "panel":  "1",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
                                                        "Name":  "GlobalUserDisabled",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0"
                                                    }
                                                ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksDisableFSO":  {
                                "Content":  "Fullscreen Optimizations - Disable",
                                "Description":  "Disables FSO in all applications. NOTE: This will disable Color Management in Exclusive Fullscreen.",
                                "category":  "z__Advanced Tweaks - CAUTION",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\System\\GameConfigStore",
                                                     "Name":  "GameDVR_DXGIHonorFSEWindowsCompatible",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleDisableCrossDeviceResume":  {
                                              "Content":  "Cross-Device Resume",
                                              "Description":  "This tweak controls the Resume function in Windows 11 24H2 and later, which allows you to resume an activity from a mobile device and vice-versa.",
                                              "category":  "Customize Preferences",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CrossDeviceResume\\Configuration",
                                                                   "Name":  "IsResumeAllowed",
                                                                   "Value":  "1",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "0",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                          },
    "WPFToggleDetailedBSoD":  {
                                  "Content":  "BSoD Verbose Mode",
                                  "Description":  "If enabled, you will see a detailed Blue Screen of Death (BSOD) with more information.",
                                  "category":  "Customize Preferences",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisplayParameters",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisableEmoticon",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFToggleBatteryPercentage":  {
                                       "Content":  "System Tray Battery Percentage",
                                       "Description":  "If enabled, Shows numeric battery percentage next to the battery icon in the system tray.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                            "Name":  "IsBatteryPercentageEnabled",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                            "DefaultState":  "false"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleDarkMode":  {
                              "Content":  "Dark Theme for Windows",
                              "Description":  "Enable/Disable Dark Mode.",
                              "category":  "Customize Preferences",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "AppsUseLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               },
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "SystemUsesLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               }
                                           ],
                              "InvokeScript":  [
                                                   "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                               ],
                              "UndoScript":  [
                                                 "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                             ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFToggleShowExt":  {
                             "Content":  "File Explorer File Extensions",
                             "Description":  "If enabled, File extensions (e.g., .txt, .jpg) are visible.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "HideFileExt",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                              ],
                             "UndoScript":  [
                                                "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                            ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleHiddenFiles":  {
                                 "Content":  "File Explorer Hidden Files",
                                 "Description":  "If enabled, Hidden Files will be shown.",
                                 "category":  "Customize Preferences",
                                 "panel":  "2",
                                 "Type":  "Toggle",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                      "Name":  "Hidden",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0",
                                                      "DefaultState":  "false"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                  ],
                                 "UndoScript":  [
                                                    "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFToggleVerboseLogon":  {
                                  "Content":  "Logon Verbose Mode",
                                  "Description":  "Show detailed messages during the login process for troubleshooting and diagnostics.",
                                  "category":  "Customize Preferences",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
                                                       "Name":  "VerboseStatus",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFToggleNewOutlook":  {
                                "Content":  "Microsoft Outlook New Version",
                                "Description":  "If disabled, it removes the new Outlook toggle, disables the new Outlook migration, and ensures the classic Outlook application is used.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "UseNewOutlook",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "HideNewOutlookToggle",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "DoNewOutlookAutoMigration",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "false"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "NewOutlookMigrationUserSetting",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleScrollbars":  {
                                "Content":  "Scrollbars Always Visible",
                                "Description":  "If enabled, scrollbars will always be visible. If disabled, Windows will automatically hide scrollbars when not in use.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility",
                                                     "Name":  "DynamicScrollbars",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "false",
                                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleMultiplaneOverlay":  {
                                       "Content":  "Multiplane Overlay",
                                       "Description":  "Enable or disable the Multiplane Overlay, which can sometimes cause issues with graphics cards.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
                                                            "Name":  "OverlayTestMode",
                                                            "Value":  "0",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "5",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleMouseAcceleration":  {
                                       "Content":  "Mouse Acceleration",
                                       "Description":  "If enabled, the Cursor movement is affected by the speed of your physical mouse movements.",
                                       "category":  "Customize Preferences",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseSpeed",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold1",
                                                            "Value":  "6",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold2",
                                                            "Value":  "10",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleNumLock":  {
                             "Content":  "Num Lock on Startup",
                             "Description":  "Toggle the Num Lock key state when your computer starts.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKU:\\.Default\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleStandbyFix":  {
                                "Content":  "S0 Sleep Network Connectivity",
                                "Description":  "Enable or disable network connectivity during S0 Sleep.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
                                                     "Name":  "ACSettingIndex",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleS3Sleep":  {
                             "Content":  "S3 Sleep",
                             "Description":  "Toggles between Modern Standby and S3 Sleep.",
                             "category":  "Customize Preferences",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
                                                  "Name":  "PlatformAoAcOverride",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleHideSettingsHome":  {
                                      "Content":  "Settings Home Page",
                                      "Description":  "Enable or disable the Home Page in the Windows Settings app.",
                                      "category":  "Customize Preferences",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                           "Name":  "SettingsPageVisibility",
                                                           "Value":  "show:home",
                                                           "Type":  "String",
                                                           "OriginalValue":  "hide:home",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFToggleBingSearch":  {
                                "Content":  "Start Menu Bing Search",
                                "Description":  "If enabled, Bing web search results will be included in your Start Menu search.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                     "Name":  "BingSearchEnabled",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleLoginBlur":  {
                               "Content":  "Logon Screen Acrylic Blur",
                               "Description":  "If disabled, the acrylic blur effect will be removed on the Windows 10/11 login screen background.",
                               "category":  "Customize Preferences",
                               "panel":  "2",
                               "Type":  "Toggle",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "DisableAcrylicBackgroundOnLogon",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "1",
                                                    "DefaultState":  "true"
                                                }
                                            ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFToggleStartMenuRecommendations":  {
                                              "Content":  "Start Menu Recommendations",
                                              "Description":  "If disabled, then you will not see recommendations in the Start Menu. WARNING: This will also disable Windows Spotlight on your Lock Screen as a side effect.",
                                              "category":  "Customize Preferences",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
                                                                   "Name":  "IsEducationEnvironment",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "InvokeScript":  [
                                                                   "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                               ],
                                              "UndoScript":  [
                                                                 "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                             ],
                                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                          },
    "WPFToggleStickyKeys":  {
                                "Content":  "Sticky Keys",
                                "Description":  "If enabled, Sticky Keys is activated. Sticky keys is an accessibility feature of some graphical user interfaces which assists users who have physical disabilities or help users reduce repetitive strain injury.",
                                "category":  "Customize Preferences",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
                                                     "Name":  "Flags",
                                                     "Value":  "506",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "58",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleTaskbarAlignment":  {
                                      "Content":  "Taskbar Centered Icons",
                                      "Description":  "[Windows 11] If enabled, the Taskbar Items will be shown on the Center, otherwise the Taskbar Items will be shown on the Left.",
                                      "category":  "Customize Preferences",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                           "Name":  "TaskbarAl",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "0",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "InvokeScript":  [
                                                           "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                       ],
                                      "UndoScript":  [
                                                         "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                     ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFToggleTaskbarSearch":  {
                                   "Content":  "Taskbar Search Icon",
                                   "Description":  "If enabled, Search Button will be on the Taskbar.",
                                   "category":  "Customize Preferences",
                                   "panel":  "2",
                                   "Type":  "Toggle",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                        "Name":  "SearchboxTaskbarMode",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0",
                                                        "DefaultState":  "true"
                                                    }
                                                ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFToggleTaskView":  {
                              "Content":  "Taskbar Task View Icon",
                              "Description":  "If enabled, Task View Button in Taskbar will be shown.",
                              "category":  "Customize Preferences",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                   "Name":  "ShowTaskViewButton",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFOOSUbutton":  {
                          "Content":  "O\u0026O ShutUp10++ - Run",
                          "category":  "z__Advanced Tweaks - CAUTION",
                          "panel":  "1",
                          "Type":  "Button",
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFchangedns":  {
                         "Content":  "DNS - Set to:",
                         "category":  "z__Advanced Tweaks - CAUTION",
                         "panel":  "1",
                         "Type":  "Combobox",
                         "ComboItems":  "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFAddUltPerf":  {
                          "Content":  "Ultimate Performance Profile - Enable",
                          "category":  "Performance Plans",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFRemoveUltPerf":  {
                             "Content":  "Ultimate Performance Profile - Disable",
                             "category":  "Performance Plans",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksDisableExplorerAutoDiscovery":  {
                                                  "Content":  "File Explorer Automatic Folder Discovery - Disable",
                                                  "Description":  "Windows Explorer automatically tries to guess the type of the folder based on its contents, slowing down the browsing experience. WARNING! Will disable File Explorer grouping.",
                                                  "category":  "Essential Tweaks",
                                                  "panel":  "1",
                                                  "InvokeScript":  [
                                                                       "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                   ],
                                                  "UndoScript":  [
                                                                     "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                 ],
                                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                              }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window x:Class="WinRUtil.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinRUtil"
        mc:Ignorable="d"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Width="Auto"
        Height="Auto"
        MinWidth="900"
        MinHeight="640"
        Title="WinRUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="14" GlassFrameThickness="0" ResizeBorderThickness="6"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="2"/>
        <Setter Property="Padding" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <StackPanel Orientation="Horizontal">
                        <Grid Width="16" Height="16" Margin="0,0,8,0">
                            <Border x:Name="CheckBoxBorder"
                                    BorderBrush="{DynamicResource MainForegroundColor}"
                                    Background="{DynamicResource ButtonBackgroundColor}"
                                    BorderThickness="1"
                                    Width="12"
                                    Height="12"
                                    CornerRadius="2"/>
                            <Path x:Name="CheckMark"
                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                  StrokeThickness="2"
                                  Data="M 2 8 L 6 12 L 14 4"
                                  Visibility="Collapsed"/>
                        </Grid>
                        <ContentPresenter Content="{TemplateBinding Content}"
                                        VerticalAlignment="Center"
                                        HorizontalAlignment="Left"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton x:Name="ToggleButton"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup x:Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border x:Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <!-- Sidebar navigation item (glass + neon accent) -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="8,2,8,2"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="BackgroundBorder"
                                Background="Transparent"
                                BorderBrush="Transparent"
                                BorderThickness="1"
                                CornerRadius="10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Rectangle x:Name="AccentBar" Grid.Column="0" Width="3" RadiusX="2" RadiusY="2"
                                           Margin="3,7,9,7" Opacity="0"
                                           Fill="{DynamicResource ToggleButtonOnColor}"/>
                                <ContentPresenter Grid.Column="1" HorizontalAlignment="Left" VerticalAlignment="Center"
                                                  Margin="4,10,14,10"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter TargetName="AccentBar" Property="Opacity" Value="1"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="0.45" ShadowDepth="0" Color="#3DF5A0" BlurRadius="18"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse x:Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border x:Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox x:Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path x:Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse x:Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse x:Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard x:Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid x:Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" x:Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse x:Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Taglia"/>
                                                    <MenuItem Command="Copy" Header="Copia"/>
                                                    <MenuItem Command="Paste" Header="Incolla"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <!-- Glass root -->
    <Border CornerRadius="14" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1">
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#FF0B0E16" Offset="0"/>
                <GradientStop Color="#FF07090F" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
    <Grid Background="Transparent" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Row="0" Grid.RowSpan="3" Grid.Column="0" Background="#26000000"
                BorderBrush="{DynamicResource BorderColor}" BorderThickness="0,0,1,0">
            <DockPanel LastChildFill="False" Margin="0,0,0,12">
                <!-- Brand -->
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,18,16,16">
                    <Ellipse Width="11" Height="11" Margin="0,0,10,0">
                        <Ellipse.Fill>
                            <RadialGradientBrush>
                                <GradientStop Color="#3DF5A0" Offset="0"/>
                                <GradientStop Color="#1FAE78" Offset="1"/>
                            </RadialGradientBrush>
                        </Ellipse.Fill>
                        <Ellipse.Effect><DropShadowEffect Color="#3DF5A0" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
                    </Ellipse>
                    <TextBlock Text="WinRUtil" FontSize="19" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Name="NavLogoPanel" DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,0,16,0"/>
                <!-- Navigation -->
                <StackPanel Name="NavDockPanel" DockPanel.Dock="Top" Orientation="Vertical" Margin="6,6,6,0">
                    <ToggleButton Name="WPFTab7BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7F8;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Sistema" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab1BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE896;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Installa" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab2BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE90F;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Ottimizza" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab3BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xEC7A;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Configura" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab4BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE895;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Aggiornamenti" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab6BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE749;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Stampanti" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab8BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE701;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Wi-Fi" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab5BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE753;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Crea Win11" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Grid.Column="1" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Modalità offline - Nessuna connessione a Internet" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Grid.Column="1" Name="WPFTitleBar" Background="Transparent">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/> <!-- Draggable title area -->
                <ColumnDefinition Width="Auto"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Draggable title area -->
            <StackPanel Grid.Column="0" Orientation="Vertical" VerticalAlignment="Center" Margin="22,10,10,6">
                <TextBlock Name="WPFCurrentTabTitle" Text="Installa" FontSize="17" FontWeight="SemiBold"
                           Foreground="{DynamicResource MainForegroundColor}"/>
                <TextBlock Text="Strumenti per Windows" FontSize="11"
                           Foreground="{DynamicResource ToggleButtonOffColor}"/>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,0,0" Width="{DynamicResource SearchBarWidth}" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Left">
                    <Grid>
                        <TextBox
                            Width="{DynamicResource SearchBarWidth}"
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Left"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="Premi Ctrl-F e digita il nome di un'app per filtrare l'elenco. Premi Esc per azzerare il filtro">
                        </TextBox>
                        <TextBlock
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="213,0,0,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Cambia il tema dell'interfaccia"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Segui il tema di Windows"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Scuro" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usa il tema scuro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Chiaro" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usa il tema chiaro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Regola la dimensione del testo per l'accessibilità"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Dimensione testo"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Piccolo"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="Grande"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Ripristina"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Applica"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Importa" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Importa la configurazione da un file esportato."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Esporta" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Esporta gli elementi selezionati e copia il comando negli appunti."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Informazioni" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Documentazione" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                    Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="{DynamicResource MainBackgroundColor}"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,0,0,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="1" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Selezioni consigliate:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Standard " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" Minima " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" Azzera " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" Rileva ottimizzazioni attive " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Nota: passa il mouse sopra le voci per una descrizione. Fai attenzione: molte di queste ottimizzazioni modificano profondamente il sistema.
                                        <LineBreak/>Le selezioni consigliate sono pensate per utenti normali: se hai dubbi, NON selezionare altro!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Applica ottimizzazioni" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="Annulla ottimizzazioni selezionate" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Impostazioni predefinite"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configurazione predefinita di Windows Update</Run>
                                        <LineBreak/>
                                         - Nessuna modifica ai valori predefiniti di Windows
                                        <LineBreak/>
                                         - Rimuove le impostazioni di aggiornamento personalizzate
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Nota: ripristina le impostazioni di Windows Update ai valori predefiniti di fabbrica. Rimuove QUALSIASI criterio o personalizzazione applicata a Windows Update.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Impostazioni di sicurezza"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configurazione di sicurezza bilanciata</Run>
                                        <LineBreak/>
                                         - Aggiornamenti delle funzionalità ritardati di 365 giorni
                                        <LineBreak/>
                                         - Aggiornamenti di sicurezza installati dopo 4 giorni
                                        <LineBreak/>
                                         - Impedisce a Windows Update di installare driver
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">Aggiornamenti funzionalità:</Run> nuove funzionalità e possibili bug
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">Aggiornamenti di sicurezza:</Run> patch di sicurezza critiche
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">Nota: si applica solo ai sistemi Pro che possono usare i criteri di gruppo.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Disabilita tutti gli aggiornamenti"
                                            Foreground="Red"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="Red">!! Sconsigliato !!</Run>
                                        <LineBreak/>
                                         - Disabilita TUTTI gli aggiornamenti di Windows
                                        <LineBreak/>
                                         - Aumenta i rischi per la sicurezza
                                        <LineBreak/>
                                         - Usare solo su sistemi isolati
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Avviso: senza aggiornamenti di sicurezza il sistema sarà vulnerabile.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Win11ISO" Visibility="Collapsed" Name="WPFTab5">
                <Grid Name="Win11ISOPanel" Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- Steps 1-4 -->
                        <RowDefinition Height="*"/>     <!-- Log / Status -->
                    </Grid.RowDefinitions>

                    <!-- Steps 1-4 -->
                    <StackPanel Grid.Row="0">

                            <!-- STEP 1 : Select Windows 11 ISO -->
                            <Grid Name="WPFWin11ISOSelectSection" Margin="5" HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: File Selector -->
                                <StackPanel Grid.Column="0" Margin="5,5,15,5">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Passo 1 - Seleziona la ISO di Windows 11
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,6">
                                        Sfoglia fino al file ISO di Windows 11 salvato sul computer. Sono supportate solo
                                        le ISO ufficiali scaricate da Microsoft.
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" FontStyle="Italic">
                                        <Run FontWeight="Bold">NOTA:</Run> pensato solo per installazioni pulite e nuove di Windows.
                                    </TextBlock>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox Grid.Column="0"
                                                 Name="WPFWin11ISOPath"
                                                 IsReadOnly="True"
                                                 VerticalAlignment="Center"
                                                 Padding="6,4"
                                                 Margin="0,0,6,0"
                                                 Text="Nessuna ISO selezionata..."
                                                 Foreground="{DynamicResource MainForegroundColor}"
                                                 Background="{DynamicResource MainBackgroundColor}"/>
                                        <Button Grid.Column="1"
                                                Name="WPFWin11ISOBrowseButton"
                                                Content="Sfoglia"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </Grid>
                                    <TextBlock Name="WPFWin11ISOFileInfo"
                                               FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               Margin="0,8,0,0"
                                               TextWrapping="Wrap"
                                               Visibility="Collapsed"/>
                                </StackPanel>

                                <!-- Right: Download guidance -->
                                <Border Grid.Column="1"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Margin="5" Padding="15">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="OrangeRed" Margin="0,0,0,10">
                                            !!ATTENZIONE!! Devi usare una ISO ufficiale Microsoft
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            Scarica la ISO di Windows 11 direttamente da Microsoft.com.
                                            Le immagini di terze parti, pre-modificate o non ufficiali non sono supportate
                                            e possono dare risultati difettosi.
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,6">
                                            Nella pagina di download Microsoft, scegli:
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="12,0,0,12">
                                            - Edizione : Windows 11
                                            <LineBreak/>- Lingua : la lingua preferita
                                            <LineBreak/>- Architettura : 64-bit (x64)
                                        </TextBlock>
                                        <Button Name="WPFWin11ISODownloadLink"
                                                Content="Apri pagina download Microsoft"
                                                HorizontalAlignment="Left"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- STEP 2 : Mount and Verify ISO -->
                            <Grid Name="WPFWin11ISOMountSection"
                                  Margin="5"
                                  Visibility="Collapsed"
                                  HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,20,0" VerticalAlignment="Top">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        Passo 2 - Monta e verifica la ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="320">
                                        Monta la ISO e verifica che contenga un install.wim di Windows 11
                                        valido prima di applicare qualsiasi modifica.
                                    </TextBlock>
                                    <Button Name="WPFWin11ISOMountButton"
                                            Content="Monta e verifica ISO"
                                            HorizontalAlignment="Left"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <CheckBox Name="WPFWin11ISOInjectDrivers"
                                              Content="Inietta i driver di sistema correnti"
                                              FontSize="{DynamicResource FontSize}"
                                              Foreground="{DynamicResource MainForegroundColor}"
                                              IsChecked="False"
                                              Margin="0,8,0,0"
                                              ToolTip="Esporta tutti i driver di questo computer e li inietta in install.wim e boot.wim. Consigliato per sistemi con controller NVMe o di rete non supportati."/>
                                </StackPanel>

                                <!-- Verification results panel -->
                                <Border Grid.Column="1"
                                        Name="WPFWin11ISOVerifyResultPanel"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,0"
                                        Visibility="Collapsed">
                                    <StackPanel>
                                        <TextBlock Name="WPFWin11ISOMountDriveLetter"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock Name="WPFWin11ISOArchLabel"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,6,0,4">
                                            Seleziona edizione:
                                        </TextBlock>
                                        <ComboBox Name="WPFWin11ISOEditionComboBox"
                                                  FontSize="{DynamicResource FontSize}"
                                                  Foreground="{DynamicResource MainForegroundColor}"
                                                  Background="{DynamicResource MainBackgroundColor}"
                                                  HorizontalAlignment="Left"
                                                  Margin="0,0,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- STEP 3 : Modify install.wim -->
                            <StackPanel Name="WPFWin11ISOModifySection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                    Passo 3 - Modifica install.wim
                                </TextBlock>
                                <TextBlock FontSize="{DynamicResource FontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,0,0,12">
                                    Il contenuto della ISO verrà estratto in una cartella di lavoro temporanea,
                                    install.wim verrà modificato (componenti rimossi, ottimizzazioni applicate)
                                    e il risultato verrà riassemblato. L'operazione può richiedere diversi minuti
                                    a seconda dell'hardware.
                                </TextBlock>
                                <Button Name="WPFWin11ISOModifyButton"
                                        Content="Avvia modifica e creazione ISO Windows"
                                        HorizontalAlignment="Left"
                                        Width="Auto" Padding="12,0"
                                        Height="{DynamicResource ButtonHeight}"/>
                            </StackPanel>

                            <!-- STEP 4 : Output Options -->
                            <StackPanel Name="WPFWin11ISOOutputSection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <!-- Header row: title + Clean & Reset button -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               VerticalAlignment="Center">
                                        Passo 4 - Output: cosa vuoi fare con l'immagine modificata?
                                    </TextBlock>
                                    <Button Grid.Column="1"
                                            Name="WPFWin11ISOCleanResetButton"
                                            Content="Pulisci e reimposta"
                                            Foreground="OrangeRed"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"
                                            ToolTip="Elimina la cartella di lavoro temporanea e riporta l'interfaccia al Passo 1"
                                            Margin="12,0,0,0"/>
                                </Grid>

                                <!-- Choice prompt buttons -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button Grid.Column="0"
                                            Name="WPFWin11ISOChooseISOButton"
                                            Content="Salva come file ISO"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <Button Grid.Column="2"
                                            Name="WPFWin11ISOChooseUSBButton"
                                            Content="Scrivi direttamente su unità USB (CANCELLA L'UNITÀ)"
                                            Foreground="OrangeRed"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                </Grid>

                                <!-- USB write sub-panel (revealed on USB choice) -->
                                <Border Name="WPFWin11ISOOptionUSB"
                                        Style="{StaticResource BorderStyle}"
                                        Visibility="Collapsed"
                                        Margin="0,8,0,0">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            <Run FontWeight="Bold" Foreground="OrangeRed">!! Tutti i dati sull'unità USB selezionata verranno cancellati definitivamente !!</Run>
                                            <LineBreak/>
                                            Seleziona qui sotto un'unità USB rimovibile, poi clicca Cancella e scrivi.
                                        </TextBlock>
                                        <!-- USB drive selector row -->
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Grid.Column="0"
                                                      Name="WPFWin11ISOUSBDriveComboBox"
                                                      Foreground="{DynamicResource MainForegroundColor}"
                                                      Background="{DynamicResource MainBackgroundColor}"
                                                      VerticalAlignment="Center"
                                                      Margin="0,0,6,0"/>
                                            <Button Grid.Column="1"
                                                    Name="WPFWin11ISORefreshUSBButton"
                                                    Content="Aggiorna"
                                                    Width="Auto" Padding="8,0"
                                                    Height="{DynamicResource ButtonHeight}"/>
                                        </Grid>
                                        <Button Name="WPFWin11ISOWriteUSBButton"
                                                Content="Cancella e scrivi su USB"
                                                Foreground="OrangeRed"
                                                HorizontalAlignment="Stretch"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"
                                                Margin="0,0,0,10"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                    </StackPanel>

                    <!-- Status Log (fills remaining height) -->
                    <Grid Grid.Row="1" Margin="5">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0"
                                   FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                   Foreground="{DynamicResource MainForegroundColor}"
                                   Margin="0,0,0,4">
                            Registro attività
                        </TextBlock>
                        <TextBox Grid.Row="1"
                                 Name="WPFWin11ISOStatusLog"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Visible"
                                 VerticalAlignment="Stretch"
                                 Padding="6"
                                 Background="{DynamicResource MainBackgroundColor}"
                                 Foreground="{DynamicResource MainForegroundColor}"
                                 BorderBrush="{DynamicResource BorderColor}"
                                 BorderThickness="1"
                                 Text="Pronto. Seleziona una ISO di Windows 11 per iniziare."/>
                    </Grid>

                </Grid>
            </TabItem>
            <TabItem Header="Printers" Visibility="Collapsed" Name="WPFTab6">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Action toolbar -->
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,6,6,6">
                        <StackPanel Orientation="Vertical">
                            <TextBlock Text="Driver stampanti e code" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,2"/>
                            <TextBlock Text="Rileva le stampanti, installa o aggiorna i driver e gestisci lo spooler di stampa."
                                       FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}" Margin="0,0,0,12"/>
                            <WrapPanel Orientation="Horizontal">
                                <Button Name="WPFPrinterRefresh" Content="Aggiorna elenco" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterRestartSpooler" Content="Riavvia spooler" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterClearQueue" Content="Svuota coda di stampa" Width="Auto" MinWidth="160" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterInstallDriver" Content="Installa driver (INF)" Width="Auto" MinWidth="150" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterRemoveDriver" Content="Rimuovi driver" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                            </WrapPanel>
                        </StackPanel>
                    </Border>

                    <!-- Printer list -->
                    <Border Grid.Row="1" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="8" Margin="6,2,6,6">
                        <DataGrid Name="WPFPrinterList" AutoGenerateColumns="False" IsReadOnly="True"
                                  Background="Transparent" BorderThickness="0" RowBackground="Transparent" AlternatingRowBackground="#14FFFFFF"
                                  Foreground="{DynamicResource MainForegroundColor}" GridLinesVisibility="None"
                                  HeadersVisibility="Column" CanUserAddRows="False" SelectionMode="Single">
                            <DataGrid.Resources>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Padding" Value="6,4"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                    <Setter Property="HorizontalContentAlignment" Value="Left"/>
                                </Style>
                            </DataGrid.Resources>
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Stampante" Binding="{Binding Name}" Width="2*"/>
                                <DataGridTextColumn Header="Driver" Binding="{Binding Driver}" Width="2*"/>
                                <DataGridTextColumn Header="Porta" Binding="{Binding Port}" Width="*"/>
                                <DataGridTextColumn Header="Stato" Binding="{Binding Status}" Width="Auto"/>
                                <DataGridTextColumn Header="In coda" Binding="{Binding Jobs}" Width="Auto"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Border>

                    <!-- Status log -->
                    <Border Grid.Row="2" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="10" Margin="6,2,6,6">
                        <StackPanel>
                            <TextBlock Text="Registro attività" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,4"/>
                            <TextBox Name="WPFPrinterStatusLog" IsReadOnly="True" TextWrapping="Wrap" Height="90"
                                     VerticalScrollBarVisibility="Auto" Background="Transparent"
                                     Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                     BorderThickness="1" Padding="6"
                                     Text="Pronto. Clicca 'Aggiorna elenco' per rilevare le stampanti installate."/>
                        </StackPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="System" Visibility="Collapsed" Name="WPFTab7">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Toolbar -->
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,13" Margin="6,6,6,6">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Orientation="Vertical" VerticalAlignment="Center">
                                <TextBlock Text="Panoramica del sistema" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}"/>
                                <TextBlock Text="Diagnostica hardware, stato di Windows e attivazione, in tempo reale."
                                           FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}" Margin="0,2,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                <Button Name="WPFSystemInfoRefresh" Content="Aggiorna" MinWidth="104" Margin="0,0,8,0" Padding="12,0"/>
                                <Button Name="WPFSystemInfoExport" Content="Esporta report" MinWidth="128" Padding="12,0"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="6,0,6,6">

                            <!-- HERO: Windows status -->
                            <Border CornerRadius="16" BorderThickness="1" Margin="0,2,0,6" Padding="22,20">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#243DF5A0" Offset="0"/>
                                        <GradientStop Color="#0C121724" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                                <Border.BorderBrush>
                                    <SolidColorBrush Color="#3D3DF5A0"/>
                                </Border.BorderBrush>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>

                                    <!-- Icon disc -->
                                    <Border Grid.Column="0" Width="58" Height="58" CornerRadius="15" Background="#1F3DF5A0"
                                            VerticalAlignment="Top" Margin="0,2,18,0">
                                        <TextBlock Text="&#xE7F8;" FontFamily="Segoe MDL2 Assets" FontSize="27" Foreground="#3DF5A0"
                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>

                                    <!-- Edition + build + mini stats -->
                                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                        <TextBlock Name="WPFSysOSCaption" Text="Windows" FontSize="22" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap"/>
                                        <TextBlock Name="WPFSysOSBuild" Text="Caricamento in corso..." FontSize="13"
                                                   Foreground="{DynamicResource ToggleButtonOffColor}" Margin="0,3,0,0"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                                            <StackPanel Orientation="Vertical" Margin="0,0,30,0">
                                                <TextBlock Text="NOME PC" FontSize="10" FontWeight="SemiBold" Foreground="#7F8A9E"/>
                                                <TextBlock Name="WPFSysHostname" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Orientation="Vertical" Margin="0,0,30,0">
                                                <TextBlock Text="ACCESO DA" FontSize="10" FontWeight="SemiBold" Foreground="#7F8A9E"/>
                                                <TextBlock Name="WPFSysUptime" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Orientation="Vertical">
                                                <TextBlock Text="INSTALLATO IL" FontSize="10" FontWeight="SemiBold" Foreground="#7F8A9E"/>
                                                <TextBlock Name="WPFSysInstallDate" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                        </StackPanel>
                                    </StackPanel>

                                    <!-- Activation pill -->
                                    <Border Grid.Column="2" Name="WPFSysActivationPill" CornerRadius="20" Background="#1F3DF5A0"
                                            Padding="15,9" VerticalAlignment="Top" Margin="14,2,0,0">
                                        <StackPanel Orientation="Horizontal">
                                            <Ellipse Name="WPFSysActivationDot" Width="9" Height="9" Fill="#3DF5A0"
                                                     VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBlock Name="WPFSysActivation" Text="Verifica..." FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                </Grid>
                            </Border>

                            <!-- CARDS -->
                            <WrapPanel Orientation="Horizontal">

                                <!-- Hardware -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE977;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="HARDWARE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Produttore" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysManufacturer" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Modello" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysModel" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="N. di serie" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysSerial" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="BIOS / UEFI" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBios" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Secure Boot" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysSecureBoot" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="TPM" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysTpm" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- CPU -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE950;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="PROCESSORE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysCpuName" Text="-" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Core / Thread" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuCores" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,12">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Frequenza base" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuClock" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,5">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Carico attuale" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuLoad" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="#3DF5A0" TextAlignment="Right"/>
                                        </Grid>
                                        <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True">
                                            <Grid Name="WPFSysCpuLoadBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                            </Grid>
                                        </Border>
                                    </StackPanel>
                                </Border>

                                <!-- RAM -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE964;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="MEMORIA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysRamText" Text="-" FontSize="20" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,10"/>
                                        <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True" Margin="0,0,0,12">
                                            <Grid Name="WPFSysRamBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                            </Grid>
                                        </Border>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Disponibile" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysRamFree" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Moduli" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysRamModules" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Storage -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <Grid Margin="0,0,0,14">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0" Orientation="Horizontal">
                                                <TextBlock Text="&#xEDA2;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                           VerticalAlignment="Center" Margin="0,0,9,0"/>
                                                <TextBlock Text="ARCHIVIAZIONE" FontSize="11" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                            </StackPanel>
                                            <TextBlock Grid.Column="1" Name="WPFSysDiskHealth" Text="-" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="#3DF5A0" VerticalAlignment="Center"/>
                                        </Grid>
                                        <StackPanel Name="WPFSysDisk0" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk0Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk0Text" Text="-" FontSize="11" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk0Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk1" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk1Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk1Text" Text="-" FontSize="11" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk1Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk2" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk2Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk2Text" Text="-" FontSize="11" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk2Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk3" Visibility="Collapsed">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk3Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk3Text" Text="-" FontSize="11" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk3Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>

                                <!-- GPU -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="GRAFICA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysGpuName" Text="-" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Memoria video" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuVram" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Risoluzione" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuResolution" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Driver" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuDriver" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Network -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE968;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="RETE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Scheda" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetAdapter" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Indirizzo IPv4" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetIp" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="#3DF5A0" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Indirizzo MAC" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetMac" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Stato" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetStatus" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Battery -->
                                <Border Name="WPFSysBatteryCard" Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6" Visibility="Collapsed">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE83F;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#3DF5A0"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="BATTERIA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource ToggleButtonOffColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysBatteryCharge" Text="-" FontSize="20" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,10"/>
                                        <Border CornerRadius="4" Height="8" Background="#1AFFFFFF" ClipToBounds="True" Margin="0,0,0,12">
                                            <Grid Name="WPFSysBatteryBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="#3DF5A0"/>
                                            </Grid>
                                        </Border>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Stato" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBatteryStatus" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Salute (usura)" FontSize="12" Foreground="{DynamicResource ToggleButtonOffColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBatteryHealth" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                            </WrapPanel>

                            <!-- Status log -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,4,6,6">
                                <StackPanel>
                                    <TextBlock Text="Registro attività" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,6"/>
                                    <TextBox Name="WPFSystemLog" IsReadOnly="True" TextWrapping="Wrap" Height="80"
                                             VerticalScrollBarVisibility="Auto" Background="Transparent"
                                             Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                             BorderThickness="1" Padding="6"
                                             Text="Pronto. Clicca 'Aggiorna' per rilevare le informazioni di sistema."/>
                                </StackPanel>
                            </Border>

                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="WiFi" Visibility="Collapsed" Name="WPFTab8">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,6,6,6">
                        <StackPanel Orientation="Vertical">
                            <TextBlock Text="Password Wi-Fi salvate" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,2"/>
                            <TextBlock Text="Recupera le chiavi delle reti Wi-Fi memorizzate su questo PC." FontSize="12"
                                       Foreground="{DynamicResource ToggleButtonOffColor}" Margin="0,0,0,12"/>
                            <WrapPanel Orientation="Horizontal">
                                <Button Name="WPFWifiRefresh" Content="Scansiona reti Wi-Fi" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFWifiCopyAll" Content="Copia tutte" Width="Auto" MinWidth="110" Margin="0,0,8,8" Padding="12,0"/>
                            </WrapPanel>
                        </StackPanel>
                    </Border>
                    <Border Grid.Row="1" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="8" Margin="6,2,6,6">
                        <DataGrid Name="WPFWifiList" AutoGenerateColumns="False" IsReadOnly="True"
                                  Background="Transparent" BorderThickness="0" RowBackground="Transparent" AlternatingRowBackground="#14FFFFFF"
                                  Foreground="{DynamicResource MainForegroundColor}" GridLinesVisibility="None"
                                  HeadersVisibility="Column" CanUserAddRows="False" SelectionMode="Single">
                            <DataGrid.Resources>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Padding" Value="6,4"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                    <Setter Property="HorizontalContentAlignment" Value="Left"/>
                                </Style>
                            </DataGrid.Resources>
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Rete (SSID)" Binding="{Binding Ssid}" Width="2*"/>
                                <DataGridTemplateColumn Header="Password" Width="2*">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                                <ToggleButton x:Name="WifiEye" Background="Transparent" BorderThickness="0"
                                                              Padding="0" Margin="0,0,8,0" Cursor="Hand"
                                                              ToolTip="Mostra/Nascondi password" VerticalAlignment="Center"
                                                              Focusable="True">
                                                    <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7B3;" FontSize="14"
                                                               Foreground="{DynamicResource MainForegroundColor}"/>
                                                </ToggleButton>
                                                <TextBlock x:Name="WifiMasked" Text="&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;"
                                                           VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"
                                                           Visibility="Visible"/>
                                                <TextBlock x:Name="WifiClear" Text="{Binding Password}"
                                                           VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"
                                                           Visibility="Collapsed"/>
                                            </StackPanel>
                                            <DataTemplate.Triggers>
                                                <DataTrigger Binding="{Binding IsChecked, ElementName=WifiEye}" Value="True">
                                                    <Setter TargetName="WifiMasked" Property="Visibility" Value="Collapsed"/>
                                                    <Setter TargetName="WifiClear" Property="Visibility" Value="Visible"/>
                                                </DataTrigger>
                                            </DataTemplate.Triggers>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="Sicurezza" Binding="{Binding Security}" Width="*"/>
                                <DataGridTextColumn Header="Auto" Binding="{Binding AutoConnect}" Width="Auto"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Border>
                    <Border Grid.Row="2" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="10" Margin="6,2,6,6">
                        <StackPanel>
                            <TextBlock Text="Registro attività" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,4"/>
                            <TextBox Name="WPFWifiStatusLog" IsReadOnly="True" TextWrapping="Wrap" Height="90"
                                     VerticalScrollBarVisibility="Auto" Background="Transparent"
                                     Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                     BorderThickness="1" Padding="6"
                                     Text="Pronto. Clicca 'Scansiona reti Wi-Fi' per elencare le reti salvate."/>
                        </StackPanel>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
    </Border>
</Window>

'@
$WinUtilAutounattendXml = @'

'@
# Create enums
Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@

# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$debugVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'DebugPreference',$DebugPreference,$Null
$uiVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_NOUI',$PARAM_NOUI,$Null
$offlineVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE',$PARAM_OFFLINE,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)
$InitialSessionState.Variables.Add($debugVar)
$InitialSessionState.Variables.Add($uiVar)
$InitialSessionState.Variables.Add($offlineVar)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

class WingetFailedInstall : Exception {
    [string]$additionalData
    WingetFailedInstall($Message) : base($Message) {}
}

class ChocoFailedInstall : Exception {
    [string]$additionalData
    ChocoFailedInstall($Message) : base($Message) {}
}

class GenericException : Exception {
    [string]$additionalData
    GenericException($Message) : base($Message) {}
}

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

Set-Preferences

if ($PARAM_NOUI) {
    Show-WinRUtilLogo
    if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            Invoke-WinUtilAutoRun
        }
        else {
            Write-Host "Did you forget to add '--Run'?";
        }
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
    else {
        Write-Host "Cannot automatically run without a config file provided."
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
}

$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Now call the function with the final merged config
Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
Initialize-WPFUI -targetGridName "appscategory"

Initialize-WPFUI -targetGridName "appspanel"

Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2

Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2

# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

#Persist Package Manager preference across winutil restarts
$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Choco
    Set-Preferences -save
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Winget
    Set-Preferences -save
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                    Write-Debug "Opening: $($Sender.ToolTip)"
                })
            }

        }
    }
}

#===========================================================================
# Setup background config
#===========================================================================

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = $oldProgressPreference
    }

} | Out-Null

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Print the logo
Show-WinRUtilLogo

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
            "S" { Invoke-WPFButton "WPFTab7BT"; $keyEventArgs.Handled = $true } # Navigate to System dashboard
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Write-Debug "WinUtil lost focus"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Print the screen size
        Write-Debug "Primary Monitor Width: $screenWidth pixels"
        Write-Debug "Primary Monitor Height: $screenHeight pixels"

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            Write-Debug "The specified width and/or height is greater than the primary monitor size."
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        } else {
            Write-Debug "The specified width and height are within the primary monitor size limits."
        }
    } else {
        Write-Debug "Unable to retrieve information about the primary monitor."
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications"

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab7BT"  # Switch to System dashboard instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab7BT"  # Default to System dashboard
    }

    $sync["Form"].Focus()

   if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            Invoke-WinUtilAutoRun
        }
    }

})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

$sync["Form"].Add_Loaded({
    param($e)
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

# WinRUtil brand is rendered in the sidebar header (XAML); no external logo asset injected.
$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")


if (Test-Path "$winutildir\logo.ico") {
    $sync["logorender"] = "$winutildir\logo.ico"
} else {
    $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
}
$sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
$sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Write-Debug "ThemeButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Write-Debug "Dark Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Write-Debug "Light Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Write-Debug "SettingsButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Write-Debug "Import clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Write-Debug "Export clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
WinRUtil — Windows toolkit
Maintainer : <a href="https://github.com/rtecnocopy89">@rtecnocopy89</a>
GitHub     : <a href="https://github.com/rtecnocopy89/WinRUtil">rtecnocopy89/WinRUtil</a>
Copyright  : © 2026 rtecnocopy89 — © 2022 CT Tech Group LLC
Based on   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a> (MIT)
Version    : $($sync.version)
"@
    Show-CustomDialog -Title "Informazioni" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Write-Debug "Documentation clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://github.com/rtecnocopy89/WinRUtil"
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Write-Debug "FontScalingButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    Write-Debug "FontScalingResetButton clicked"
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    Write-Debug "FontScalingApplyButton clicked"
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# ── Win11ISO Tab button handlers ──────────────────────────────────────────────

$sync["WPFTab5BT"].Add_Click({
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
})

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Write-Debug "WPFWin11ISOBrowseButton clicked"
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Write-Debug "WPFWin11ISODownloadLink clicked"
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Write-Debug "WPFWin11ISOMountButton clicked"
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Write-Debug "WPFWin11ISOModifyButton clicked"
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    Write-Debug "WPFWin11ISOChooseISOButton clicked"
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISOChooseUSBButton clicked"
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISORefreshUSBButton clicked"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Write-Debug "WPFWin11ISOWriteUSBButton clicked"
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Write-Debug "WPFWin11ISOCleanResetButton clicked"
    Invoke-WinUtilISOCleanAndReset
})

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Stop-Transcript