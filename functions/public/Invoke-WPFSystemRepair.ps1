function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image

        The exit code of each step is checked: a failed step stops the repair, and the error of
        DISM is explained.
    #>

    # SuccessCodes are the exit codes other than 0 that a step treats as success. The same number
    # means different things: 1 and 2 are normal results of chkdsk, while 1 from sfc is a failure.
    $steps = @(
        @{
            Label = "CHKDSK (controllo del disco)"
            Arguments = "/c chkdsk /scan /perf"
            # 3: the disk could not be checked or has errors that an online scan cannot fix,
            # and the next steps are not worth running on a disk in that state
            SuccessCodes = @(1, 2)
        },
        @{
            Label = "SFC (controllo dei file di sistema)"
            Arguments = "/c sfc /scannow"
            SuccessCodes = @()
        },
        @{
            Label = "DISM (riparazione dell'immagine di Windows)"
            Arguments = "/c dism /online /cleanup-image /restorehealth"
            # 3010: repaired, a restart is needed
            SuccessCodes = @(3010)
        }
    )

    # The most common errors of DISM, which are Windows system error codes
    $dismErrors = @{
        2 = "file non trovato"
        3 = "percorso non trovato"
        5 = "accesso negato"
        21 = "dispositivo non pronto"
        32 = "file in uso da un altro programma"
        50 = "richiesta non supportata"
        87 = "parametro non valido"
        112 = "disco pieno"
        1168 = "elemento non trovato"
        1223 = "operazione annullata"
        1392 = "file o cartella danneggiati"
        1460 = "tempo scaduto"
        -2146498529 = "file di origine non trovati: serve Windows Update o un'immagine di Windows come origine"
        -2146498298 = "impossibile scaricare i file di origine: controlla la connessione a Internet e Windows Update"
        -2146498297 = "un criterio di gruppo impedisce di scaricare i file di origine da Windows Update"
    }

    $failure = $null
    foreach ($step in $steps) {
        Write-Host "==> $($step.Label)"
        $exitCode = Invoke-WinUtilProcess -FilePath "cmd.exe" -ArgumentList $step.Arguments -NoNewWindow
        if ($exitCode -ne 0 -and $step.SuccessCodes -notcontains $exitCode) {
            $failure = "{0}: codice di uscita {1} (0x{1:X8})" -f $step.Label, $exitCode
            if ($step.Label -like "DISM*" -and $dismErrors.ContainsKey($exitCode)) {
                $failure += ", " + $dismErrors[$exitCode]
            }
            break
        }
    }

    if ($failure) {
        Write-Warning "System repair stopped. $failure"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Add-WinUtilSessionAction -Area "Riparazione" -Text "Controllo e riparazione del sistema (CHKDSK, SFC, DISM) - $failure" -Status "Error"
        [System.Windows.MessageBox]::Show("Controllo e riparazione del sistema non completato.`n`n$failure", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    Add-WinUtilSessionAction -Area "Riparazione" -Text "Controllo e riparazione del sistema (CHKDSK, SFC, DISM)"
}
