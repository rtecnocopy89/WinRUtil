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
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "O&O ShutUp10++" -Status "Info"
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "O&O ShutUp10++" -Status "Error"
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
