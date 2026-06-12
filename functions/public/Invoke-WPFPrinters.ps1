function Write-WinUtilPrinterLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Printers tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFPrinterStatusLog
    if (-not $logBox) {
        Write-Host $line
        return
    }

    $action = {
        if ([string]::IsNullOrWhiteSpace($logBox.Text) -or $logBox.Text -like "Pronto.*") {
            $logBox.Text = $line
        } else {
            $logBox.AppendText("`r`n$line")
        }
        $logBox.ScrollToEnd()
    }

    if ($logBox.Dispatcher.CheckAccess()) {
        & $action
    } else {
        $logBox.Dispatcher.Invoke($action)
    }
}

function Invoke-WPFPrinterRefresh {
    <#
        .SYNOPSIS
            Detects installed printers and fills the Printers DataGrid with driver, port, status and queued jobs.
    #>
    Write-WinUtilPrinterLog "Scansione delle stampanti installate..."
    try {
        $rows = New-Object System.Collections.Generic.List[PSObject]
        $printers = Get-Printer -ErrorAction Stop

        foreach ($printer in $printers) {
            $jobCount = 0
            try {
                $jobCount = @(Get-PrintJob -PrinterName $printer.Name -ErrorAction Stop).Count
            } catch {
                $jobCount = 0
            }

            $rows.Add([PSCustomObject]@{
                Name   = $printer.Name
                Driver = $printer.DriverName
                Port   = $printer.PortName
                Status = [string]$printer.PrinterStatus
                Jobs   = $jobCount
            })
        }

        $sync.WPFPrinterList.ItemsSource = $rows
        Write-WinUtilPrinterLog ("Trovate {0} stampante/i." -f $rows.Count) -Level Success
    } catch {
        Write-WinUtilPrinterLog "Impossibile elencare le stampanti: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFPrinterSpooler {
    <#
        .SYNOPSIS
            Manages the Windows print spooler: restart the service or clear the print queue.
        .PARAMETER Action
            "Restart" restarts the Spooler service. "ClearQueue" purges all queued jobs.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Restart", "ClearQueue")]
        [string]$Action
    )

    switch ($Action) {
        "Restart" {
            Write-WinUtilPrinterLog "Riavvio del servizio Spooler di stampa..."
            try {
                Restart-Service -Name Spooler -Force -ErrorAction Stop
                Write-WinUtilPrinterLog "Spooler di stampa riavviato." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Riavvio dello spooler non riuscito: $($_.Exception.Message)" -Level Error
            }
        }
        "ClearQueue" {
            Write-WinUtilPrinterLog "Svuotamento della coda di stampa..."
            $spoolPath = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
            try {
                Stop-Service -Name Spooler -Force -ErrorAction Stop
                if (Test-Path $spoolPath) {
                    Get-ChildItem -Path $spoolPath -File -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                }
                Start-Service -Name Spooler -ErrorAction Stop
                Write-WinUtilPrinterLog "Coda di stampa svuotata e spooler riavviato." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Svuotamento della coda non riuscito: $($_.Exception.Message)" -Level Error
                try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch {}
            }
            Invoke-WPFPrinterRefresh
        }
    }
}

function Invoke-WPFPrinterDriver {
    <#
        .SYNOPSIS
            Installs a printer driver from an INF package, or removes the driver of the selected printer.
        .PARAMETER Action
            "Install" prompts for an .inf file and stages it with pnputil. "Remove" removes the
            driver used by the printer selected in the list.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Install", "Remove")]
        [string]$Action
    )

    switch ($Action) {
        "Install" {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title  = "Seleziona un file di installazione driver (.inf)"
            $dialog.Filter = "File driver (*.inf)|*.inf|Tutti i file (*.*)|*.*"
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
                Write-WinUtilPrinterLog "Installazione del driver annullata." -Level Warning
                return
            }

            $inf = $dialog.FileName
            Write-WinUtilPrinterLog "Installazione del driver da: $inf"
            try {
                $output = & pnputil.exe /add-driver "$inf" /install 2>&1
                $output | ForEach-Object { Write-WinUtilPrinterLog $_ }
                if ($LASTEXITCODE -eq 0) {
                    Write-WinUtilPrinterLog "Driver installato correttamente." -Level Success
                } else {
                    Write-WinUtilPrinterLog "pnputil e' terminato con codice $LASTEXITCODE." -Level Warning
                }
            } catch {
                Write-WinUtilPrinterLog "Installazione del driver non riuscita: $($_.Exception.Message)" -Level Error
            }
            Invoke-WPFPrinterRefresh
        }
        "Remove" {
            $selected = $sync.WPFPrinterList.SelectedItem
            if (-not $selected) {
                Write-WinUtilPrinterLog "Seleziona prima una stampante nell'elenco, poi clicca Rimuovi driver." -Level Warning
                return
            }

            $driverName = $selected.Driver
            Write-WinUtilPrinterLog "Rimozione del driver '$driverName' (stampante '$($selected.Name)')..."
            try {
                Remove-PrinterDriver -Name $driverName -ErrorAction Stop
                Write-WinUtilPrinterLog "Driver '$driverName' rimosso." -Level Success
            } catch {
                Write-WinUtilPrinterLog "Impossibile rimuovere il driver (potrebbe essere ancora in uso): $($_.Exception.Message)" -Level Error
            }
            Invoke-WPFPrinterRefresh
        }
    }
}
