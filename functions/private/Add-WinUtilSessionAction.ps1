function Add-WinUtilSessionAction {
    <#
    .SYNOPSIS
        Records an operation performed in this session, for the intervention report

    .PARAMETER Area
        The section where the operation was performed (e.g. "Programmi", "Ottimizzazione")

    .PARAMETER Text
        A short description of the operation

    .PARAMETER Status
        Success when the operation completed, Error when it failed, Info when an external tool was started

    .EXAMPLE
        Add-WinUtilSessionAction -Area "Riparazione" -Text "Rete - Reimposta"
    #>

    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet("Success", "Error", "Info")]
        [string]$Status = "Success"
    )

    if (-not $sync.SessionActions) {
        $sync.SessionActions = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    }

    $result = switch ($Status) {
        "Error" { "Non riuscito" }
        "Info" { "Avviato" }
        default { "Eseguito" }
    }

    $null = $sync.SessionActions.Add([pscustomobject]@{
        Timestamp = Get-Date
        Time      = Get-Date -Format "HH:mm"
        Area      = $Area
        Text      = $Text
        Status    = $Status
        Result    = $result
    })
}
