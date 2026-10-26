function Invoke-WPFAppxInstall {
    <#

    .SYNOPSIS
        Installs again the selected Windows apps, from the copy left on the PC or from the Microsoft Store

    #>

    if ($sync.ProcessRunning) {
        [System.Windows.MessageBox]::Show("Attendi la fine dell'operazione in corso.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $selected = @($sync.selectedAppx)
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Seleziona le app di Windows da reinstallare.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $appxScript = {
        param($Selected, $Apps)

        $installed = 0
        Write-Host "==========================================="
        Write-Host "--     Installing Windows apps         ---"
        Write-Host "==========================================="
        try {
            for ($i = 0; $i -lt $Selected.Count; $i++) {
                $app = $Apps[$Selected[$i]]
                Invoke-WPFUIThread -ScriptBlock {
                    $sync.WPFAppxStatus.Text = "Installazione {0} di {1}: {2}..." -f ($i + 1), $Selected.Count, $app.Content
                    Set-WinUtilTaskbaritem -state "Normal" -value ($i / $Selected.Count)
                }

                $ok = Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId
                if ($ok) {
                    $installed++
                }
                Add-WinUtilSessionAction -Area "App di Windows" -Text ("Installazione di {0}" -f $app.Content) -Status $(if ($ok) { "Success" } else { "Error" })
            }
            $status = "Installazione completata: {0} app su {1}." -f $installed, $Selected.Count
        } catch {
            $status = "Installazione interrotta: $($_.Exception.Message)"
        } finally {
            $sync.ProcessRunning = $false
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFAppxStatus.Text = $status
                Set-WinUtilTaskbaritem -state "None" -overlay $(if ($installed -eq $Selected.Count) { "checkmark" } else { "warning" })
            }
        }
    }

    $sync.ProcessRunning = $true
    try {
        Invoke-WPFRunspace -ParameterList @(("Selected", $selected), ("Apps", $sync.configs.appxHashtable)) -ScriptBlock $appxScript | Out-Null
    } catch {
        $sync.ProcessRunning = $false
        $sync.WPFAppxStatus.Text = "Impossibile avviare l'installazione: $($_.Exception.Message)"
    }
}
