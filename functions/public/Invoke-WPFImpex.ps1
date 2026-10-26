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
        $Config = $null
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
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "Non hai selezionato nulla da esportare. Seleziona almeno un programma, un'ottimizzazione o una funzione di Windows prima di esportare.",
                            "WinRUtil", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1) } -Config '$Config'""" | Set-Clipboard
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
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "Il file selezionato non contiene impostazioni da importare: nessuna modifica applicata.",
                            "WinRUtil", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if (!$PARAM_NOUI) {
                        # Set flag so toggle Checked/Unchecked events don't trigger registry writes
                        # while we're programmatically restoring UI state from the imported config
                        $sync.ImportInProgress = $true
                        try {
                            Reset-WPFCheckBoxes -doToggles $true
                        } finally {
                            $sync.ImportInProgress = $false
                        }
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}
