function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null,

        # Adds the imported selections to the current ones instead of replacing them
        [switch]$Merge
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "Non hai selezionato nulla da esportare. Seleziona almeno un programma, un'ottimizzazione, una funzione di Windows o un'app di Windows prima di esportare.",
                            "WinRUtil", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    # LiteralPath: brackets are valid in file names
                    $jsonFile | Out-File -LiteralPath $Config -Force
                    # The path stays literal when the copied command is pasted into PowerShell, also with apostrophes
                    $escapedConfig = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Config)
                    "& ([ScriptBlock]::Create((irm 'https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1'))) -Config '$escapedConfig'" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config" -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content -LiteralPath $Config -Raw -ErrorAction Stop | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }

                    # Exports of the original WinUtil are an object with the keys grouped by type
                    $isLegacyConfig = $jsonFile -is [System.Management.Automation.PSCustomObject] -and
                        $null -ne $jsonFile.PSObject.Properties["WPFInstall"]
                    if ($isLegacyConfig) {
                        $flattenedJson = @(
                            foreach ($property in $jsonFile.PSObject.Properties) {
                                if ($property.Name -notmatch '^WPF(?:Install|Tweaks|Toggle|Feature|Appx)') {
                                    continue
                                }
                                foreach ($selection in @($property.Value)) {
                                    if ($selection -is [string] -and -not [string]::IsNullOrWhiteSpace($selection)) {
                                        $selection
                                    }
                                }
                            }
                        )
                    } else {
                        $flattenedJson = @($jsonFile)
                    }

                    if ($flattenedJson.Count -eq 0) {
                        [System.Windows.MessageBox]::Show(
                            "Il file selezionato non contiene impostazioni da importare: nessuna modifica applicata.",
                            "WinRUtil", "OK", "Warning")
                        return
                    }

                    # The import replaces the current selections, unless it adds to a preset.
                    # Entries that no longer exist are skipped.
                    $skipped = @(Update-WinUtilSelections -flatJson $flattenedJson -Replace:(-not $Merge))

                    if (!$PARAM_NOUI) {
                        # Set flag so toggle Checked/Unchecked events don't trigger registry writes
                        # while we're programmatically restoring UI state from the imported config
                        $sync.ImportInProgress = $true
                        try {
                            Reset-WPFCheckBoxes -doToggles $true
                        } finally {
                            $sync.ImportInProgress = $false
                        }

                        if ($skipped.Count -gt 0) {
                            $skippedText = (@($skipped | Select-Object -First 10) -join "`n")
                            if ($skipped.Count -gt 10) {
                                $skippedText += "`n... e altre {0}" -f ($skipped.Count - 10)
                            }
                            [System.Windows.MessageBox]::Show(
                                ("Le impostazioni sono state importate, tranne queste voci che non esistono pi{0} in questa versione di WinRUtil:`n`n{1}" -f [char]0x00F9, $skippedText),
                                "WinRUtil", "OK", "Warning") | Out-Null
                        }
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
