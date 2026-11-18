function Invoke-WPFUltimatePerformance {
    param(
        [switch]$Do
    )

    $guidPattern = '[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}'

    if ($Do) {
        if (-not (powercfg /list | Select-String "WinRUtil - Ultimate Power Plan")) {
            if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                powercfg /restoredefaultschemes
                if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                    Write-Host "Failed to restore High Performance plan. Default plans do not include high performance. If you are on a laptop, do NOT use High Performance or Ultimate Performance plans." -ForegroundColor Red
                    return
                }
            }
            # Match the GUID itself: the label before it is localized (e.g. Italian Windows).
            $guid = [regex]::Match(((powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) -join ' '), $guidPattern).Value
            if (-not $guid) {
                Write-Host "Failed to create the WinRUtil - Ultimate Power Plan plan." -ForegroundColor Red
                return
            }
            powercfg /changename $guid "WinRUtil - Ultimate Power Plan"
            powercfg /setacvalueindex $guid SUB_PROCESSOR IDLEDISABLE 1
            powercfg /setacvalueindex $guid 54533251-82be-4824-96c1-47b60b740d00 4d2b0152-7d5c-498b-88e2-34345392a2c5 1
            powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100
            powercfg /setactive $guid
            Write-Host "WinRUtil - Ultimate Power Plan plan installed and activated." -ForegroundColor Green
            Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "Profilo Prestazioni eccellenti - Attiva"
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is already installed." -ForegroundColor Red
            return
        }
    } else {
        $planLines = @(powercfg /list | Select-String "WinRUtil - Ultimate Power Plan")
        if ($planLines.Count -gt 0) {
            powercfg /setactive SCHEME_BALANCED
            foreach ($planLine in $planLines) {
                $guid = [regex]::Match($planLine.Line, $guidPattern).Value
                if ($guid) {
                    powercfg /delete $guid
                }
            }
            Write-Host "WinRUtil - Ultimate Power Plan plan was removed." -ForegroundColor Red
            Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "Profilo Prestazioni eccellenti - Disattiva"
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is not installed." -ForegroundColor Yellow
        }
    }
}
