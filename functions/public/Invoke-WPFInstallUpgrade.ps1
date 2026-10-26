function Invoke-WPFInstallUpgrade {
    <#
    .SYNOPSIS
        Shows the updates available for the installed programs, so that the ones to install can be chosen
    #>
    if ($sync.UpgradeState -in @("Searching", "Updating")) {
        # The search or the update is still running: show it again
        $sync.WPFUpgradeOverlay.Visibility = "Visible"
        return
    }
    if ($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $sync.WPFUpgradeOverlay.Visibility = "Visible"
    Invoke-WPFUpgradeRefresh
}

function Invoke-WPFUpgradeRefresh {
    <#
    .SYNOPSIS
        Searches the available updates in the background, with the package manager chosen in the Install tab,
        and lists them in the update list
    #>
    if ($sync.ProcessRunning) {
        return
    }

    $manager = if ($sync.ChocoRadioButton.IsChecked) { "Choco" } else { "Winget" }
    $sync.ProcessRunning = $true
    $sync.UpgradeState = "Searching"
    $sync.WPFUpgradeList.ItemsSource = @()
    $sync.WPFUpgradeStatus.Text = "Ricerca degli aggiornamenti con {0} in corso..." -f $(if ($manager -eq "Choco") { "Chocolatey" } else { "WinGet" })
    Update-WinUtilUpgradeView

    Invoke-WPFRunspace -ParameterList @(, @("Manager", $manager)) -ScriptBlock {
        param($Manager)
        $updates = @()
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }
        try {
            if ($Manager -eq "Choco" -and -not (Get-Command choco -ErrorAction SilentlyContinue)) {
                $status = "Chocolatey non {0} installato: non ci sono applicazioni da aggiornare con Chocolatey." -f [char]0x00E8
            } else {
                if ($Manager -eq "Winget") {
                    Install-WinUtilWinget
                }
                $updates = @(Get-WinUtilProgramUpdates -Manager $Manager)
                $status = switch ($updates.Count) {
                    0 { "Nessun aggiornamento disponibile: tutte le applicazioni sono aggiornate." }
                    1 { "1 aggiornamento disponibile." }
                    default { "{0} aggiornamenti disponibili." -f $updates.Count }
                }
                if ($updates.Count -gt 0) {
                    $status += " Scegli quali installare e clicca 'Aggiorna selezionate'."
                }
                if (@($updates | Where-Object { -not $_.Selected }).Count -gt 0) {
                    $status += " Non sono preselezionate le applicazioni con la versione installata sconosciuta e quelle che WinGet aggiorna solo su richiesta."
                }
            }
        } catch {
            $status = "Impossibile cercare gli aggiornamenti: $($_.Exception.Message)"
        } finally {
            $sync.UpgradeState = "Ready"
            $sync.ProcessRunning = $false
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFUpgradeList.ItemsSource = $updates
                $sync.WPFUpgradeStatus.Text = $status
                Update-WinUtilUpgradeView
                Set-WinUtilTaskbaritem -state "None"
            }
        }
    }
}

function Invoke-WPFUpgradeStart {
    <#
    .SYNOPSIS
        Updates the programs selected in the update list one at a time, showing the result of each one
        in the list and recording it for the intervention report
    #>
    $selected = @($sync.WPFUpgradeList.ItemsSource | Where-Object { $_.Selected -and -not $_.Done })
    if ($sync.ProcessRunning -or $selected.Count -eq 0) {
        return
    }

    foreach ($item in $selected) {
        $item.Status = "In attesa"
        $item.Level = "Muted"
    }
    $sync.ProcessRunning = $true
    $sync.UpgradeState = "Updating"
    $sync.WPFUpgradeList.Items.Refresh()
    Update-WinUtilUpgradeView

    Invoke-WPFRunspace -ParameterList @(, @("Programs", $selected)) -ScriptBlock {
        param($Programs)
        $updated = 0
        Write-Host "==========================================="
        Write-Host "--    Updating the selected programs    ---"
        Write-Host "==========================================="
        try {
            for ($i = 0; $i -lt $Programs.Count; $i++) {
                $program = $Programs[$i]
                Invoke-WPFUIThread -ScriptBlock {
                    $program.Status = "In corso..."
                    $program.Level = "Running"
                    $sync.WPFUpgradeList.Items.Refresh()
                    $sync.WPFUpgradeList.ScrollIntoView($program)
                    $sync.WPFUpgradeStatus.Text = "Aggiornamento {0} di {1}: {2}" -f ($i + 1), $Programs.Count, $program.Name
                    Set-WinUtilTaskbaritem -state "Normal" -value ($i / $Programs.Count)
                }

                $result = Update-WinUtilProgram -Program $program
                if ($result.Success) {
                    $updated++
                }
                Add-WinUtilSessionAction -Area "Programmi" -Text ("Aggiornamento di {0} alla versione {1}" -f $program.Name, $program.Available) -Status $(if ($result.Success) { "Success" } else { "Error" })

                Invoke-WPFUIThread -ScriptBlock {
                    $program.Status = $result.Text
                    $program.Level = $result.Level
                    if ($result.Success) {
                        $program.Done = $true
                        $program.Selected = $false
                    }
                    $sync.WPFUpgradeList.Items.Refresh()
                }
            }
            $status = "Aggiornamento completato. Applicazioni aggiornate: {0} su {1}." -f $updated, $Programs.Count
            if ($updated -lt $Programs.Count) {
                $status += " Quelle non riuscite restano selezionate, per riprovare."
            }
        } catch {
            $status = "Aggiornamento interrotto: $($_.Exception.Message)"
        } finally {
            $sync.UpgradeState = "Ready"
            $sync.ProcessRunning = $false
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFUpgradeStatus.Text = $status
                Update-WinUtilUpgradeView
                Set-WinUtilTaskbaritem -state "None" -overlay $(if ($updated -eq $Programs.Count) { "checkmark" } else { "warning" })
            }
        }
    }
}

