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

        $app = $sync.configs.applicationsHashtable[$appKey]
        $handlers = Get-WinUtilAppEntryHandlers

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp($handlers.BorderClick)
        $border.Add_MouseEnter($handlers.MouseEnter)
        $border.Add_MouseLeave($handlers.MouseLeave)
        $border.Add_MouseRightButtonUp($handlers.RightClick)

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked($handlers.Checked)
        $checkbox.Add_Unchecked($handlers.Unchecked)

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        # The icon of the website of the app, with its initial while the icon is missing
        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 6, 0)
        $icon.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"
        $fallback.HorizontalAlignment = "Center"
        $fallback.VerticalAlignment = "Center"
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($app.link -and -not $PARAM_OFFLINE) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            [Windows.Media.RenderOptions]::SetBitmapScalingMode($logo, [Windows.Media.BitmapScalingMode]::HighQuality)
            $logo.Add_ImageFailed($handlers.ImageFailed)
            $fallback.Visibility = "Collapsed"
            [void]$icon.Children.Add($logo)
            try {
                # WPF downloads the icon by itself, without a runspace. The image cache is skipped so that a
                # window opened again in the same PowerShell session does not reuse images of the closed one.
                $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit()
                $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
                $bitmap.UriSource = [uri]"https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))"
                $bitmap.EndInit()
                $logo.Source = $bitmap
            } catch {
                $logo.Visibility = "Collapsed"
                $fallback.Visibility = "Visible"
            }
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content

        # Change color to Green if FOSS
        if ($app.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the icon and the name to the Checkbox
        [void]$contentPanel.Children.Add($appName)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        $border.Child = $checkBox
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
