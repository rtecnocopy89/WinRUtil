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
$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}

Set-Preferences

if ($PARAM_NOUI) {
    Show-WinRUtilLogo
    if ($PARAM_PRESET -or ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG))) {
        if ($PARAM_PRESET) {
            Write-Host "Selecting the $PARAM_PRESET preset..."
            $null = Update-WinUtilSelections -flatJson $sync.configs.preset.$PARAM_PRESET
        }
        if ($PARAM_CONFIG) {
            Write-Host "Running config file tasks..."
            # A preset given together with the configuration is kept, the configuration adds to it
            Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG -Merge:([bool]$PARAM_PRESET)
        }
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
        Write-Host "Cannot automatically run without a config file or a preset provided."
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

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme,
# and to keep the maximized window inside the work area of its monitor
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
        # WM_GETMINMAXINFO (0x0024): a window without a frame is maximized over the whole monitor, so the
        # taskbar would cover its bottom (the buttons of the Tweaks tab); maximize it to the work area instead.
        # MINMAXINFO is made of POINTs (two Int32): ptMaxSize is at offset 8, ptMaxPosition at offset 16.
        if ($msg -eq 0x0024) {
            $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 8, $screen.WorkingArea.Width)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 12, $screen.WorkingArea.Height)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 16, $screen.WorkingArea.Left - $screen.Bounds.Left)
            [System.Runtime.InteropServices.Marshal]::WriteInt32($lParam, 20, $screen.WorkingArea.Top - $screen.Bounds.Top)
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

Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2

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
    Stop-WinUtilSystemLiveUpdate
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
        "Escape" {
            $sync.SearchBar.Text = ""
            if ($sync.WPFWifiQrOverlay.Visibility -eq "Visible") { Invoke-WPFWifiQrClose }
            if ($sync.WPFUpgradeOverlay.Visibility -eq "Visible") { Invoke-WPFUpgradeClose }
        }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "P" { Invoke-WPFButton "WPFTab6BT"; $keyEventArgs.Handled = $true } # Navigate to Printers tab
            "S" { Invoke-WPFButton "WPFTab7BT"; $keyEventArgs.Handled = $true } # Navigate to System dashboard
            "F" { Invoke-WPFButton "WPFTab8BT"; $keyEventArgs.Handled = $true } # Navigate to Wi-Fi tab
            "R" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Report tab
            "A" { Invoke-WPFButton "WPFTab9BT"; $keyEventArgs.Handled = $true } # Navigate to Windows apps tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
            # Text size, in the steps of the slider: bigger, smaller, normal
            { $_ -in "OemPlus", "Add" } { Set-WinUtilFontScaleStep -Step 0.25; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Set-WinUtilFontScaleStep -Step -0.25; $keyEventArgs.Handled = $true }
            { $_ -in "D0", "NumPad0" } { Set-WinUtilFontScaleStep -Step 0; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

# Ctrl + mouse wheel changes the text size too
$sync["Form"].Add_PreviewMouseWheel({
    if ([System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
        Set-WinUtilFontScaleStep -Step $(if ($_.Delta -gt 0) { 0.25 } else { -0.25 })
        $_.Handled = $true
    }
})

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
    # Keep the window inside the work area of its monitor (the screen without the taskbar), so that
    # the bottom of every tab stays visible. The work area is in pixels, the window size in WPF units.
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $sync.Form).Handle
    $workArea = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
    $toWpf = [System.Windows.PresentationSource]::FromVisual($sync.Form).CompositionTarget.TransformFromDevice
    $workWidth = $workArea.Width * $toWpf.M11
    $workHeight = $workArea.Height * $toWpf.M22
    Write-Debug "Work area of the monitor: $workWidth x $workHeight"

    if ($sync.Form.ActualWidth -gt $workWidth -or $sync.Form.ActualHeight -gt $workHeight) {
        Write-Debug "The window is larger than the work area of the monitor: resizing it."
        $width = [Math]::Min($sync.Form.ActualWidth, $workWidth)
        $height = [Math]::Min($sync.Form.ActualHeight, $workHeight)
        $sync.Form.MinWidth = [Math]::Min($sync.Form.MinWidth, $width)
        $sync.Form.MinHeight = [Math]::Min($sync.Form.MinHeight, $height)
        $sync.Form.Width = $width
        $sync.Form.Height = $height
        $sync.Form.Left = $workArea.Left * $toWpf.M11 + ($workWidth - $width) / 2
        $sync.Form.Top = $workArea.Top * $toWpf.M22 + ($workHeight - $height) / 2
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Connessione a Internet necessaria per installare le applicazioni"

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

    if ($PARAM_PRESET) {
        Write-Host "Selecting the $PARAM_PRESET preset..."
        Invoke-WPFPresets $PARAM_PRESET -checkboxfilterpattern "WPFTweak*"
        Invoke-WPFTab "WPFTab2BT"
    }
    if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        # A preset given together with the configuration is kept, the configuration adds to it
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG -Merge:([bool]$PARAM_PRESET)
    }
    if ($PARAM_RUN -and ($PARAM_PRESET -or $PARAM_CONFIG)) {
        Invoke-WinUtilAutoRun
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
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories @($sync.SelectedAppCategories)
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
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

    $dash = [char]0x2014
    $copyright = [char]0x00A9
    $authorInfo = @"
WinRUtil $dash Windows toolkit
Maintainer : <a href="https://github.com/rtecnocopy89">@rtecnocopy89</a>
GitHub     : <a href="https://github.com/rtecnocopy89/WinRUtil">rtecnocopy89/WinRUtil</a>
Copyright  : $copyright 2026 rtecnocopy89 $dash $copyright 2022 CT Tech Group LLC
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

# Wi-Fi tab: the QR code button shown in each row of the network list
$sync["WPFWifiList"].AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($list, $clickArgs)
    if ($clickArgs.OriginalSource.Uid -eq "WifiQr") {
        Show-WinUtilWifiQRCode -Network $clickArgs.OriginalSource.Tag
    }
})

# Install tab: the check box of each program in the update list, and the one that selects them all
$sync["WPFUpgradeList"].AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($list, $clickArgs)
    if ($clickArgs.OriginalSource.Uid -eq "UpgradeCheck") {
        $clickArgs.OriginalSource.DataContext.Selected = [bool]$clickArgs.OriginalSource.IsChecked
        Update-WinUtilUpgradeView
    }
})
$sync["WPFUpgradeSelectAll"].Add_Click({
    Invoke-WPFUpgradeSelectAll
})

$sync["Form"].ShowDialog() | out-null
Stop-Transcript
