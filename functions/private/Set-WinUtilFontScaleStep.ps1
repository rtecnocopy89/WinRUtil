function Set-WinUtilFontScaleStep {
    <#
    .SYNOPSIS
        Makes the text of WinRUtil bigger or smaller by one step of the text size slider

    .PARAMETER Step
        The change of the scale factor; 0 restores the normal size

    .EXAMPLE
        Set-WinUtilFontScaleStep -Step 0.25
    #>

    param([double]$Step)

    $slider = $sync.FontScalingSlider
    $value = if ($Step -eq 0) { 1.0 } else { $slider.Value + $Step }
    $value = [math]::Max($slider.Minimum, [math]::Min($slider.Maximum, $value))
    if ($value -eq $sync.fontScaleFactor -or ($null -eq $sync.fontScaleFactor -and $value -eq 1.0)) {
        return
    }

    $slider.Value = $value
    Invoke-WinUtilFontScaling -ScaleFactor $value
}
