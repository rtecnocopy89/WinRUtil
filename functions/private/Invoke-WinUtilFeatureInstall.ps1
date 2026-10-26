function Invoke-WinUtilFeatureInstall {
    <#

    .SYNOPSIS
        Converts all the values from the tweaks.json and routes them to the appropriate function

    #>

    param(
        $CheckBox
    )

    $failed = $false
    if($sync.configs.feature.$CheckBox.feature) {
        Foreach( $feature in $sync.configs.feature.$CheckBox.feature ) {
            try {
                Write-Host "Installing $feature"
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
            } catch {
                $failed = $true
                if ($_.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {

                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $_.Exception.StackTrace
                }
            }
        }
    }
    if($sync.configs.feature.$CheckBox.InvokeScript) {
        Foreach( $script in $sync.configs.feature.$CheckBox.InvokeScript ) {
            try {
                $Scriptblock = [scriptblock]::Create($script)

                Write-Host "Running Script for $CheckBox"
                Invoke-Command $scriptblock -ErrorAction stop
            } catch {
                $failed = $true
                if ($_.Exception.Message -like "*requires elevation*") {
                    Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                } else {
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" }
                    Write-Warning "Unable to Install $feature due to unhandled exception."
                    Write-Warning $_.Exception.StackTrace
                }
            }
        }
    }

    # Record the operation for the intervention report
    if ($sync.configs.feature.$CheckBox.Content) {
        Add-WinUtilSessionAction -Area "Configurazione" -Text $sync.configs.feature.$CheckBox.Content -Status $(if ($failed) { "Error" } else { "Success" })
    }
}
