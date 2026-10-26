function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    Write-Debug "Tweaks: $($CheckBox)"
    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

            # KeepServiceStartup leaves alone a service that the user or another program changed away from
            # the value this tweak expects. Undo uses the same rule in reverse: OriginalType is restored only
            # when the service still has the StartupType this tweak applies.
            $expectedType = if ($undo) { $psitem.StartupType } else { $psitem.$($values.OriginalService) }
            if ($KeepServiceStartup) {
                $serviceName = $psitem.Name
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $serviceName -ErrorAction Stop
                    if (!($service.StartType.ToString() -eq $expectedType)) {
                        Write-Debug "Service $serviceName has the startup type $($service.StartType) instead of $expectedType, so it is left as it is"
                        $changeservice = $false
                    }
                } catch {
                    # A service that does not exist on this edition of Windows is skipped, it does not stop the tweak
                    if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
                        $changeservice = $false
                        Write-Warning "Service $serviceName was not found."
                    } else {
                        throw
                    }
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        # Entries with a list of Values belong to a combo box and are set by Set-WinUtilRegistryComboState
        $sync.configs.tweaks.$CheckBox.registry | Where-Object { -not $psitem.Values } | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if ($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Write-Debug "UNDO $($psitem.Name)"
                Remove-WinUtilAPPX -Name $psitem
            }
        }

    }

    # Record the operation for the intervention report
    $tweak = $sync.configs.tweaks.$CheckBox
    if ($tweak.Content) {
        $text = if ($tweak.Type -eq "Toggle") {
            "{0} - {1}" -f $tweak.Content, $(if ($undo) { "Disattiva" } else { "Attiva" })
        } elseif ($undo) {
            "{0} (annullata)" -f $tweak.Content
        } else {
            $tweak.Content
        }
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text $text
    }
}
