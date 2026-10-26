function Get-WinUtilProgramUpdates {
    <#
    .SYNOPSIS
        Lists the installed programs that have an update available

    .PARAMETER Manager
        The package manager to ask: Winget or Choco

    .OUTPUTS
        One entry of the update list of the Install tab per program. Selected is false for the
        programs that "winget upgrade --all" leaves out: the ones whose installed version is
        unknown and the ones that must be upgraded explicitly.

    .EXAMPLE
        Get-WinUtilProgramUpdates -Manager "Winget"
    #>

    param(
        [Parameter(Mandatory)]
        [ValidateSet("Winget", "Choco")]
        [string]$Manager
    )

    # The output goes through a file, so that a package manager that stops responding can be stopped
    # instead of leaving the search running for ever
    $outputFile = Join-Path $env:TEMP ("WinRUtil-updates-{0}.txt" -f [guid]::NewGuid())
    try {
        if ($Manager -eq "Choco") {
            $exitCode = Invoke-WinUtilProcess -FilePath "choco" -ArgumentList "outdated --limit-output --ignore-unfound" -NoNewWindow -OutputFile $outputFile -TimeoutSeconds 300
        } else {
            $exitCode = Invoke-WinUtilProcess -FilePath "winget" -ArgumentList "upgrade --include-unknown --accept-source-agreements --disable-interactivity" -NoNewWindow -OutputFile $outputFile -TimeoutSeconds 300
        }
        # WinGet writes UTF-8 when its output is redirected
        $lines = @([System.IO.File]::ReadAllLines($outputFile, [System.Text.Encoding]::UTF8))
    } finally {
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }

    if ($Manager -eq "Choco") {
        # One "name|installed|available|pinned" line per outdated package; pinned packages are not upgraded
        $lines = $lines | Where-Object { $_ -match '^[^|]+\|[^|]*\|[^|]+\|false$' }
        foreach ($line in $lines) {
            $name, $version, $available = ($line -split '\|')[0..2]
            [pscustomobject]@{
                Selected  = $true
                Name      = $name
                Id        = $name
                Version   = $version
                Available = $available
                Source    = "chocolatey"
                Manager   = "Choco"
                Status    = ""
                Level     = ""
                Done      = $false
            }
        }
        return
    }

    $rows = @(ConvertFrom-WinUtilWingetTable -Lines $lines)
    # Without a table WinGet prints a message: no updates (also "no applicable update" or "no package found") or an error
    if ($rows.Count -eq 0 -and ('0x{0:X8}' -f $exitCode) -notin @('0x00000000', '0x8A15002B', '0x8A150014')) {
        $message = $lines | Where-Object { $_.Trim() } | Select-Object -Last 1
        throw ("{0} (codice di WinGet 0x{1:X8})" -f $message, $exitCode).Trim()
    }

    foreach ($row in $rows) {
        [pscustomobject]@{
            Selected  = ($row.Table -eq 1 -and $row.Version -match '\d')
            Name      = $row.Name
            Id        = $row.Id
            Version   = $row.Version
            Available = $row.Available
            Source    = $row.Source
            Manager   = "Winget"
            Status    = ""
            Level     = ""
            Done      = $false
        }
    }
}
