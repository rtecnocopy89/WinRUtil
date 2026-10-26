function Invoke-WPFGetInstalledAppx {
    <#

    .SYNOPSIS
        Selects the Windows apps of the list that are installed on this PC

    #>

    if ($sync.ProcessRunning) {
        [System.Windows.MessageBox]::Show("Attendi la fine dell'operazione in corso.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $sync.WPFAppxStatus.Text = "Ricerca delle app installate..."
    Invoke-WPFRunspace -ScriptBlock {
        # Reading the packages takes a few seconds, so it runs in the background
        $installed = @(Get-WinUtilInstalledAPPX)
        Invoke-WPFUIThread -ScriptBlock {
            $found = 0
            foreach ($key in $sync.configs.appxHashtable.Keys) {
                if ($installed -contains $sync.configs.appxHashtable[$key].PackageId) {
                    $sync.$key.IsChecked = $true
                    $found++
                }
            }
            $sync.WPFAppxStatus.Text = "App dell'elenco installate su questo PC: $found."
        }
    } | Out-Null
}
