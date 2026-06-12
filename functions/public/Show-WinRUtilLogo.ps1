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
