function ConvertFrom-WinUtilWingetTable {
    <#
    .SYNOPSIS
        Reads the package tables printed by "winget upgrade"

    .DESCRIPTION
        The column positions come from the header above the dashed line, so names that contain
        spaces are read correctly. WinGet aligns the columns by display width: East Asian wide
        characters take two columns and are counted that way.

    .PARAMETER Lines
        The output of WinGet, one line per item

    .OUTPUTS
        One object per row with Name, Id, Version, Available, Source and Table, the position of the
        table in the output (the first table lists the upgrades that "winget upgrade --all" installs)

    .EXAMPLE
        ConvertFrom-WinUtilWingetTable -Lines (winget upgrade | Out-String -Stream)
    #>

    param([string[]]$Lines)

    function ConvertTo-CellText {
        # Adds a NUL after every wide character, so that string positions match the columns
        param([string]$Text)
        if ($Text -notmatch '[^\x00-\x7F]') {
            return $Text
        }
        $builder = [System.Text.StringBuilder]::new()
        foreach ($char in $Text.ToCharArray()) {
            $null = $builder.Append($char)
            $code = [int]$char
            if (($code -ge 0x1100 -and $code -le 0x115F) -or ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
                ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or
                ($code -ge 0xFE10 -and $code -le 0xFE19) -or ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
                ($code -ge 0xFF00 -and $code -le 0xFF60) -or ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
                $null = $builder.Append([char]0)
            }
        }
        return $builder.ToString()
    }

    function Test-TableRow {
        # Every column starts right after a space with a value, and every row has all five values
        param([string]$Row, [int[]]$Starts)
        if ($Row.Length -le $Starts[-1] -or $Row[0] -eq ' ') {
            return $false
        }
        for ($c = 1; $c -lt $Starts.Count; $c++) {
            if ($Row[$Starts[$c] - 1] -ne ' ' -or $Row[$Starts[$c]] -eq ' ') {
                return $false
            }
        }
        return $true
    }

    $table = 0
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^-{8,}\s*$') {
            continue
        }

        # The header is the line above the dashes, without what a progress spinner may have left before it
        $header = ConvertTo-CellText (($Lines[$i - 1].TrimEnd("`r") -split "`r")[-1])
        $words = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
        if ($words.Count -lt 5 -or $words.Count -gt 9) {
            continue
        }

        # The rows, followed by the summary line ("N upgrades available.") that ends the table
        $body = @(for ($j = $i + 1; $j -lt $Lines.Count -and -not [string]::IsNullOrWhiteSpace($Lines[$j]); $j++) {
            ConvertTo-CellText $Lines[$j]
        })

        # Name, Id, Version, Available and Source. The Korean titles have two words, so the header
        # words are grouped into the five columns that fit the most rows
        $starts = $null
        $rowCount = -1
        for ($mask = 0; $mask -lt (1 -shl ($words.Count - 1)); $mask++) {
            $candidate = @($words[0]) + @(for ($w = 1; $w -lt $words.Count; $w++) {
                if ($mask -band (1 -shl ($w - 1))) { $words[$w] }
            })
            if ($candidate.Count -ne 5) {
                continue
            }
            $fitting = 0
            while ($fitting -lt $body.Count -and (Test-TableRow -Row $body[$fitting] -Starts $candidate)) {
                $fitting++
            }
            if ($fitting -gt $rowCount) {
                $starts = $candidate
                $rowCount = $fitting
            }
        }

        $table++
        for ($r = 0; $r -lt $rowCount; $r++) {
            $row = $body[$r]
            $cells = for ($c = 0; $c -lt 5; $c++) {
                $end = if ($c -lt 4) { $starts[$c + 1] } else { $row.Length }
                $row.Substring($starts[$c], $end - $starts[$c]).Replace([string][char]0, '').Trim()
            }
            [pscustomobject]@{
                Name      = $cells[0]
                Id        = $cells[1]
                Version   = $cells[2]
                Available = $cells[3]
                Source    = $cells[4]
                Table     = $table
            }
        }
    }
}
