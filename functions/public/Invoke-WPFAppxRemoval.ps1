function Invoke-WPFAppxRemoval {
    <#

    .SYNOPSIS
        Removes the selected Windows apps for all users, also for the user profiles created later

    .PARAMETER Confirmed
        Removes the apps without asking, for the automatic runs

    #>
    param([switch]$Confirmed)

    if ($sync.ProcessRunning) {
        [System.Windows.MessageBox]::Show("Attendi la fine dell'operazione in corso.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $selected = @($sync.selectedAppx)
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Seleziona le app di Windows da rimuovere.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    if (-not $Confirmed -and -not $PARAM_NOUI) {
        $names = ($selected | ForEach-Object { "- $($sync.configs.appxHashtable[$_].Content)" }) -join "`n"
        $message = "Vuoi rimuovere queste app di Windows per tutti gli utenti?`n`n$names`n`nPotrai reinstallarle in seguito con 'Reinstalla selezionate'."
        $answer = [System.Windows.MessageBox]::Show($message, "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne "Yes") {
            return
        }
    }

    $appxScript = {
        param($Selected, $Apps)

        $removed = 0
        $packageList = [System.Collections.Generic.List[string]]::new()
        Write-Host "==========================================="
        Write-Host "--      Removing Windows apps          ---"
        Write-Host "==========================================="
        try {
            for ($i = 0; $i -lt $Selected.Count; $i++) {
                $key = $Selected[$i]
                $app = $Apps[$key]
                Invoke-WPFUIThread -ScriptBlock {
                    $sync.WPFAppxStatus.Text = "Rimozione {0} di {1}: {2}..." -f ($i + 1), $Selected.Count, $app.Content
                    Set-WinUtilTaskbaritem -state "Normal" -value ($i / $Selected.Count)
                }

                if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                    # The Game Bar must not be running, and without game capture the ms-gamebar
                    # message no longer appears when a game starts
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0 -ErrorAction SilentlyContinue
                }
                if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                    Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                $ok = Remove-WinUtilAPPX -Name $app.PackageId
                $packageList.Add($app.PackageId)

                if ($key -eq "WPFAppxMSTeams") {
                    # The Teams meeting add-in for Microsoft Office
                    Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null
                }

                if ($ok) {
                    $removed++
                }
                Add-WinUtilSessionAction -Area "App di Windows" -Text ("Rimozione di {0}" -f $app.Content) -Status $(if ($ok) { "Success" } else { "Error" })
            }

            $status = "Rimozione completata: {0} app su {1}." -f $removed, $Selected.Count
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFAppxStatus.Text = "Rimozione delle app per i nuovi profili utente..."
            }
            try {
                Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
            } catch {
                Write-Warning $_.Exception.Message
                $status += " Alcune app potrebbero comparire di nuovo nei profili utente creati in seguito."
            }
        } catch {
            $status = "Rimozione interrotta: $($_.Exception.Message)"
        } finally {
            $sync.ProcessRunning = $false
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFAppxStatus.Text = $status
                Set-WinUtilTaskbaritem -state "None" -overlay $(if ($removed -eq $Selected.Count) { "checkmark" } else { "warning" })
            }
        }
    }

    $sync.ProcessRunning = $true
    try {
        Invoke-WPFRunspace -ParameterList @(("Selected", $selected), ("Apps", $sync.configs.appxHashtable)) -ScriptBlock $appxScript | Out-Null
    } catch {
        $sync.ProcessRunning = $false
        $sync.WPFAppxStatus.Text = "Impossibile avviare la rimozione: $($_.Exception.Message)"
    }
}
