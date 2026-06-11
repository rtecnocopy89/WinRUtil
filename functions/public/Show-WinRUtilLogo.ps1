Function Show-WinRUtilLogo {
    <#
        .SYNOPSIS
            Displays the WinRUtil logo in ASCII art.
        .DESCRIPTION
            Prints the WinRUtil banner to the console.
        .EXAMPLE
            Show-WinRUtilLogo
    #>

    $asciiArt = @"
 __        __ _       ____   _   _ _   _ _
 \ \      / /(_) _ __ |  _ \ | | | | |_(_) |
  \ \ /\ / / | || '_ \| |_) || | | | __| | |
   \ V  V /  | || | | |  _ < | |_| | |_| | |
    \_/\_/   |_||_| |_|_| \_\ \___/ \__|_|_|

=======  WinRUtil - Windows toolkit  =======
"@

    Write-Host $asciiArt -ForegroundColor Green
}