function Update-WinUtilProgram {
    <#
    .SYNOPSIS
        Updates one program of the update list with its package manager

    .PARAMETER Program
        The entry of the update list (Name, Id, Source and Manager)

    .OUTPUTS
        Success, and the Text and Level of the result shown in the update list
    #>
    param([Parameter(Mandatory)]$Program)

    Write-Host "Updating $($Program.Name) ($($Program.Id))..."
    if ($Program.Manager -eq "Choco") {
        $exitCode = (Start-Process -FilePath "choco" -ArgumentList "upgrade $($Program.Id) -y" -Wait -PassThru).ExitCode
        $result = switch ($exitCode) {
            0 { @{ Success = $true; Text = "Aggiornata"; Level = "Success" } }
            { $_ -in 1641, 3010 } { @{ Success = $true; Text = "Aggiornata, riavvia il PC"; Level = "Warning" } }
            default { @{ Success = $false; Text = "Non riuscito (codice $exitCode)"; Level = "Danger" } }
        }
    } else {
        $arguments = "upgrade --id $($Program.Id) --exact --include-unknown --silent --accept-source-agreements --accept-package-agreements"
        if ($Program.Source) {
            $arguments += " --source $($Program.Source)"
        }
        $exitCode = (Start-Process -FilePath "winget" -ArgumentList $arguments -Wait -PassThru -NoNewWindow).ExitCode
        # The meaning of each code is shown by "winget error <code>"
        $result = switch ('0x{0:X8}' -f $exitCode) {
            '0x00000000' { @{ Success = $true; Text = "Aggiornata"; Level = "Success" } }
            { $_ -in '0x8A150109', '0x8A15010B' } { @{ Success = $true; Text = "Aggiornata, riavvia il PC"; Level = "Warning" } }
            '0x8A15002B' { @{ Success = $false; Text = "Nessun aggiornamento applicabile"; Level = "Warning" } }
            { $_ -in '0x8A150101', '0x8A150103', '0x8A150111' } { @{ Success = $false; Text = "Non riuscito: applicazione aperta"; Level = "Danger" } }
            '0x8A15010A' { @{ Success = $false; Text = "Non riuscito: riavvia il PC e riprova"; Level = "Danger" } }
            default { @{ Success = $false; Text = "Non riuscito (codice $_)"; Level = "Danger" } }
        }
    }

    if ($result.Success) {
        Write-Host "$($Program.Name) updated successfully."
    } else {
        Write-Host "Failed to update $($Program.Name) (exit code $exitCode)."
    }
    return [pscustomobject]$result
}

function Update-WinUtilUpgradeView {
    <#
    .SYNOPSIS
        Updates the counter, the buttons and the progress indicator of the update list

    .NOTES
        The background runspaces call it on the UI thread: it must not pass script blocks to cmdlets
        (Where-Object, ForEach-Object), which would wait for the runspace that is waiting for the UI thread
    #>
    $open = 0
    $selected = 0
    foreach ($item in @($sync.WPFUpgradeList.ItemsSource)) {
        if ($item -and -not $item.Done) {
            $open++
            if ($item.Selected) {
                $selected++
            }
        }
    }
    $ready = $sync.UpgradeState -eq "Ready"

    $sync.WPFUpgradeCount.Text = if ($open -gt 0) { "{0} di {1} selezionate" -f $selected, $open } else { "" }
    $sync.WPFUpgradeSelectAll.IsChecked = $open -gt 0 -and $selected -eq $open
    $sync.WPFUpgradeSelectAll.IsEnabled = $ready -and $open -gt 0
    $sync.WPFUpgradeStart.IsEnabled = $ready -and $selected -gt 0
    $sync.WPFUpgradeRefresh.IsEnabled = $ready
    $sync.WPFUpgradeClose.IsEnabled = $sync.UpgradeState -ne "Updating"
    $sync.WPFUpgradeList.IsEnabled = $sync.UpgradeState -ne "Updating"

    # The arc next to the status turns while WinGet or Chocolatey are working
    $busy = $sync.UpgradeState -in @("Searching", "Updating")
    if ($busy -ne ($sync.WPFUpgradeSpinner.Visibility -eq "Visible")) {
        $animation = $null
        if ($busy) {
            $animation = [System.Windows.Media.Animation.DoubleAnimation]::new([double]0, [double]360, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(1)))
            $animation.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        }
        $sync.WPFUpgradeSpinner.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $animation)
        $sync.WPFUpgradeSpinner.Visibility = if ($busy) { "Visible" } else { "Collapsed" }
    }
}

function Invoke-WPFUpgradeSelectAll {
    <#
    .SYNOPSIS
        Selects or clears every program of the update list that has not been updated yet
    #>
    $state = [bool]$sync.WPFUpgradeSelectAll.IsChecked
    foreach ($item in @($sync.WPFUpgradeList.ItemsSource | Where-Object { $_ -and -not $_.Done })) {
        $item.Selected = $state
    }
    $sync.WPFUpgradeList.Items.Refresh()
    Update-WinUtilUpgradeView
}

function Invoke-WPFUpgradeClose {
    <#
    .SYNOPSIS
        Hides the update list, except while the programs are being updated
    #>
    if ($sync.UpgradeState -ne "Updating") {
        $sync.WPFUpgradeOverlay.Visibility = "Collapsed"
    }
}
