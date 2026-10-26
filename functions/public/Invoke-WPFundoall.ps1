function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Seleziona le ottimizzazioni da annullare."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
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
            $tweakName = $sync.configs.tweaks.($tweaks[$i]).Content
            if (-not $tweakName) { $tweakName = $tweaks[$i] }
            Set-WinUtilProgressBar -Label "Annullamento: $tweakName" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilProgressBar -Label "Annullamento completato" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="

    }
}
