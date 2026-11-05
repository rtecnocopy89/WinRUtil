<#
.NOTES
    WinRUtil - Windows toolkit
    Maintainer     : @rtecnocopy89
    GitHub         : https://github.com/rtecnocopy89/WinRUtil
    Copyright      : (c) 2026 rtecnocopy89 - (c) 2022 CT Tech Group LLC
    Based on       : ChrisTitusTech/winutil (MIT)
    Version        : 26.11.05
#>

param (
    [string]$Config,
    [string]$Preset,
    [switch]$Run,
    [switch]$Noui,
    [switch]$Offline
)

if ($Config) {
    $PARAM_CONFIG = $Config
}

if ($Preset) {
    # Checked here rather than with ValidateSet: "irm | iex" runs the param block as plain
    # variable declarations, and ValidateSet rejects their empty default value
    if ($Preset -notin "Standard", "Minimal", "Advanced") {
        Write-Host "Unknown preset '$Preset', use Standard, Minimal or Advanced" -ForegroundColor Red
        return
    }
    $PARAM_PRESET = $Preset
}

$PARAM_RUN = $false
# Handle the -Run switch
if ($Run) {
    $PARAM_RUN = $true
}

$PARAM_NOUI = $false
if ($Noui) {
    $PARAM_NOUI = $true
}

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinRUtil is unable to run on your system, powershell execution is restricted by security policies" -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinRUtil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            # An apostrophe in a path is doubled, so that it stays inside the quotes
            "-$($_.Key) '$($_.Value -replace "'", "''")'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil-web.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Load DLLs
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.PSScriptRoot = $PSScriptRoot
$sync.version = "26.11.05"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"
$sync.selectedAppsStackPanel
$sync.selectedAppsPopup
# Operations performed in this session, listed in the intervention report
$sync.SessionActions = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

# Set the path for the WinRUtil data directory (preferences, logs and report settings)
$winutildir = "$env:LocalAppData\WinRUtil"
$legacydir = "$env:LocalAppData\winutil"
if (-not (Test-Path $winutildir) -and (Test-Path "$legacydir\preferences.ini")) {
    # Earlier versions shared the folder of the original WinUtil: keep the saved preferences
    New-Item $winutildir -ItemType Directory -Force | Out-Null
    Copy-Item "$legacydir\preferences.ini" $winutildir -ErrorAction SilentlyContinue
}
New-Item $winutildir -ItemType Directory -Force | Out-Null

$logdir = "$winutildir\logs"
New-Item $logdir -ItemType Directory -Force | Out-Null
Start-Transcript -Path "$logdir\winrutil_$dateTime.log" -Append -NoClobber | Out-Null

# Set PowerShell window title
$Host.UI.RawUI.WindowTitle = "WinRUtil (Admin)"
clear-host
    function Add-SelectedAppsMenuItem {
        <#
        .SYNOPSIS
            This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

        .Parameter name
            The actual Name of an App like "Chrome" or "Brave"
            This name is contained in the "Content" property inside the applications.json
        .PARAMETER key
            The key which identifies an app object in applications.json
            For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
        #>

        param ([string]$name, [string]$key)

        $selectedAppGrid = New-Object Windows.Controls.Grid

        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
        $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

        # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
        # With the tooltip, you can still read the whole entry on hover
        $selectedAppLabel = New-Object Windows.Controls.Label
        $selectedAppLabel.Content = $name
        $selectedAppLabel.ToolTip = $name
        $selectedAppLabel.HorizontalAlignment = "Left"
        $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
        $selectedAppGrid.Children.Add($selectedAppLabel)

        $selectedAppRemoveButton = New-Object Windows.Controls.Button
        $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
        $selectedAppRemoveButton.Content = [string]([char]0xE711)
        $selectedAppRemoveButton.HorizontalAlignment = "Center"
        $selectedAppRemoveButton.Tag = $key
        $selectedAppRemoveButton.ToolTip = "Rimuovi l'app dalla selezione"
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
        $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

        # Highlight the Remove icon on Hover
        $selectedAppRemoveButton.Add_MouseEnter({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "DangerColor") })
        $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
        $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
        })
        [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
        $selectedAppGrid.Children.Add($selectedAppRemoveButton)
        # Add new Element to Popup
        $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
    }
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
function ConvertTo-WinUtilQRCode {
    <#
    .SYNOPSIS
        Encodes a text as a QR Code symbol

    .DESCRIPTION
        Implements the QR Code Model 2 encoding of ISO/IEC 18004 for versions 1 to 10: byte mode with
        UTF-8 text, error correction level M (L when the text does not fit), Reed-Solomon error
        correction, block interleaving, function patterns, format and version information, and the
        data mask with the lowest penalty score. Besides the standard penalty rules, the score avoids
        masks that make finder-like patterns in the data area, which some decoders misread.

    .PARAMETER Text
        The text to encode: up to 213 bytes in UTF-8 at level M, or 271 bytes at level L.

    .OUTPUTS
        An object with Size (modules per side) and Modules, a [bool[]] of Size * Size values stored
        row by row, where $true is a dark module, plus Version, ErrorCorrection and Mask. The quiet
        zone around the symbol is not included.

    .EXAMPLE
        $qr = ConvertTo-WinUtilQRCode -Text "WIFI:T:WPA;S:Casa;P:password;;"
    #>

    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    # Versions 1-10: total codewords, then error correction codewords per block and number of blocks for each level
    $totalCodewords = @(26, 44, 70, 100, 134, 172, 196, 242, 292, 346)
    $levels = @(
        @{ Name = "M"; FormatBits = 0; EccPerBlock = @(10, 16, 26, 18, 24, 16, 18, 22, 22, 26); Blocks = @(1, 1, 1, 2, 2, 4, 4, 4, 5, 5) }
        @{ Name = "L"; FormatBits = 1; EccPerBlock = @(7, 10, 15, 20, 26, 18, 20, 24, 30, 18); Blocks = @(1, 1, 1, 1, 1, 2, 2, 2, 2, 4) }
    )

    # Smallest version that holds the text, preferring level M
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $version = 0
    foreach ($candidate in $levels) {
        for ($v = 1; $v -le 10; $v++) {
            $capacity = ($totalCodewords[$v - 1] - $candidate.EccPerBlock[$v - 1] * $candidate.Blocks[$v - 1]) * 8
            $countBits = if ($v -le 9) { 8 } else { 16 }
            if (4 + $countBits + $bytes.Length * 8 -le $capacity) {
                $version = $v
                $level = $candidate
                break
            }
        }
        if ($version) { break }
    }
    if (-not $version) {
        throw "The text is too long for a QR Code of version 10 or lower."
    }

    $size = $version * 4 + 17
    $eccLen = $level.EccPerBlock[$version - 1]
    $numBlocks = $level.Blocks[$version - 1]
    $rawCodewords = $totalCodewords[$version - 1]
    $dataCodewords = $rawCodewords - $eccLen * $numBlocks
    $countBits = if ($version -le 9) { 8 } else { 16 }

    # Data bit stream: byte mode indicator, character count, data, terminator and padding
    $bits = New-Object System.Collections.Generic.List[int]
    $appendBits = {
        param([int]$value, [int]$length)
        for ($i = $length - 1; $i -ge 0; $i--) {
            $bits.Add(($value -shr $i) -band 1)
        }
    }
    & $appendBits 4 4
    & $appendBits $bytes.Length $countBits
    foreach ($b in $bytes) {
        & $appendBits $b 8
    }
    & $appendBits 0 ([math]::Min(4, $dataCodewords * 8 - $bits.Count))
    & $appendBits 0 ((8 - $bits.Count % 8) % 8)

    $data = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $bits.Count; $i += 8) {
        $value = 0
        for ($j = 0; $j -lt 8; $j++) {
            $value = ($value -shl 1) -bor $bits[$i + $j]
        }
        $data.Add($value)
    }
    # Pad codewords alternate between 0xEC and 0x11
    for ($pad = 0xEC; $data.Count -lt $dataCodewords; $pad = $pad -bxor 0xFD) {
        $data.Add($pad)
    }

    # Galois field GF(256) with the primitive polynomial 0x11D
    $exp = New-Object int[] 512
    $log = New-Object int[] 256
    $x = 1
    for ($i = 0; $i -lt 255; $i++) {
        $exp[$i] = $x
        $log[$x] = $i
        $x = $x -shl 1
        if ($x -band 0x100) { $x = $x -bxor 0x11D }
    }
    for ($i = 255; $i -lt 512; $i++) {
        $exp[$i] = $exp[$i - 255]
    }

    # Reed-Solomon generator polynomial, highest power first and without the leading term
    $divisor = New-Object int[] $eccLen
    $divisor[$eccLen - 1] = 1
    $root = 1
    for ($i = 0; $i -lt $eccLen; $i++) {
        for ($j = 0; $j -lt $eccLen; $j++) {
            $divisor[$j] = if ($divisor[$j] -and $root) { $exp[$log[$divisor[$j]] + $log[$root]] } else { 0 }
            if ($j + 1 -lt $eccLen) {
                $divisor[$j] = $divisor[$j] -bxor $divisor[$j + 1]
            }
        }
        $root = $exp[$log[$root] + 1]
    }

    # Split the data into blocks (the last blocks are one codeword longer) and compute their error correction codewords
    $numShortBlocks = $numBlocks - $rawCodewords % $numBlocks
    $shortBlockLen = [int][math]::Floor($dataCodewords / $numBlocks)
    $dataBlocks = @()
    $eccBlocks = @()
    $offset = 0
    for ($i = 0; $i -lt $numBlocks; $i++) {
        $length = if ($i -lt $numShortBlocks) { $shortBlockLen } else { $shortBlockLen + 1 }
        $block = $data.GetRange($offset, $length).ToArray()
        $offset += $length

        $remainder = New-Object int[] $eccLen
        foreach ($b in $block) {
            $factor = $b -bxor $remainder[0]
            [Array]::Copy($remainder, 1, $remainder, 0, $eccLen - 1)
            $remainder[$eccLen - 1] = 0
            if ($factor) {
                for ($j = 0; $j -lt $eccLen; $j++) {
                    if ($divisor[$j]) {
                        $remainder[$j] = $remainder[$j] -bxor $exp[$log[$divisor[$j]] + $log[$factor]]
                    }
                }
            }
        }
        $dataBlocks += , $block
        $eccBlocks += , $remainder
    }

    # Interleave the data codewords, then the error correction codewords, of all blocks
    $codewords = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -le $shortBlockLen; $i++) {
        foreach ($block in $dataBlocks) {
            if ($i -lt $block.Length) { $codewords.Add($block[$i]) }
        }
    }
    for ($i = 0; $i -lt $eccLen; $i++) {
        foreach ($remainder in $eccBlocks) {
            $codewords.Add($remainder[$i])
        }
    }

    # Function patterns
    $modules = New-Object bool[] ($size * $size)
    $isFunction = New-Object bool[] ($size * $size)
    $setFunction = {
        param([int]$px, [int]$py, [bool]$dark)
        $modules[$py * $size + $px] = $dark
        $isFunction[$py * $size + $px] = $true
    }

    # Timing patterns
    for ($i = 0; $i -lt $size; $i++) {
        & $setFunction 6 $i ($i % 2 -eq 0)
        & $setFunction $i 6 ($i % 2 -eq 0)
    }

    # Finder patterns with their separators
    foreach ($center in @(@(3, 3), @(($size - 4), 3), @(3, ($size - 4)))) {
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -4; $dx -le 4; $dx++) {
                $px = $center[0] + $dx
                $py = $center[1] + $dy
                if ($px -ge 0 -and $px -lt $size -and $py -ge 0 -and $py -lt $size) {
                    $distance = [math]::Max([math]::Abs($dx), [math]::Abs($dy))
                    & $setFunction $px $py ($distance -ne 2 -and $distance -ne 4)
                }
            }
        }
    }

    # Alignment patterns, except on the three corners taken by the finder patterns
    if ($version -gt 1) {
        $numAlign = [int][math]::Floor($version / 7) + 2
        $step = [int][math]::Floor(($version * 8 + $numAlign * 3 + 5) / ($numAlign * 4 - 4)) * 2
        $positions = @(6) + @(for ($i = $numAlign - 2; $i -ge 0; $i--) { $size - 7 - $i * $step })
        $last = $positions.Count - 1
        for ($i = 0; $i -le $last; $i++) {
            for ($j = 0; $j -le $last; $j++) {
                if (($i -eq 0 -and $j -eq 0) -or ($i -eq 0 -and $j -eq $last) -or ($i -eq $last -and $j -eq 0)) { continue }
                for ($dy = -2; $dy -le 2; $dy++) {
                    for ($dx = -2; $dx -le 2; $dx++) {
                        & $setFunction ($positions[$i] + $dx) ($positions[$j] + $dy) ([math]::Max([math]::Abs($dx), [math]::Abs($dy)) -ne 1)
                    }
                }
            }
        }
    }

    # Format information (error correction level and mask, BCH code), written in both copies
    $drawFormatBits = {
        param([bool[]]$target, [int]$mask)
        $formatData = ($level.FormatBits -shl 3) -bor $mask
        $remainder = $formatData
        for ($i = 0; $i -lt 10; $i++) {
            $remainder = ($remainder -shl 1) -bxor ((($remainder -shr 9) -band 1) * 0x537)
        }
        $format = (($formatData -shl 10) -bor $remainder) -bxor 0x5412
        $bit = { param([int]$index) (($format -shr $index) -band 1) -eq 1 }

        for ($i = 0; $i -le 5; $i++) { $target[$i * $size + 8] = & $bit $i }
        $target[7 * $size + 8] = & $bit 6
        $target[8 * $size + 8] = & $bit 7
        $target[8 * $size + 7] = & $bit 8
        for ($i = 9; $i -lt 15; $i++) { $target[8 * $size + 14 - $i] = & $bit $i }

        for ($i = 0; $i -lt 8; $i++) { $target[8 * $size + $size - 1 - $i] = & $bit $i }
        for ($i = 8; $i -lt 15; $i++) { $target[($size - 15 + $i) * $size + 8] = & $bit $i }
        $target[($size - 8) * $size + 8] = $true
    }
    # Reserve the format areas before placing the data
    for ($i = 0; $i -le 8; $i++) {
        $isFunction[$i * $size + 8] = $true
        $isFunction[8 * $size + $i] = $true
    }
    for ($i = 0; $i -lt 8; $i++) {
        $isFunction[8 * $size + $size - 1 - $i] = $true
        $isFunction[($size - 1 - $i) * $size + 8] = $true
    }

    # Version information (versions 7 and later, BCH code)
    if ($version -ge 7) {
        $remainder = $version
        for ($i = 0; $i -lt 12; $i++) {
            $remainder = ($remainder -shl 1) -bxor ((($remainder -shr 11) -band 1) * 0x1F25)
        }
        $versionBits = ($version -shl 12) -bor $remainder
        for ($i = 0; $i -lt 18; $i++) {
            $dark = (($versionBits -shr $i) -band 1) -eq 1
            $a = $size - 11 + $i % 3
            $b = [int][math]::Floor($i / 3)
            & $setFunction $a $b $dark
            & $setFunction $b $a $dark
        }
    }

    # Data placement: two-module columns in a zigzag from the bottom right, skipping the vertical timing pattern
    $bitIndex = 0
    $totalBits = $codewords.Count * 8
    for ($right = $size - 1; $right -ge 1; $right -= 2) {
        if ($right -eq 6) { $right = 5 }
        $upward = (($right + 1) -band 2) -eq 0
        for ($vert = 0; $vert -lt $size; $vert++) {
            $py = if ($upward) { $size - 1 - $vert } else { $vert }
            for ($j = 0; $j -lt 2; $j++) {
                $index = $py * $size + $right - $j
                if (-not $isFunction[$index] -and $bitIndex -lt $totalBits) {
                    $modules[$index] = (($codewords[$bitIndex -shr 3] -shr (7 - ($bitIndex -band 7))) -band 1) -eq 1
                    $bitIndex++
                }
            }
        }
    }

    # The eight mask conditions of every module, one bit per mask
    $maskBits = New-Object int[] ($size * $size)
    for ($py = 0; $py -lt $size; $py++) {
        for ($px = 0; $px -lt $size; $px++) {
            $product = $px * $py
            $value = 0
            if (($px + $py) % 2 -eq 0) { $value = $value -bor 1 }
            if ($py % 2 -eq 0) { $value = $value -bor 2 }
            if ($px % 3 -eq 0) { $value = $value -bor 4 }
            if (($px + $py) % 3 -eq 0) { $value = $value -bor 8 }
            if (([int][math]::Floor($px / 3) + [int][math]::Floor($py / 2)) % 2 -eq 0) { $value = $value -bor 16 }
            if ($product % 2 + $product % 3 -eq 0) { $value = $value -bor 32 }
            if (($product % 2 + $product % 3) % 2 -eq 0) { $value = $value -bor 64 }
            if ((($px + $py) % 2 + $product % 3) % 2 -eq 0) { $value = $value -bor 128 }
            $maskBits[$py * $size + $px] = $value
        }
    }

    # Apply each mask and keep the one with the lowest penalty score
    $bestPenalty = [int]::MaxValue
    $best = $null
    for ($mask = 0; $mask -lt 8; $mask++) {
        $candidate = [bool[]]$modules.Clone()
        $flag = 1 -shl $mask
        for ($i = 0; $i -lt $candidate.Length; $i++) {
            if (-not $isFunction[$i] -and ($maskBits[$i] -band $flag)) {
                $candidate[$i] = -not $candidate[$i]
            }
        }
        & $drawFormatBits $candidate $mask

        $chars = New-Object char[] ($size * $size)
        $columnChars = New-Object char[] ($size * $size)
        for ($py = 0; $py -lt $size; $py++) {
            for ($px = 0; $px -lt $size; $px++) {
                $c = if ($candidate[$py * $size + $px]) { [char]'1' } else { [char]'0' }
                $chars[$py * $size + $px] = $c
                $columnChars[$px * $size + $py] = $c
            }
        }
        $rows = for ($py = 0; $py -lt $size; $py++) { [string]::new($chars, $py * $size, $size) }
        $columns = for ($px = 0; $px -lt $size; $px++) { [string]::new($columnChars, $px * $size, $size) }
        $lines = ($rows + $columns) -join "|"

        $penalty = 0
        # Runs of five or more modules of the same color in a row or column
        foreach ($run in [regex]::Matches($lines, "0{5,}|1{5,}")) {
            $penalty += $run.Length - 2
        }
        # Finder-like patterns with four light modules on one side (the area outside the symbol is light)
        $padded = "0000" + ($lines -replace "\|", "0000|0000") + "0000"
        $penalty += [regex]::Matches($padded, "(?=00001011101|10111010000)").Count * 40
        # 2x2 blocks of the same color
        for ($py = 0; $py -lt $size - 1; $py++) {
            $top = $rows[$py]
            $bottom = $rows[$py + 1]
            for ($px = 0; $px -lt $size - 1; $px++) {
                $c = $top[$px]
                if ($c -eq $top[$px + 1] -and $c -eq $bottom[$px] -and $c -eq $bottom[$px + 1]) {
                    $penalty += 3
                }
            }
        }
        # Balance of dark and light modules
        $joined = -join $rows
        $dark = $joined.Length - $joined.Replace("1", "").Length
        $total = $size * $size
        $penalty += ([int][math]::Floor(([math]::Abs($dark * 20 - $total * 10) + $total - 1) / $total) - 1) * 10

        # Not part of the standard score: decoders such as ZXing look for finder patterns as five runs
        # (dark, light, dark, light, dark) in the proportions 1:1:3:1:1 with a 50% tolerance per run, checked
        # across a row and then down the column through the middle. Such a cross in the data area can make
        # them miss a real finder pattern. Any mask gives a valid symbol, so masks that create these crosses
        # are used only when every mask does.
        $columnRuns = foreach ($line in $columns) { , [regex]::Matches($line, "0+|1+") }
        for ($py = 0; $py -lt $size; $py++) {
            $runs = [regex]::Matches($rows[$py], "0+|1+")
            for ($k = $(if ($rows[$py][0] -eq [char]'1') { 0 } else { 1 }); $k + 4 -lt $runs.Count; $k += 2) {
                $h = @($runs[$k].Length, $runs[$k + 1].Length, $runs[$k + 2].Length, $runs[$k + 3].Length, $runs[$k + 4].Length)
                $hTotal = $h[0] + $h[1] + $h[2] + $h[3] + $h[4]
                $unit = $hTotal / 7
                if ([math]::Abs($unit - $h[0]) -ge $unit / 2 -or [math]::Abs($unit - $h[1]) -ge $unit / 2 -or [math]::Abs(3 * $unit - $h[2]) -ge 1.5 * $unit -or
                    [math]::Abs($unit - $h[3]) -ge $unit / 2 -or [math]::Abs($unit - $h[4]) -ge $unit / 2) { continue }
                $px = $runs[$k + 2].Index + [int][math]::Floor($h[2] / 2)
                # The three real finder patterns
                if (($px -le 6 -and $py -le 6) -or ($px -ge $size - 7 -and $py -le 6) -or ($px -le 6 -and $py -ge $size - 7)) { continue }

                $vertical = $columnRuns[$px]
                for ($j = 2; $j + 2 -lt $vertical.Count; $j++) {
                    if ($py -lt $vertical[$j].Index -or $py -ge $vertical[$j].Index + $vertical[$j].Length) { continue }
                    $v = @($vertical[$j - 2].Length, $vertical[$j - 1].Length, $vertical[$j].Length, $vertical[$j + 1].Length, $vertical[$j + 2].Length)
                    $vTotal = $v[0] + $v[1] + $v[2] + $v[3] + $v[4]
                    $unit = $vTotal / 7
                    if ([math]::Abs($unit - $v[0]) -lt $unit / 2 -and [math]::Abs($unit - $v[1]) -lt $unit / 2 -and [math]::Abs(3 * $unit - $v[2]) -lt 1.5 * $unit -and
                        [math]::Abs($unit - $v[3]) -lt $unit / 2 -and [math]::Abs($unit - $v[4]) -lt $unit / 2 -and 5 * [math]::Abs($vTotal - $hTotal) -lt 2 * $hTotal) {
                        $penalty += 1000
                    }
                    break
                }
            }
        }

        if ($penalty -lt $bestPenalty) {
            $bestPenalty = $penalty
            $best = $candidate
            $bestMask = $mask
        }
    }

    [pscustomobject]@{
        Size            = $size
        Modules         = $best
        Version         = $version
        ErrorCorrection = $level.Name
        Mask            = $bestMask
    }
}
function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Filters the apps of the Install tab by search text and by category

        .DESCRIPTION
            An app is shown when its name or description contains the search text and its
            category is one of the categories chosen with the chips. An empty search text matches
            every app, and no category chosen matches every category.

            While a filter is active the categories with results are expanded, otherwise a collapsed
            category would hide them; without filters the categories go back to how the user left them.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as normal characters.

        .PARAMETER Categories
            The categories to show. Without categories every category is shown.
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = "",

        [Parameter(Mandatory=$false)]
        [string[]]$Categories = @()
    )

    if ($null -eq $sync.ItemsControl) {
        return
    }

    # Categories expanded by the filters, so that clearing the filters can collapse them again
    if ($null -eq $sync.AppCategoryAutoExpanded) {
        $sync.AppCategoryAutoExpanded = @{}
    }

    $activeCategories = @($Categories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hasSearch = -not [string]::IsNullOrWhiteSpace($SearchString)
    $hasCategories = $activeCategories.Count -gt 0

    # Reset the visibility if there are no filters
    if (-not $hasSearch -and -not $hasCategories) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # A category expanded by a filter goes back to how the user left it
                $categoryName = $categoryLabel.Content -replace '^[+-] ', ''
                if ($sync.AppCategoryAutoExpanded.ContainsKey($categoryName)) {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^- ", "+ "
                    $sync.AppCategoryAutoExpanded.Remove($categoryName)
                }

                # Respect the collapsed state of categories (indicated by + prefix)
                if ($categoryLabel.Content -like "+*") {
                    $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                } else {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                }

                # Show all apps within the category
                $wrapPanel.Children | ForEach-Object {
                    $_.Visibility = [Windows.Visibility]::Visible
                }
            }
        }
        return
    }

    $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            foreach ($appControl in $wrapPanel.Children) {
                $appEntry = $sync.configs.applicationsHashtable[[string]$appControl.Tag]
                $categoryMatch = -not $hasCategories -or $activeCategories -contains $appEntry.Category
                $textMatch = -not $hasSearch -or
                    $appEntry.Content -like "*$escapedSearchString*" -or
                    $appEntry.Description -like "*$escapedSearchString*"

                if ($appEntry -and $categoryMatch -and $textMatch) {
                    $appControl.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                } else {
                    $appControl.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Expand the category to show its matches, and remember that it was collapsed
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    $sync.AppCategoryAutoExpanded[($categoryLabel.Content -replace '^- ', '')] = $true
                }
            } else {
                # Hide the entire category container if no matches
                $_.Visibility = [Windows.Visibility]::Collapsed
            }
        }
    }
}
function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )

    # The same search serves the tweaks and the Windows apps
    $panelName = if ($sync.currentTab -eq "AppX") { "appxpanel" } else { "tweakspanel" }
    # Wildcards in the search text are normal characters
    $SearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        # Show all categories
        $tweakspanel = $sync.Form.FindName($panelName)
        $tweakspanel.Children | ForEach-Object {
            $_.Visibility = [Windows.Visibility]::Visible

            # Foreach category section, show all items
            if ($_ -is [Windows.Controls.Border]) {
                $_.Visibility = [Windows.Visibility]::Visible

                # Find ItemsControl
                $dockPanel = $_.Child
                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                    if ($itemsControl) {
                        # Show items in the category
                        foreach ($item in $itemsControl.Items) {
                            if ($item -is [Windows.Controls.Label]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            } elseif ($item -is [Windows.Controls.DockPanel] -or
                                      $item -is [Windows.Controls.StackPanel]) {
                                $item.Visibility = [Windows.Visibility]::Visible
                            }
                        }
                    }
                }
            }
        }
        return
    }

    # Search for matching tweaks when search string is not null
    $tweakspanel = $sync.Form.FindName($panelName)

    $tweakspanel.Children | ForEach-Object {
        $categoryBorder = $_
        $categoryVisible = $false

        if ($_ -is [Windows.Controls.Border]) {
            # Find the ItemsControl
            $dockPanel = $_.Child
            if ($dockPanel -is [Windows.Controls.DockPanel]) {
                $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] }
                if ($itemsControl) {
                    $categoryLabel = $null

                    # Process all items in the ItemsControl
                    for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                        $item = $itemsControl.Items[$i]

                        if ($item -is [Windows.Controls.Label]) {
                            $categoryLabel = $item
                            $item.Visibility = [Windows.Visibility]::Collapsed
                        } elseif ($item -is [Windows.Controls.DockPanel]) {
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                            $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                            if ($label -and ($label.Content -like "*$SearchString*" -or $label.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        } elseif ($item -is [Windows.Controls.StackPanel]) {
                            # StackPanel which contain checkboxes or other elements
                            $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                            if ($checkbox -and ($checkbox.Content -like "*$SearchString*" -or $checkbox.ToolTip -like "*$SearchString*")) {
                                $item.Visibility = [Windows.Visibility]::Visible
                                if ($categoryLabel) { $categoryLabel.Visibility = [Windows.Visibility]::Visible }
                                $categoryVisible = $true
                            } else {
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }
                        }
                    }
                }
            }

            # Set the visibility based on if any item matched
            $categoryBorder.Visibility = if ($categoryVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

        }
    }
}
function Get-LocalizedYesNo {
    <#
    .SYNOPSIS
    This function runs choice.exe and captures its output to extract yes no in a localized Windows

    .DESCRIPTION
    The function retrieves the output of the command 'cmd /c "choice <nul 2>nul"' and converts the default output for Yes and No
    in the localized format, such as "Yes=<first character>, No=<second character>".

    .EXAMPLE
    $yesNoArray = Get-LocalizedYesNo
    Write-Host "Yes=$($yesNoArray[0]), No=$($yesNoArray[1])"
    #>

    # Run choice and capture its options as output
    # The output shows the options for Yes and No as "[Y,N]?" in the (partially) localized format.
    # eg. English: [Y,N]?
    # Dutch: [Y,N]?
    # German: [J,N]?
    # French: [O,N]?
    # Spanish: [S,N]?
    # Italian: [S,N]?
    # Russian: [Y,N]?

    $line = cmd /c "choice <nul 2>nul"
    $charactersArray = @()
    $regexPattern = '([a-zA-Z])'
    $charactersArray = [regex]::Matches($line, $regexPattern) | ForEach-Object { $_.Groups[1].Value }

    Write-Debug "According to takeown.exe local Yes is $charactersArray[0]"
    # Return the array of characters
    return $charactersArray

  }
function Get-WinUtilAppCategoryName {
    <#
    .SYNOPSIS
        Returns the Italian name shown for a category of applications.json

    .PARAMETER Category
        The category as written in applications.json. A category without a translation is shown as it is.

    .EXAMPLE
        Get-WinUtilAppCategoryName -Category "Multimedia Tools"
    #>

    param([string]$Category)

    $names = @{
        "Browsers"         = "Browser"
        "Communications"   = "Comunicazione"
        "Development"      = "Sviluppo"
        "Document"         = "Documenti"
        "Games"            = "Giochi"
        "Microsoft Tools"  = "Strumenti Microsoft"
        "Multimedia Tools" = "Multimedia"
        "Pro Tools"        = "Strumenti professionali"
        "Selfhosted Tools" = "Self-hosted"
        "Utilities"        = "Utilit$([char]0x00E0)"
    }

    if ($names.ContainsKey($Category)) {
        return $names[$Category]
    }
    return $Category
}
function Get-WinUtilAppEntryHandlers {
    <#
        .SYNOPSIS
            The event handlers shared by every app entry on the Install tab

        .DESCRIPTION
            A script block written inside a loop is a new script block every time round, and building
            them for every app is the largest cost of drawing the app list. None of them depend on the
            entry: they read the control that raised the event through $this, so one set serves every app.
    #>

    if ($null -ne $script:WinUtilAppEntryHandlers) {
        return $script:WinUtilAppEntryHandlers
    }

    $script:WinUtilAppEntryHandlers = @{
        BorderClick = {
            $childCheckbox = $sync.$($this.Tag)
            $childCheckbox.IsChecked = -not $childCheckbox.IsChecked
        }
        MouseEnter = {
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        }
        MouseLeave = {
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        }
        RightClick = {
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        }
        Checked = {
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $this.Parent.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        }
        Unchecked = {
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $this.Parent.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        }
        # Without a connection, or when the site has no icon, the initial of the app stays visible
        ImageFailed = {
            $this.Visibility = "Collapsed"
            $this.Parent.Children[0].Visibility = "Visible"
        }
    }

    return $script:WinUtilAppEntryHandlers
}
function Get-WinUtilDNSBenchmark {
    <#

    .SYNOPSIS
        Measures the latency of the neutral DNS providers (TCP connection to port 53) to find the fastest one

    .PARAMETER TimeoutMs
        Maximum time for each connection test, in milliseconds

    .OUTPUTS
        Provider, PrimaryIP and LatencyMs of each provider, the fastest first. 9999 means no answer.

    .EXAMPLE
        $fastest = (Get-WinUtilDNSBenchmark)[0]

    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 9998)]
        [int]$TimeoutMs = 1500
    )

    $dnsConfigs = $sync.configs.dns
    if ($null -eq $dnsConfigs) {
        Write-Warning "DNS configurations not found in `$sync.configs.dns."
        return @()
    }

    $results = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($prop in $dnsConfigs.PSObject.Properties) {
        $providerName = $prop.Name
        $primaryIp = $prop.Value.Primary
        if (-not $primaryIp) { continue }

        # Only the providers marked in dns.json, so that a filtering service is never chosen automatically
        if ($prop.Value.BenchmarkEligible -ne $true) {
            continue
        }

        $latency = 9999
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $asyncResult = $client.BeginConnect($primaryIp, 53, $null, $null)
            $success = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
            $stopwatch.Stop()

            if ($success) {
                $client.EndConnect($asyncResult)
                $latency = [int]$stopwatch.ElapsedMilliseconds
            }
        } catch {
            $latency = 9999
        } finally {
            if ($null -ne $client) {
                $client.Dispose()
            }
        }

        $results.Add([PSCustomObject]@{
            Provider  = $providerName
            PrimaryIP = $primaryIp
            LatencyMs = $latency
        })
    }

    return @($results | Sort-Object LatencyMs)
}
function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of the AppX packages installed for all users

    #>

    # In PowerShell 7 the AppX module can depend on a temporary compatibility session of
    # Windows PowerShell, so the packages are read in Windows PowerShell 5.1
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to get the installed AppX packages: $(($packageOutput | Out-String).Trim())"
        return @()
    }

    return @($packageOutput)
}
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
function Get-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Finds the choice of a combo box that matches the current registry values

    .PARAMETER Registry
        The registry entries of the combo box, with the value of each choice in Values

    .OUTPUTS
        The name of the matching choice. Throws an error when the values match no choice.
    #>
    param(
        [Parameter(Mandatory)]
        $Registry
    )

    foreach ($state in $Registry[0].Values.PSObject.Properties) {
        $stateMatches = $true
        foreach ($setting in @($Registry)) {
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $actualValue = if ($currentValue.Exists -and $null -ne $currentValue.Value) { $currentValue.Value } else { $setting.DefaultValue }
            $configuredValue = $setting.Values.PSObject.Properties[$state.Name].Value
            # A removed value means the default of Windows
            $expectedValue = if ($configuredValue -eq "<RemoveEntry>") { $setting.DefaultValue } else { $configuredValue }
            if ([string]$actualValue -ne [string]$expectedValue) {
                $stateMatches = $false
                break
            }
        }
        if ($stateMatches) {
            return $state.Name
        }
    }

    throw "I valori del registro non corrispondono a nessuna delle scelte disponibili."
}
function Get-WinUtilRegistryComboValue {
    <#
    .SYNOPSIS
        Reads one registry value of a combo box whose choices are registry states

    .PARAMETER Setting
        The registry entry of the combo box in tweaks.json

    .OUTPUTS
        Exists, and the Value when the value exists
    #>
    param(
        [Parameter(Mandatory)]
        $Setting
    )

    try {
        $item = Get-ItemProperty -Path $Setting.Path -Name $Setting.Name -ErrorAction Stop
        $property = $item.PSObject.Properties[$Setting.Name]
        return [pscustomobject]@{ Exists = $null -ne $property; Value = $property.Value }
    } catch [System.Management.Automation.PSArgumentException] {
        # The registry provider throws PSArgumentException when a named value is missing
        return [pscustomobject]@{ Exists = $false; Value = $null }
    } catch [System.Management.Automation.ItemNotFoundException] {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
}
function Get-WinUtilSelectedPackages
{
     <#
    .SYNOPSIS
        Sorts given packages based on installer preference and availability.

    .OUTPUTS
        Hashtable. Key = Package Manager, Value = ArrayList of packages to install
    #>
    param (
        [Parameter(Mandatory=$true)]
        $PackageList,
        [Parameter(Mandatory=$true)]
        [PackageManagers]$Preference,
        [ValidateSet("Install", "Uninstall")]
        [string]$Action = "Install"
    )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packages = [System.Collections.Hashtable]::new()
    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages[[PackageManagers]::Winget] = $packagesWinget
    $packages[[PackageManagers]::Choco] = $packagesChoco

    Write-Debug "Checking packages using Preference '$($Preference)'"

    function Test-PackageId {
        param($PackageId)
        -not ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na")
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId,
            [string]$Manager
        )

        # A field can hold several IDs separated by ";" (dependencies first, then the app).
        # Uninstalling removes only the app, the last ID.
        $ids = [string]$PackageId -split ";"
        if ($Action -eq "Uninstall") {
            $ids = @($ids[-1])
        }
        foreach ($id in $ids) {
            $id = $id.Trim()
            if ((Test-PackageId $id) -and -not $Target.Contains($id)) {
                $null = $Target.Add($id)
                Write-Host "Queueing $id for $Manager..."
            }
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if (Test-PackageId $package.choco) {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco -Manager "Chocolatey"
                } else {
                    Write-Debug "$($package.content) has no Choco value."
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget -Manager "WinGet"
                }
                break
            }
            "Winget" {
                if (Test-PackageId $package.winget) {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget -Manager "WinGet"
                } else {
                    Write-Debug "$($package.content) has no WinGet value."
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco -Manager "Chocolatey"
                }
                break
            }
        }
    }

    return $packages
}
Function Get-WinUtilToggleStatus {
    <#

    .SYNOPSIS
        Pulls the registry keys for the given toggle switch and checks whether the toggle should be checked or unchecked

    .PARAMETER ToggleSwitch
        The name of the toggle to check

    .OUTPUTS
        Boolean to set the toggle's status to

    #>

    Param($ToggleSwitch)

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry
    if (-not $ToggleSwitchReg) {
        return $false
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
    }

    # Reading the state must not change the registry: a missing key or value takes the DefaultState of the entry
    foreach ($regentry in $ToggleSwitchReg) {
        $regstate = $null
        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path -ErrorAction SilentlyContinue).$($regentry.Name)
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
            return $false
        }
    }

    return $true
}
function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            } catch {
                <#I am here so errors don't get outputted for a couple variables that don't have the .GetType() attribute#>
            }
        }
        return $output
    }
    return $keys
}
function Get-WPFObjectName {
    <#
        .SYNOPSIS
            This is a helper function that generates an objectname with the prefix WPF that can be used as a Powershell Variable after compilation.
            To achieve this, all characters that are not a-z, A-Z or 0-9 are simply removed from the name.

        .PARAMETER type
            The type of object for which the name should be generated. (e.g. Label, Button, CheckBox...)

        .PARAMETER name
            The name or description to be used for the object. (invalid characters are removed)

        .OUTPUTS
            A string that can be used as a object/variable name in powershell.
            For example: WPFLabelMicrosoftTools

        .EXAMPLE
            Get-WPFObjectName -type Label -name "Microsoft Tools"
    #>

    param(
        [Parameter(Mandatory, position=0)]
        [string]$type,

        [Parameter(position=1)]
        [string]$name
    )

    $Output = $("WPF"+$type+$name) -replace '[^a-zA-Z0-9]', ''
    return $Output
}
function Hide-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Hides the busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall has finished.
    #>
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Collapsed
        $sync.InstallAppAreaBorder.IsEnabled = $true
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 0
    }
}
    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

                Also creates an overlay with a progress bar and text to indicate that an install or uninstall is in progress

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        $sync.InstallAppAreaBorder = $Border

        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $sync.InstallAppAreaScrollViewer = $scrollViewer
        $Border.Child = $scrollViewer

        # Initialize the Blur Effect for the ScrollViewer, which will be used to indicate that an install/uninstall is in progress
        $blurEffect = New-Object Windows.Media.Effects.BlurEffect
        $blurEffect.Radius = 0
        $scrollViewer.Effect = $blurEffect

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        $overlay = New-Object Windows.Controls.Border
        $overlay.CornerRadius = New-Object Windows.CornerRadius(10)
        $overlay.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallOverlayBackgroundColor")
        $overlay.Visibility = [Windows.Visibility]::Collapsed

        # Also add the overlay to the target Grid on top of the App Area
        $targetGrid.Children.Add($overlay) | Out-Null
        $sync.InstallAppAreaOverlay = $overlay

        $overlayText = New-Object Windows.Controls.TextBlock
        $overlayText.Text = "Installazione app in corso..."
        $overlayText.HorizontalAlignment = 'Center'
        $overlayText.VerticalAlignment = 'Center'
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        $overlayText.Background = "Transparent"
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "HeaderFontSize")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, "FontFamily")
        $overlayText.FontWeight = [Windows.FontWeights]::Bold
        $overlayText.Margin = "0,0,0,10"
        $sync.InstallAppAreaOverlayText = $overlayText

        $progressbar = New-Object Windows.Controls.ProgressBar
        $progressbar.Name = "ProgressBar"
        $progressbar.Width = 250
        $progressbar.Height = 8
        $sync.ProgressBar = $progressbar

        # Add a TextBlock below the progress bar for the progress text, so it stays readable on any fill level
        $progressBarTextBlock = New-Object Windows.Controls.TextBlock
        $progressBarTextBlock.Name = "progressBarTextBlock"
        $progressBarTextBlock.FontWeight = [Windows.FontWeights]::SemiBold
        $progressBarTextBlock.FontSize = 13
        $progressBarTextBlock.Width = $progressbar.Width
        $progressBarTextBlock.Margin = "0,8,0,0"
        $progressBarTextBlock.TextAlignment = "Center"
        $progressBarTextBlock.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarTextColor")
        $progressBarTextBlock.TextTrimming = "CharacterEllipsis"
        $progressBarTextBlock.Background = "Transparent"
        $sync.progressBarTextBlock = $progressBarTextBlock

        # Stack the progress bar and its text
        $progressPanel = New-Object Windows.Controls.StackPanel
        $progressPanel.Orientation = "Vertical"
        $progressPanel.Width = $progressbar.Width
        $progressPanel.Margin = "0,10,0,10"
        $progressPanel.Children.Add($progressbar) | Out-Null
        $progressPanel.Children.Add($progressBarTextBlock) | Out-Null

        $overlayStackPanel = New-Object Windows.Controls.StackPanel
        $overlayStackPanel.Orientation = "Vertical"
        $overlayStackPanel.HorizontalAlignment = 'Center'
        $overlayStackPanel.VerticalAlignment = 'Center'
        $overlayStackPanel.Children.Add($overlayText) | Out-Null
        $overlayStackPanel.Children.Add($progressPanel) | Out-Null

        $overlay.Child = $overlayStackPanel

        return $itemsControl
    }
function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable[$appKey]
        $handlers = Get-WinUtilAppEntryHandlers

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp($handlers.BorderClick)
        $border.Add_MouseEnter($handlers.MouseEnter)
        $border.Add_MouseLeave($handlers.MouseLeave)
        $border.Add_MouseRightButtonUp($handlers.RightClick)

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked($handlers.Checked)
        $checkbox.Add_Unchecked($handlers.Unchecked)

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        # The icon of the website of the app, with its initial while the icon is missing
        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 6, 0)
        $icon.VerticalAlignment = [Windows.VerticalAlignment]::Center
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"
        $fallback.HorizontalAlignment = "Center"
        $fallback.VerticalAlignment = "Center"
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($app.link -and -not $PARAM_OFFLINE) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            [Windows.Media.RenderOptions]::SetBitmapScalingMode($logo, [Windows.Media.BitmapScalingMode]::HighQuality)
            $logo.Add_ImageFailed($handlers.ImageFailed)
            $fallback.Visibility = "Collapsed"
            [void]$icon.Children.Add($logo)
            try {
                # WPF downloads the icon by itself, without a runspace. The image cache is skipped so that a
                # window opened again in the same PowerShell session does not reuse images of the closed one.
                $bitmap = [Windows.Media.Imaging.BitmapImage]::new()
                $bitmap.BeginInit()
                $bitmap.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
                $bitmap.UriSource = [uri]"https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))"
                $bitmap.EndInit()
                $logo.Source = $bitmap
            } catch {
                $logo.Visibility = "Collapsed"
                $fallback.Visibility = "Visible"
            }
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content

        # Change color to Green if FOSS
        if ($app.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the icon and the name to the Checkbox
        [void]$contentPanel.Children.Add($appName)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        $border.Child = $checkBox
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }
function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category. Lists, because appending to an array copies it.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps[$appKey].Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = [System.Collections.Generic.List[string]]::new()
            }
            $appsByCategory[$category].Add($appKey)
        }
        # The categories are shown with their Italian names, in alphabetical order
        foreach ($category in $($appsByCategory.Keys | Sort-Object { Get-WinUtilAppCategoryName $_ })) {
            $categoryName = Get-WinUtilAppCategoryName $category
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $categoryName)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $categoryName"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($sender, $e)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $sender.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # A click wins over a category that the filters expanded by themselves
                    if ($sync.AppCategoryAutoExpanded) {
                        $sync.AppCategoryAutoExpanded.Remove(($sender.Content -replace '^[+-] ', ''))
                    }

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $sender.Content = $sender.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $sender.Content = $sender.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            # Add apps to the wrap panel
            $appsByCategory[$category] | Sort-Object | ForEach-Object {
                $sync.$_ = $(Initialize-InstallAppEntry -TargetElement $wrapPanel -AppKey $_)
            }
        }
    }
function Initialize-WinUtilAppCategoryChips {
    <#
    .SYNOPSIS
        Creates the category filters above the app list of the Install tab

    .DESCRIPTION
        One chip per category of applications.json, in the order of the list, after the chip that
        shows every category. A click shows only that category (a second click shows them all
        again), Ctrl+click adds or removes the category from the ones shown.

    .PARAMETER Apps
        The Hashtable of Apps, from which the categories are taken
    #>

    param($Apps)

    $chipPanel = $sync.Form.FindName("WPFAppCategoryChips")
    if (-not $chipPanel) {
        return
    }
    $chipPanel.Children.Clear()
    $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()
    $sync.AppCategoryChips = [System.Collections.Generic.List[object]]::new()

    $filterIcon = New-Object Windows.Controls.TextBlock
    $filterIcon.Text = [string][char]0xE71C
    $filterIcon.FontFamily = "Segoe MDL2 Assets"
    $filterIcon.VerticalAlignment = "Center"
    $filterIcon.Margin = New-Object Windows.Thickness(2, 0, 10, 6)
    $filterIcon.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "IconFontSize")
    $filterIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "LabelboxForegroundColor")
    $filterIcon.ToolTip = "Filtra per categoria. Ctrl+clic per mostrarne pi$([char]0x00F9) di una."
    [void]$chipPanel.Children.Add($filterIcon)

    $categories = @($Apps.Values | ForEach-Object { $_.Category } | Sort-Object -Unique | Sort-Object { Get-WinUtilAppCategoryName $_ })
    foreach ($category in @("") + $categories) {
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $sync.Form.Resources.AppCategoryChipStyle
        # The chip carries its category, empty for the one that shows every category
        $chip.Tag = $category
        $chip.Content = if ($category) { Get-WinUtilAppCategoryName $category } else { "Tutte" }
        $chip.IsChecked = -not $category
        [System.Windows.Automation.AutomationProperties]::SetName($chip, "Filtro categoria: $($chip.Content)")
        $chip.Add_Click({
            $additive = [bool]([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)
            Set-WinUtilAppCategoryFilter -Category $this.Tag -Additive:$additive
        })
        [void]$chipPanel.Children.Add($chip)
        $sync.AppCategoryChips.Add($chip)
    }
}
function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers an AppX package again from the copy left on the PC, or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The Microsoft Store product ID, used when no copy of the package is left on the PC

    .OUTPUTS
        True when the package was installed

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-Host "Installing $Name"

    # The AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Both the installed and
    # the provisioned packages can point to a manifest that can be registered again.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-Host "Registered $Name from $manifestPath"
            return $true
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Local registration of $Name failed: $(($manifestOutput | Out-String).Trim())"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        Write-Warning "$Name cannot be installed: no copy is left on the PC and it has no Microsoft Store ID."
        return $false
    }

    Write-Host "No copy of $Name is left on the PC: installing it from the Microsoft Store ($StoreId)"
    Install-WinUtilWinget
    $exitCode = Invoke-WinUtilProcess -FilePath "winget" -ArgumentList "install --id $StoreId --source msstore --silent --accept-source-agreements --accept-package-agreements" -NoNewWindow
    # Installed, already installed, or installed with a restart needed to finish
    return $exitCode -in @(0, -1978335135, 3010, 1641, -1978334967, -1978334965)
}
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>
    if ((Test-WinUtilPackageManager -choco) -eq "installed") {
        return
    }

    Write-Host "Chocolatey is not installed. Installing now..."
    # Windows PowerShell 5.1 can offer a protocol the site refuses; the official bootstrap sets it too
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing -TimeoutSec 60
    Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))

    # The installer extends PATH only for new processes: add the new folders to this one too,
    # otherwise choco is not found until WinRUtil is restarted
    $current = $env:PATH -split ';' | Where-Object { $_ }
    $saved = @(
        [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        [System.Environment]::GetEnvironmentVariable("Path", "User")
    ) -join ';' -split ';' | Where-Object { $_ }
    $missing = $saved | Where-Object { $current -notcontains $_ }
    if ($missing) {
        $env:PATH = (@($current) + @($missing)) -join ';'
    }

    if (-not (Get-Command -Name choco -ErrorAction SilentlyContinue)) {
        throw "Chocolatey was installed but choco is still not on PATH."
    }
}
function Install-WinUtilProgramChoco {
    <#
    .SYNOPSIS
    Manages the installation or uninstallation of a list of Chocolatey packages.

    .PARAMETER Programs
    A string array containing the programs to be installed or uninstalled.

    .PARAMETER Action
    Specifies the action to perform: "Install" or "Uninstall". The default value is "Install".

    .DESCRIPTION
    This function processes a list of programs to be managed using Chocolatey. Depending on the specified action, it either installs or uninstalls each program in the list, updating the taskbar progress accordingly. After all operations are completed, temporary output files are cleaned up.

    .EXAMPLE
    Install-WinUtilProgramChoco -Programs @("7zip","chrome") -Action "Uninstall"
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Programs,

        [Parameter(Position = 1)]
        [String]$Action = "Install"
    )

    function Initialize-OutputFile {
        <#
        .SYNOPSIS
        Initializes an output file by removing any existing file and creating a new, empty file at the specified path.

        .PARAMETER filePath
        The full path to the file to be initialized.

        .DESCRIPTION
        This function ensures that the specified file is reset by removing any existing file at the provided path and then creating a new, empty file. It is useful when preparing a log or output file for subsequent operations.

        .EXAMPLE
        Initialize-OutputFile -filePath "C:\temp\output.txt"
        #>

        param ($filePath)
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
        New-Item -ItemType File -Path $filePath | Out-Null
    }

    function Invoke-ChocoCommand {
        <#
        .SYNOPSIS
        Executes a Chocolatey command with the specified arguments and returns the exit code.

        .PARAMETER arguments
        The arguments to be passed to the Chocolatey command.

        .DESCRIPTION
        This function runs a specified Chocolatey command by passing the provided arguments to the `choco` executable. It waits for the process to complete and then returns the exit code, allowing the caller to determine success or failure based on the exit code.

        .RETURNS
        [int]
        The exit code of the Chocolatey command.

        .EXAMPLE
        $exitCode = Invoke-ChocoCommand -arguments "install 7zip -y"
        #>

        param ($arguments)
        # Only choco is waited for: an installer may leave the installed application open
        return Invoke-WinUtilProcess -FilePath "choco" -ArgumentList $arguments
    }

    function Test-UpgradeNeeded {
        <#
        .SYNOPSIS
        Checks if an upgrade is needed for a Chocolatey package based on the content of a log file.

        .PARAMETER filePath
        The path to the log file that contains the output of a Chocolatey install command.

        .DESCRIPTION
        This function reads the specified log file and checks for keywords that indicate whether an upgrade is needed. It returns a boolean value indicating whether the terms "reinstall" or "already installed" are present, which suggests that the package might need an upgrade.

        .RETURNS
        [bool]
        True if the log file indicates that an upgrade is needed; otherwise, false.

        .EXAMPLE
        $isUpgradeNeeded = Test-UpgradeNeeded -filePath "C:\temp\install-output.txt"
        #>

        param ($filePath)
        return Get-Content -Path $filePath | Select-String -Pattern "reinstall|already installed" -Quiet
    }

    function Update-TaskbarProgress {
        <#
        .SYNOPSIS
        Updates the taskbar progress based on the current installation progress.

        .PARAMETER currentIndex
        The current index of the program being installed or uninstalled.

        .PARAMETER totalPrograms
        The total number of programs to be installed or uninstalled.

        .DESCRIPTION
        This function calculates the progress of the installation or uninstallation process and updates the taskbar accordingly. The taskbar is set to "Normal" if all programs have been processed, otherwise, it is set to "Error" as a placeholder.

        .EXAMPLE
        Update-TaskbarProgress -currentIndex 3 -totalPrograms 10
        #>

        param (
            [int]$currentIndex,
            [int]$totalPrograms
        )
        $progressState = if ($currentIndex -eq $totalPrograms) { "Normal" } else { "Error" }
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state $progressState -value ($currentIndex / $totalPrograms) }
    }

    function Add-ReportAction {
        <#
        .SYNOPSIS
        Records the result of a Chocolatey operation for the intervention report.

        .PARAMETER Program
        The name of the Chocolatey package; the report shows the app name used in the Install tab.

        .PARAMETER Operation
        The description of the operation, with {0} in place of the app name.

        .PARAMETER Succeeded
        Whether the operation completed successfully.
        #>

        param (
            [string]$Program,
            [string]$Operation,
            [bool]$Succeeded
        )
        $appName = ($sync.configs.applicationsHashtable.Values | Where-Object { $_.choco -eq $Program } | Select-Object -First 1).content
        if (-not $appName) { $appName = $Program }
        Add-WinUtilSessionAction -Area "Programmi" -Text ($Operation -f $appName) -Status $(if ($Succeeded) { "Success" } else { "Error" })
    }

    function Install-ChocoPackage {
        <#
        .SYNOPSIS
        Installs a Chocolatey package and optionally upgrades it if needed.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be installed.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be installed.

        .DESCRIPTION
        This function installs a Chocolatey package by running the `choco install` command. If the installation output indicates that an upgrade might be needed, the function will attempt to upgrade the package. The taskbar progress is updated after each package is processed.

        .EXAMPLE
        Install-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $installOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt"
        Initialize-OutputFile $installOutputFile

        Write-Host "Starting installation of $Program with Chocolatey."

        try {
            $installStatusCode = Invoke-ChocoCommand "install $Program -y --log-file $installOutputFile"
            # 1641 and 3010: installed, a restart is needed to finish
            if ($installStatusCode -in @(0, 1641, 3010)) {

                if (Test-UpgradeNeeded $installOutputFile) {
                    $upgradeStatusCode = Invoke-ChocoCommand "upgrade $Program -y"
                    Write-Host "$Program was" $(if ($upgradeStatusCode -eq 0) { "upgraded successfully." } else { "not upgraded." })
                }
                else {
                    Write-Host "$Program installed successfully."
                }
                Add-ReportAction $Program "Installazione di {0}" $true
            }
            else {
                Write-Host "Failed to install $Program."
                Add-ReportAction $Program "Installazione di {0}" $false
            }
        }
        catch {
            Write-Host "Failed to install $Program due to an error: $_"
            Add-ReportAction $Program "Installazione di {0}" $false
        }
        finally {
            Update-TaskbarProgress $currentIndex $totalPrograms
        }
    }

    function Uninstall-ChocoPackage {
        <#
        .SYNOPSIS
        Uninstalls a Chocolatey package and any related metapackages.

        .PARAMETER Program
        A string containing the name of the Chocolatey package to be uninstalled.

        .PARAMETER currentIndex
        The current index of the program in the list of programs to be managed.

        .PARAMETER totalPrograms
        The total number of programs to be uninstalled.

        .DESCRIPTION
        This function uninstalls a Chocolatey package and any related metapackages (e.g., .install or .portable variants). It updates the taskbar progress after processing each package.

        .EXAMPLE
        Uninstall-ChocoPackage -Program $Program -currentIndex 0 -totalPrograms 5
        #>

        param (
            [string]$Program,
            [int]$currentIndex,
            [int]$totalPrograms
        )

        $uninstallOutputFile = "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt"
        Initialize-OutputFile $uninstallOutputFile

        Write-Host "Searching for metapackages of $Program (.install or .portable)"
        $chocoPackages = ((choco list | Select-String -Pattern "$Program(\.install|\.portable)?").Matches.Value) -join " "
        if ($chocoPackages) {
            Write-Host "Starting uninstallation of $chocoPackages with Chocolatey..."
            try {
                $uninstallStatusCode = Invoke-ChocoCommand "uninstall $chocoPackages -y"
                $uninstalled = $uninstallStatusCode -in @(0, 1641, 3010)
                Write-Host "$Program" $(if ($uninstalled) { "uninstalled successfully." } else { "failed to uninstall." })
                Add-ReportAction $Program "Disinstallazione di {0}" $uninstalled
            }
            catch {
                Write-Host "Failed to uninstall $Program due to an error: $_"
                Add-ReportAction $Program "Disinstallazione di {0}" $false
            }
            finally {
                Update-TaskbarProgress $currentIndex $totalPrograms
            }
        }
        else {
            Write-Host "$Program is not installed."
        }
    }

    $totalPrograms = $Programs.Count
    if ($totalPrograms -le 0) {
        throw "Parameter 'Programs' must have at least one item."
    }

    Write-Host "==========================================="
    Write-Host "--   Configuring Chocolatey packages   ---"
    Write-Host "==========================================="

    for ($currentIndex = 0; $currentIndex -lt $totalPrograms; $currentIndex++) {
        $Program = $Programs[$currentIndex]
        $appName = ($sync.configs.applicationsHashtable.Values | Where-Object { $_.choco -eq $Program } | Select-Object -First 1).content
        if (-not $appName) { $appName = $Program }
        $operation = if ($Action -eq "Install") { "Installazione di {0}" } else { "Disinstallazione di {0}" }
        Set-WinUtilProgressBar -label ($operation -f $appName) -percent ($currentIndex / $totalPrograms * 100)
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($currentIndex / $totalPrograms)}

        switch ($Action) {
            "Install" {
                Install-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            "Uninstall" {
                Uninstall-ChocoPackage -Program $Program -currentIndex $currentIndex -totalPrograms $totalPrograms
            }
            default {
                throw "Invalid action parameter value: '$Action'."
            }
        }
    }
    Set-WinUtilProgressBar -label $(if ($Action -eq "Install") { "Installazione completata" } else { "Disinstallazione completata" }) -percent 100
    # Cleanup Output Files
    $outputFiles = @("$env:TEMP\Install-WinUtilProgramChoco.install-command.output.txt", "$env:TEMP\Install-WinUtilProgramChoco.uninstall-command.output.txt")
    foreach ($filePath in $outputFiles) {
        Remove-Item -Path $filePath -Force -ErrorAction SilentlyContinue
    }
}

Function Get-WinUtilPowerShellVersion {
    param ([string]$Path)
    & $Path -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
}

Function Get-WinUtilPowerShellArchitecture {
    param ([string]$Path)
    & $Path -NoLogo -NoProfile -Command '[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()'
}

Function Test-WinUtilPowerShellMSIUpgradeAllowed {
    # WinGet has no structured pin-list output, and list filters are not honored by all versions.
    # Conservatively leave upgrades to WinGet whenever any pins exist or the check fails.
    try {
        $pinOutput = @(& winget pin list --accept-source-agreements --disable-interactivity 2>&1)
        if ($LASTEXITCODE -ne 0 -or $pinOutput.Count -eq 0) { return $false }
        $text = $pinOutput -join "`n"
        $text = $text -replace '\x1B\[[0-9;]*[A-Za-z]', ''
        return $text -notmatch '(?m)^\s*-{3,}\s*$'
    } catch {
        return $false
    }
}

Function Update-WinUtilPowerShellMSI {
    <#
    .SYNOPSIS
        Upgrades PowerShell 7 installed with the official MSI package, which WinGet does not upgrade

    .OUTPUTS
        Outcome (NotInstalled, Skipped, Succeeded or Failed) and Detail
    #>
    $candidates = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.WindowsInstaller -eq 1 -and
            $_.DisplayName -match '^PowerShell\s+7(?:\.\d+)?(?:\.\d+)?(?:\.\d+)?(?:-(?:x64|x86|arm64))?(?:\s|$)' -and
            $_.DisplayName -notmatch "preview|daily"
        }
    $locations = @()
    foreach ($candidate in $candidates) {
        $location = $candidate.InstallLocation
        if (-not $location) {
            # The official MSI registers its location here, not in the uninstall record
            $registration = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions\*","HKLM:\SOFTWARE\WOW6432Node\Microsoft\PowerShellCore\InstalledVersions\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProductCode -and $_.ProductCode -eq $candidate.PSChildName } |
                Select-Object -First 1
            $location = $registration.InstallLocation
        }
        if ($location -and (Test-Path -LiteralPath (Join-Path $location "pwsh.exe"))) {
            $location = ([string]$location).TrimEnd([char[]]'\/')
            if ($locations -notcontains $location) { $locations += $location }
        }
    }

    if ($locations.Count -eq 0) {
        return [pscustomobject]@{ Outcome = "NotInstalled"; Detail = "PowerShell is not installed through MSI" }
    }

    if ($locations.Count -gt 1) {
        return [pscustomobject]@{ Outcome = "Failed"; Detail = "Multiple PowerShell MSI installations found; upgrade each one manually" }
    }

    if (-not (Test-WinUtilPowerShellMSIUpgradeAllowed)) {
        return [pscustomobject]@{ Outcome = "Skipped"; Detail = "WinGet pins exist or their state could not be verified; MSI upgrade skipped" }
    }

    $pwsh = Join-Path $locations[0] "pwsh.exe"
    try {
        # Windows PowerShell 5.1 can offer a protocol GitHub refuses
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        $installed = Get-WinUtilPowerShellVersion $pwsh
        $release = Invoke-RestMethod "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -TimeoutSec 30
        $latest = ([string]$release.tag_name).TrimStart("v")

        if ([version]$installed -ge [version]$latest) {
            return [pscustomobject]@{ Outcome = "Skipped"; Detail = "PowerShell $installed is already up to date" }
        }

        $arch = ([string](Get-WinUtilPowerShellArchitecture $pwsh)).Trim().ToLowerInvariant()
        if ($arch -notin @("x64", "x86", "arm64")) {
            throw "Unsupported installed PowerShell architecture: $arch"
        }
        $asset = $release.assets | Where-Object { $_.name -match "^PowerShell-.*-win-$arch\.msi$" } | Select-Object -First 1
        if (-not $asset) {
            throw "No PowerShell MSI found for $arch"
        }

        $msiPath = Join-Path $env:TEMP "PowerShell-$arch-$([guid]::NewGuid()).msi"
        try {
            Write-Host "Downloading PowerShell $latest ($arch)..."
            Invoke-WebRequest $asset.browser_download_url -OutFile $msiPath -UseBasicParsing -TimeoutSec 300

            if ($asset.digest) {
                $hash = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($hash -ne $asset.digest.Replace("sha256:", "").ToLowerInvariant()) {
                    throw "PowerShell MSI SHA256 verification failed"
                }
            }

            $signature = Get-AuthenticodeSignature -LiteralPath $msiPath
            if ($signature.Status -ne "Valid" -or -not $signature.SignerCertificate -or
                $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
                throw "PowerShell MSI signature verification failed"
            }

            $exitCode = Invoke-WinUtilProcess -FilePath "msiexec.exe" -ArgumentList "/i `"$msiPath`" /qn /norestart"
            if ($exitCode -notin @(0, 3010, 1641)) {
                throw "PowerShell MSI installation failed with exit code $exitCode"
            }
            return [pscustomobject]@{
                Outcome = "Succeeded"
                Detail  = $(if ($exitCode -eq 0) { "PowerShell upgraded to $latest" } else { "PowerShell upgraded to $latest, a restart is needed to finish" })
            }
        } finally {
            Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        return [pscustomobject]@{ Outcome = "Failed"; Detail = "PowerShell MSI upgrade failed: $($_.Exception.Message)" }
    }
}

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
    Runs the designated action on the provided programs using Winget

    .PARAMETER Programs
    A list of programs to process. An ID that starts with "msstore:" comes from the Microsoft Store source.

    .PARAMETER action
    The action to perform on the programs, can be either 'Install' or 'Uninstall'

    .NOTES
    The winget Return codes are documented here: https://learn.microsoft.com/windows/package-manager/winget/returnCodes
    #>

    param(
        [Parameter(Mandatory, Position=0)]$Programs,

        [Parameter(Mandatory, Position=1)]
        [ValidateSet("Install", "Uninstall")]
        [String]$Action
    )

    # WinGet reports "there was nothing to do" and "installed, restart to finish" through the exit code
    $alreadyDone = @{
        -1978335135 = "already installed"
        -1978335189 = "no applicable update"
    }
    $rebootNeeded = @(3010, 1641, -1978334967, -1978334965)
    # The package was installed for the current user only: elevated WinGet cannot change it
    $adminContextProhibited = -1978335107

    Function Invoke-Winget {
    <#
    .SYNOPSIS
    Invokes the winget.exe with the provided arguments and return the exit code

    .PARAMETER wingetId
    The Id of the Program that WinGet should Install/Uninstall

    .NOTES
    Invoke WinGet uses the public variable $Action defined outside the function to determine if a Program should be installed or removed
    #>
        param (
            [string]$wingetId
        )

        $source = "winget"
        if ($wingetId.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $wingetId = $wingetId.Substring("msstore:".Length)
        }

        $commonArguments = "--id $wingetId --silent"
        $arguments = if ($Action -eq "Install") {
            "install $commonArguments --accept-source-agreements --accept-package-agreements --source $source"
        } else {
            "uninstall $commonArguments --source $source"
        }

        # Only winget is waited for: an installer may leave the installed application open
        return Invoke-WinUtilProcess -FilePath "winget" -ArgumentList $arguments -NoNewWindow
    }

    Function Invoke-Install {
    <#
    .SYNOPSIS
    Contains the Install Logic and return code handling from winget

    .PARAMETER Program
    The WinGet ID of the Program that should be installed
    #>
        param (
            [string]$Program
        )

        if ($Program -eq "Microsoft.PowerShell") {
            # WinGet does not upgrade PowerShell installed with the official MSI package
            $msiResult = Update-WinUtilPowerShellMSI
            if ($msiResult.Outcome -ne "NotInstalled") {
                Write-Host $msiResult.Detail
                if ($msiResult.Outcome -ne "Failed") {
                    return $true
                }
            }
        }

        $status = Invoke-Winget -wingetId $Program
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully."
            return $true
        } elseif ($alreadyDone.ContainsKey($status)) {
            Write-Host "$($Program): $($alreadyDone[$status])."
            return $true
        } elseif ($status -in $rebootNeeded) {
            Write-Host "$($Program) installed, a restart is needed to finish."
            return $true
        } elseif ($status -eq $adminContextProhibited) {
            Write-Host "$($Program) is already installed for the current user; elevated WinGet cannot update it."
            return $true
        }

        Write-Host ("Failed to install {0} (WinGet 0x{1:X8})." -f $Program, $status)
        return $false
    }

    Function Invoke-Uninstall {
        <#
        .SYNOPSIS
        Contains the Uninstall Logic and return code handling from WinGet

        .PARAMETER Program
        The WinGet ID of the Program that should be uninstalled
        #>
        param (
            [string]$Program
        )

        try {
            $status = Invoke-Winget -wingetId $Program
            if ($status -eq 0 -or $status -in $rebootNeeded) {
                Write-Host "$($Program) uninstalled successfully."
                return $true
            } elseif ($status -eq $adminContextProhibited) {
                Write-Host "$($Program) is installed for the current user only; elevated WinGet cannot uninstall it."
                return $false
            } else {
                Write-Host ("Failed to uninstall {0} (WinGet 0x{1:X8})." -f $Program, $status)
                return $false
            }
        } catch {
            Write-Host "Failed to uninstall $($Program) due to an error: $_"
            return $false
        }
    }

    $count = $Programs.Count
    $failedPackages = @()

    Write-Host "==========================================="
    Write-Host "--    Configuring WinGet packages       ---"
    Write-Host "==========================================="

    for ($i = 0; $i -lt $count; $i++) {
        $Program = $Programs[$i]
        $result = $false
        # The app name shown in the Install tab, for the progress bar and the intervention report
        $appName = $null
        foreach ($app in $sync.configs.applicationsHashtable.Values) {
            if (($app.winget -split ";") -contains $Program) {
                $appName = $app.content
                break
            }
        }
        if (-not $appName) { $appName = $Program }
        $operation = if ($Action -eq "Install") { "Installazione di {0}" } else { "Disinstallazione di {0}" }
        Set-WinUtilProgressBar -label ($operation -f $appName) -percent ($i / $count * 100)
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -value ($i / $count)}

        $result = switch ($Action) {
            "Install" {Invoke-Install -Program $Program}
            "Uninstall" {Invoke-Uninstall -Program $Program}
            default {throw "[Install-WinUtilProgramWinget] Invalid action: $Action"}
        }

        if (-not $result) {
            $failedPackages += $Program
        }

        Add-WinUtilSessionAction -Area "Programmi" -Text ($operation -f $appName) -Status $(if ($result) { "Success" } else { "Error" })
    }

    Set-WinUtilProgressBar -label $(if ($Action -eq "Install") { "Installazione completata" } else { "Disinstallazione completata" }) -percent 100
    return $failedPackages
}
function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}
function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          # WinRUtil mark: a hexagonal nut (utility/tools symbol) in the brand neon-mint.
          # Outer hexagon ring (flat-top) with a hexagonal hole, drawn even-odd.
          $LogoNutData = @"
F0
M 89.84,27.00 L 50.00,4.00 L 10.16,27.00 L 10.16,73.00 L 50.00,96.00 L 89.84,73.00 Z
M 69.05,39.00 L 50.00,28.00 L 30.95,39.00 L 30.95,61.00 L 50.00,72.00 L 69.05,61.00 Z
"@
          $LogoNut = New-Object Windows.Shapes.Path
          $LogoNut.Data = [Windows.Media.Geometry]::Parse($LogoNutData)
          $LogoNut.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3DF5A0")

          # Inner accent dot at the center of the hole for a two-tone, distinctive look.
          $LogoDotData = "M 58.00,50.00 A 8,8 0 1,0 42.00,50.00 A 8,8 0 1,0 58.00,50.00 Z"
          $LogoDot = New-Object Windows.Shapes.Path
          $LogoDot.Data = [Windows.Media.Geometry]::Parse($LogoDotData)
          $LogoDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2BD389")

          $canvas.Children.Add($LogoNut) | Out-Null
          $canvas.Children.Add($LogoDot) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}
Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = ([string]$_.Value.choco -split ";")[-1].Trim()
            if ($packageId -and $packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $_.Key
            }
        }

        # Apps without a Chocolatey package are installed with WinGet (see Get-WinUtilSelectedPackages),
        # so they are looked for in the list of WinGet
        $wingetFallbackKeys = @($sync.configs.applicationsHashtable.GetEnumerator() | Where-Object {
            ([string]::IsNullOrWhiteSpace([string]$_.Value.choco) -or $_.Value.choco -eq "na") -and
            -not ([string]::IsNullOrWhiteSpace([string]$_.Value.winget) -or $_.Value.winget -eq "na")
        } | ForEach-Object { $_.Key })
        if ($wingetFallbackKeys.Count -gt 0 -and (Test-WinUtilPackageManager -winget) -eq "installed") {
            try {
                Invoke-WinUtilCurrentSystem -CheckBox "winget" | Where-Object { $_ -in $wingetFallbackKeys }
            } catch {
                Write-Warning "Could not check the apps installed with WinGet: $($_.Exception.Message)"
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
            $installedProgramOutput = @(winget list --accept-source-agreements --disable-interactivity 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
        $installedProgramText = $installedProgramOutput -join "`n"

        # WinGet pads each column to its widest value plus one space, so the row with the widest Name or Id
        # has only one space next to its Id. Take the Id column position from the header above the dashes,
        # which works whatever the language of the column titles.
        $idColumnStart = 0
        if ($installedProgramText -match '(?m)^(\S+[^\S\r\n]+)\S[^\r\n]*\r?\n-{3,}') {
            $idColumnStart = $Matches[1].Length
        }

        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = (([string]$_.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
            if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                return
            }

            $escapedPackageId = [regex]::Escape($packageId)
            $packagePattern = "(?im)[^\S\r\n]{2,}$escapedPackageId(?=[^\S\r\n]{2,}|$)"
            # Rows whose Name has combining marks or emoji are skipped: they have more characters than columns
            $idColumnPattern = "(?im)(?<=^[^\r\n\p{M}\p{Cs}\p{Cf}]{$($idColumnStart - 1)}[^\S\r\n])$escapedPackageId(?=[^\S\r\n]|$)"
            if ($installedProgramText -match $packagePattern -or ($idColumnStart -and $installedProgramText -match $idColumnPattern)) {
                Write-Output $_.Key
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $appxKeys = $entry.appx
            $invokeScript = $entry.InvokeScript
            $entryType = $entry.Type

            # A combo box has no applied state to detect: each entry is one of its choices
            if (($registryKeys -or $serviceKeys) -and $entryType -ne "Combobox") {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name -ErrorAction SilentlyContinue

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            } else {
                if ($invokeScript -or $appxKeys) {
                    Write-Debug "Skipping $Config in Get Installed: no detectable registry, scheduled task, or service state."
                }
            }
        }
    }
}
function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
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
                # Without Stop a missing feature (e.g. Windows Sandbox on Home) is only a warning
                # and the operation would be reported as done
                Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
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
    # The scripts configure the features, so they are skipped when a feature could not be enabled
    if($sync.configs.feature.$CheckBox.InvokeScript -and -not $failed) {
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
function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Remember the current scale factor so a theme change can re-apply it
    # (Invoke-WinutilThemeChange resets the shared size resources to their unscaled values)
    $sync.fontScaleFactor = $ScaleFactor

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "WindowButtonFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "AppEntryIconSize",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
                Write-Debug "Scaled $resourceName from original $originalValue to $newValue (factor: $ScaleFactor)"
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }

    Write-Debug "Font scaling applied with factor: $ScaleFactor"
}


function Invoke-WinUtilProcess {
    <#
    .SYNOPSIS
        Starts a program, waits for it to exit and returns its exit code

    .DESCRIPTION
        Start-Process -Wait also waits for every process the program started. An installer that
        opens the application when it has finished would then keep the operation running until
        the application is closed. Only the program itself is waited for here.

    .PARAMETER FilePath
        The program to run

    .PARAMETER ArgumentList
        The arguments of the program

    .PARAMETER NoNewWindow
        Runs a console program in the window of WinRUtil

    .PARAMETER OutputFile
        Writes the standard output of the program to this file instead of the window

    .PARAMETER TimeoutSeconds
        Stops the program and throws an error when it is still running after this many seconds.
        With 0 the program can run as long as it needs.

    .EXAMPLE
        $exitCode = Invoke-WinUtilProcess -FilePath "winget" -ArgumentList "upgrade --id Git.Git --silent" -NoNewWindow
    #>

    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$ArgumentList,

        [switch]$NoNewWindow,

        [string]$OutputFile,

        [int]$TimeoutSeconds = 0
    )

    $parameters = @{
        FilePath    = $FilePath
        PassThru    = $true
        NoNewWindow = $NoNewWindow
    }
    if ($ArgumentList) {
        $parameters.ArgumentList = $ArgumentList
    }
    if ($OutputFile) {
        $parameters.RedirectStandardOutput = $OutputFile
    }

    $process = Start-Process @parameters
    # ExitCode stays empty unless the handle is opened while the process is still running
    $null = $process.Handle

    if ($TimeoutSeconds -gt 0 -and -not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $minutes = [math]::Ceiling($TimeoutSeconds / 60)
        throw ("{0} non ha risposto entro {1} {2} ed {3} stato interrotto." -f [IO.Path]::GetFileNameWithoutExtension($FilePath), $minutes, $(if ($minutes -eq 1) { "minuto" } else { "minuti" }), [char]0x00E8)
    }
    $process.WaitForExit()
    return $process.ExitCode
}
function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }

}
function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time"
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}
function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    # Supports #RRGGBB, #AARRGGBB and named colors such as "Transparent"
                    "Color" { [Windows.Media.ColorConverter]::ConvertFromString($Value) }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($_ in $themeProperties) {
            # Apply properties that deal with colors
            if ($_.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "ColorBrush"
                # Also expose every color as a <Color> prefixed with "C" (e.g. BorderColor -> CBorderColor), because
                # GradientStop and DropShadowEffect require a <Color> and not a <SolidColorBrush> object
                Set-ThemeResourceProperty -Name "C$($_.Name)" -Value $_.Value -Type "Color"
            }
            # Apply corner radius properties
            elseif ($_.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($_.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($_.Name -like "*Thickness*") -or ($_.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($_.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $_.Name -Value $_.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-Preferences -save
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            # Follow the Windows app mode (Settings > Personalization > Colors), Light when the value is missing
            $personalizeKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
            $appsUseLightTheme = (Get-ItemProperty -Path $personalizeKey -Name "AppsUseLightTheme" -ErrorAction SilentlyContinue).AppsUseLightTheme
            if ($appsUseLightTheme -eq 0) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Set FOSS Highlight Color
    $fossEnabled = $true
    if ($sync.WPFToggleFOSSHighlight) {
        $fossEnabled = $sync.WPFToggleFOSSHighlight.IsChecked
    }

    if ($fossEnabled) {
         $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["FOSSHighlightColor"]
    } else {
         $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon

    # Re-apply the user's font scaling, since applying the "shared" theme above
    # resets every size resource to its unscaled default
    if ($sync.fontScaleFactor -and $sync.fontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.fontScaleFactor
    }
}
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
function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name, for all users

    .PARAMETER Name
        The name of the APPX package to remove

    .OUTPUTS
        True when no package that matches the name is left

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"

    # One package at a time instead of the pipeline: in PowerShell 7 Remove-AppxPackage fails silently
    # through the pipeline, and Get-AppxPackage -AllUsers returns the same package once per user profile
    $removed = $true
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    foreach ($pkg in @($pkgs)) {
        if ($null -eq $pkg) {
            continue
        }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
        } catch {
            Write-Warning "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            $removed = $false
        }
    }
    return $removed
}
function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes the provisioned AppX packages that match the given names, so that new user profiles do not get them

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."

    # The DISM cmdlets often fail with "Class not registered" or stop responding in PowerShell 7,
    # so they run in Windows PowerShell 5.1
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages | Where-Object DisplayName -Like "*$Package*"
            foreach ($prov in @($provs)) {
                if ($null -eq $prov) {
                    continue
                }
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                } catch {
                    $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        throw "Provisioned AppX package removal failed: $(($removalOutput | Out-String).Trim())"
    }
}
function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = @($sync.selectedApps) + @($sync.selectedTweaks) + @($sync.selectedFeatures) + @($sync.selectedAppx)
    # Imported keys can differ in case from the names of the checkboxes
    $selectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$CheckBoxesToCheck, [StringComparer]::OrdinalIgnoreCase)
    $CheckBoxes = ($sync.GetEnumerator()).where{ $_.Value -is [System.Windows.Controls.CheckBox] -and $_.Name -notlike "WPFToggle*" -and $_.Name -like "$checkboxfilterpattern"}
    Write-Debug "Getting checkboxes to set, number of checkboxes: $($CheckBoxes.Count)"

    if ($CheckBoxesToCheck -ne "") {
        $debugMsg = "CheckBoxes to Check are: "
        $CheckBoxesToCheck | ForEach-Object { $debugMsg += "$_, " }
        $debugMsg = $debugMsg -replace (',\s*$', '')
        Write-Debug "$debugMsg"
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if ($selectedSet.Count -eq 0) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($selectedSet.Contains($checkboxName)) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
            Write-Debug "$checkboxName is checked"
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
            Write-Debug "$checkboxName is not checked"
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "App selezionate: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
                Write-Debug "Restoring toggle: $($toggle.Key) = checked"
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}
function Set-Preferences{

    param(
        [switch]$save=$false
    )

    # TODO delete this function sometime later
    function Clean-OldPrefs{
        if (Test-Path -Path "$winutildir\LightTheme.ini") {
            $sync.preferences.theme = "Light"
            Remove-Item -Path "$winutildir\LightTheme.ini"
        }

        if (Test-Path -Path "$winutildir\DarkTheme.ini") {
            $sync.preferences.theme = "Dark"
            Remove-Item -Path "$winutildir\DarkTheme.ini"
        }

        # check old prefs, if its first line has no =, then absorb it as pm
        if (Test-Path -Path $iniPath) {
            $oldPM = Get-Content $iniPath
            if ($oldPM -notlike "*=*") {
                $sync.preferences.packagemanager = $oldPM
            }
        }

        if (Test-Path -Path "$winutildir\preferChocolatey.ini") {
            $sync.preferences.packagemanager = "Choco"
            Remove-Item -Path "$winutildir\preferChocolatey.ini"
        }
    }

    function Save-Preferences{
        $ini = ""
        foreach($key in $sync.preferences.Keys) {
            $pref = "$($key)=$($sync.preferences.$key)"
            Write-Debug "Saving pref: $($pref)"
            $ini = $ini + $pref + "`r`n"
        }
        $ini | Out-File $iniPath
    }

    function Load-Preferences{
        Clean-OldPrefs
        if (Test-Path -Path $iniPath) {
            $iniData = Get-Content "$winutildir\preferences.ini"
            foreach ($line in $iniData) {
                if ($line -like "*=*") {
                    $arr = $line -split "=",-2
                    $key = $arr[0] -replace "\s",""
                    $value = $arr[1] -replace "\s",""
                    Write-Debug "Preference: Key = '$($key)' Value ='$($value)'"
                    $sync.preferences.$key = $value
                }
            }
        }

        # write defaults in case preferences dont exist
        if ($null -eq $sync.preferences.theme) {
            $sync.preferences.theme = "Auto"
        }
        if ($null -eq $sync.preferences.packagemanager) {
            $sync.preferences.packagemanager = "Winget"
        }

        # convert packagemanager to enum
        if ($sync.preferences.packagemanager -eq "Choco") {
            $sync.preferences.packagemanager = [PackageManagers]::Choco
        }
        elseif ($sync.preferences.packagemanager -eq "Winget") {
            $sync.preferences.packagemanager = [PackageManagers]::Winget
        }
    }

    $iniPath = "$winutildir\preferences.ini"

    if ($save) {
        Save-Preferences
    }
    else {
        Load-Preferences
    }
}
function Set-WinUtilAppCategoryFilter {
    <#
    .SYNOPSIS
        Applies the category filter of the Install tab and updates its chips

    .DESCRIPTION
        The categories shown are in $sync.SelectedAppCategories: an empty list shows every category,
        which is what the "Tutte" chip stands for. The search text is applied again on top of the categories.

    .PARAMETER Category
        The category to act on. An empty value shows every category again.

    .PARAMETER Additive
        Adds the category to the ones shown, or removes it, instead of showing only that category (Ctrl+click)
    #>

    param(
        [string]$Category = "",
        [switch]$Additive
    )

    if ($null -eq $sync.SelectedAppCategories) {
        $sync.SelectedAppCategories = [System.Collections.Generic.List[string]]::new()
    }
    $selected = $sync.SelectedAppCategories

    if ([string]::IsNullOrWhiteSpace($Category)) {
        $selected.Clear()
    } elseif ($Additive) {
        if ($selected.Contains($Category)) {
            [void]$selected.Remove($Category)
        } else {
            $selected.Add($Category)
        }
    } elseif ($selected.Count -eq 1 -and $selected.Contains($Category)) {
        # A second click on the only category shown shows them all again
        $selected.Clear()
    } else {
        $selected.Clear()
        $selected.Add($Category)
    }

    Update-WinUtilAppCategoryChip
    Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Categories $selected.ToArray()
}
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .DESCRIPTION
        "Fastest" measures the neutral providers and uses the fastest one. When Windows supports it,
        the provider is also registered for DNS over HTTPS.

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .OUTPUTS
        True when the DNS was set (or left unchanged with "Default"), false when it was not

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if ($DNSProvider -eq "Default") {
        return $true
    }

    if ($DNSProvider -eq "Fastest") {
        Write-Host "Measuring the latency of the DNS providers..."
        $fastest = Get-WinUtilDNSBenchmark | Where-Object { $_.LatencyMs -lt 9999 } | Select-Object -First 1
        if (-not $fastest) {
            Write-Warning "Could not measure the latency of any DNS provider: the DNS settings are left as they are."
            Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "DNS - Imposta sul pi$([char]0x00F9) veloce" -Status "Error"
            return $false
        }
        $DNSProvider = $fastest.Provider
        Write-Host "Fastest DNS provider: $DNSProvider ($($fastest.LatencyMs) ms)"
    }

    $reportText = if ($DNSProvider -eq "DHCP") { "DNS - Imposta su automatico (DHCP)" } else { "DNS - Imposta su {0}" -f ($DNSProvider -replace "_", " ") }
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)

        if ($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if ($null -eq $dns) {
                throw "DNS provider $DNSProvider was not found in the configuration."
            }
        }

        $dohSupported = [bool](Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)
        $dnscacheBase = "HKLM:\System\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters"

        foreach ($Adapter in $Adapters) {
            $interfaceParams = "$dnscacheBase\$($Adapter.InterfaceGuid)"

            if ($DNSProvider -eq "DHCP") {
                # Set-DnsClientServerAddress alone can leave static servers on some adapters
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp | Out-Null
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp | Out-Null

                # The DNS over HTTPS settings of the provider used before
                $dohInterfaceSettings = "$interfaceParams\DohInterfaceSettings"
                if (Test-Path $dohInterfaceSettings) {
                    if ($dohSupported) {
                        $dohServerAddresses = @(
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh" -ErrorAction SilentlyContinue
                            Get-ChildItem -Path "$dohInterfaceSettings\Doh6" -ErrorAction SilentlyContinue
                        ) | Select-Object -ExpandProperty PSChildName -Unique

                        foreach ($ip in $dohServerAddresses) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Remove-DnsClientDohServerAddress -ServerAddress $ip -Confirm:$false -ErrorAction Stop
                            }
                        }
                    }
                    Remove-Item -Path $dohInterfaceSettings -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                $ipv4Addresses = @(@($dns.Primary, $dns.Secondary) | Where-Object { $_ })
                $ipv6Addresses = @(@($dns.Primary6, $dns.Secondary6) | Where-Object { $_ })

                if ($dohSupported -and $dns.DohTemplate) {
                    try {
                        foreach ($ip in @($ipv4Addresses + $ipv6Addresses)) {
                            if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
                                Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            } else {
                                Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $dns.DohTemplate -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop
                            }

                            # Turns DNS over HTTPS on for this adapter, as the Settings app does
                            $leaf = if ($ip.Contains(':')) { 'Doh6' } else { 'Doh' }
                            $regPath = "$interfaceParams\DohInterfaceSettings\$leaf\$ip"
                            if (-not (Test-Path $regPath)) {
                                New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                            }
                            New-ItemProperty -Path $regPath -Name "DohFlags" -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
                        }
                    } catch {
                        Write-Warning "DNS over HTTPS setup for provider $DNSProvider failed; continuing with plain DNS: $($psitem.Exception.Message)"
                    }
                }

                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv4Addresses -ErrorAction Stop
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses $ipv6Addresses -ErrorAction Stop
            }
        }
        if ($DNSProvider -ne "DHCP" -and $dohSupported -and $dns.DohTemplate) {
            Clear-DnsClientCache
        }
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text $reportText
        return $true
    } catch {
        Write-Warning "DNS provider $DNSProvider was not completed because an error occurred."
        Write-Warning $psitem.Exception.Message
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text $reportText -Status "Error"
        return $false
    }
}
function Set-WinUtilFontScaleStep {
    <#
    .SYNOPSIS
        Makes the text of WinRUtil bigger or smaller by one step of the text size slider

    .PARAMETER Step
        The change of the scale factor; 0 restores the normal size

    .EXAMPLE
        Set-WinUtilFontScaleStep -Step 0.25
    #>

    param([double]$Step)

    $slider = $sync.FontScalingSlider
    $value = if ($Step -eq 0) { 1.0 } else { $slider.Value + $Step }
    $value = [math]::Max($slider.Minimum, [math]::Min($slider.Maximum, $value))
    if ($value -eq $sync.fontScaleFactor -or ($null -eq $sync.fontScaleFactor -and $value -eq 1.0)) {
        return
    }

    $slider.Value = $value
    Invoke-WinUtilFontScaling -ScaleFactor $value
}
function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlaid onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    if($PARAM_NOUI) {
        return;
    }

    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.Text = $label}
    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.ToolTip = $label}
    if ($percent -lt 5 ) {
        $percent = 5 # Ensure the progress bar is not empty, as it looks weird
    }
    Invoke-WPFUIThread -ScriptBlock { $sync.ProgressBar.Value = $percent}

}
function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null}

        if ($Value -eq "<RemoveEntry>") {
            # A value that is not there is already in the requested state: undoing a tweak that was never
            # applied must not fail, and the key must not be created just to remove nothing from it.
            # Only a missing key or value counts as absent; access errors still reach the handlers below.
            $valueExists = $true
            try {
                Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop | Out-Null
            } catch [System.Management.Automation.PSArgumentException] {
                # The registry provider throws PSArgumentException when a named value is missing
                $valueExists = $false
            } catch [System.Management.Automation.ItemNotFoundException] {
                $valueExists = $false
            }

            if (-not $valueExists) {
                Write-Host "$Path\$Name is already absent"
                return
            }
        }

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
    }
}
function Set-WinUtilRegistryComboState {
    <#
    .SYNOPSIS
        Writes the registry values of a choice of a combo box, and checks them

    .DESCRIPTION
        When a value cannot be written, the values that were there before are restored.

    .PARAMETER Registry
        The registry entries of the combo box, with the value of each choice in Values

    .PARAMETER State
        The name of the choice to apply
    #>
    param(
        [Parameter(Mandatory)]
        $Registry,

        [Parameter(Mandatory)]
        [string]$State
    )

    if ($Registry[0].Values.PSObject.Properties.Name -notcontains $State) {
        throw "Scelta sconosciuta: '$State'."
    }

    # The values before the change, to restore them if the change fails halfway
    $previousValues = foreach ($setting in @($Registry)) {
        $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
        [pscustomobject]@{ Setting = $setting; Exists = $currentValue.Exists; Value = $currentValue.Value }
    }

    try {
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $previousValue = $previousValues | Where-Object Setting -EQ $setting
            if ($configuredValue -ne "<RemoveEntry>" -or $previousValue.Exists) {
                Set-WinUtilRegistry -Name $setting.Name -Path $setting.Path -Type $setting.Type -Value $configuredValue
            }
        }

        # Set-WinUtilRegistry reports write errors without throwing, so every value is read again
        foreach ($setting in @($Registry)) {
            $configuredValue = $setting.Values.PSObject.Properties[$State].Value
            $currentValue = Get-WinUtilRegistryComboValue -Setting $setting
            $writeMatches = if ($configuredValue -eq "<RemoveEntry>") {
                -not $currentValue.Exists
            } else {
                $currentValue.Exists -and [string]$currentValue.Value -eq [string]$configuredValue
            }
            if (-not $writeMatches) {
                throw "I valori del registro non corrispondono alla scelta richiesta."
            }
        }
    } catch {
        $applyError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($applyError)) {
            $applyError = "I valori del registro non corrispondono alla scelta richiesta."
        }
        $rollbackFailed = $false
        foreach ($previousValue in $previousValues) {
            try {
                $currentValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($previousValue.Exists -or $currentValue.Exists) {
                    $rollbackValue = if ($previousValue.Exists) { $previousValue.Value } else { "<RemoveEntry>" }
                    Set-WinUtilRegistry -Name $previousValue.Setting.Name -Path $previousValue.Setting.Path -Type $previousValue.Setting.Type -Value $rollbackValue
                }
                $restoredValue = Get-WinUtilRegistryComboValue -Setting $previousValue.Setting
                if ($restoredValue.Exists -ne $previousValue.Exists -or ($restoredValue.Exists -and [string]$restoredValue.Value -ne [string]$previousValue.Value)) {
                    $rollbackFailed = $true
                }
            } catch {
                $rollbackFailed = $true
            }
        }
        if ($rollbackFailed) {
            throw ("Impossibile applicare '{0}': {1} Non {2} stato possibile ripristinare i valori precedenti del registro." -f $State, $applyError, [char]0x00E8)
        }
        throw "Impossibile applicare '$State': $applyError"
    }
}
Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType)) {
            Write-Host "Service $Name is already set to $StartupType"
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            # sc.exe needs the space after "start="
            sc.exe config $Name start= delayed-auto
            if ($LASTEXITCODE -ne 0) {
                throw "sc.exe config failed with exit code $LASTEXITCODE"
            }
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
        }
    }

}
function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}
function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinRUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($sender, $args)
            Start-Process $sender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($sender, $args)
            $sender.Foreground = $LinkHoverForegroundColor
            $sender.FontSize = ($FontSize + ($FontSize / 4))
            $sender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($sender, $args)
            $sender.Foreground = $LinkForegroundColor
            $sender.FontSize = $FontSize
            $sender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}
function Show-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Displays a busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall is in progress.
        Dynamically updates the size of the overlay based on the app area on each invocation.
    .PARAMETER text
        The text to display in the busy overlay. Defaults to "Installing apps...".
    #>
    param (
        $text = "Installazione app in corso..."
    )
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Visible
        $sync.InstallAppAreaOverlay.Width = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlay.Height = $($sync.InstallAppAreaScrollViewer.ActualHeight * 0.4)
        $sync.InstallAppAreaOverlayText.Text = $text
        $sync.InstallAppAreaBorder.IsEnabled = $false
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 5
    }
}
function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}
function Update-WinUtilAppCategoryChip {
    <#
    .SYNOPSIS
        Checks the category chips of the Install tab that match the categories shown

    .DESCRIPTION
        A toggle button changes its state on every click; the state has to follow the categories
        shown instead. The "Tutte" chip is checked when no category is selected.
    #>

    $selected = $sync.SelectedAppCategories
    if ($null -eq $selected -or $null -eq $sync.AppCategoryChips) {
        return
    }

    foreach ($chip in $sync.AppCategoryChips) {
        $chip.IsChecked = if ($chip.Tag) { $selected.Contains([string]$chip.Tag) } else { $selected.Count -eq 0 }
    }
}
function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.

    .PARAMETER Replace
        Replaces the current selections instead of adding to them

    .OUTPUTS
        The keys that are not known to this version of WinRUtil, which are skipped
    #>

    param (
        $flatJson,

        [switch]$Replace
    )

    Write-Debug "JSON to import: $($flatJson)"

    $nextSelections = @{
        selectedApps     = [System.Collections.Generic.List[string]]::new()
        selectedTweaks   = [System.Collections.Generic.List[string]]::new()
        selectedToggles  = [System.Collections.Generic.List[string]]::new()
        selectedFeatures = [System.Collections.Generic.List[string]]::new()
        selectedAppx     = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($item in $flatJson) {
        # Ensure each item is treated as a string to handle PSCustomObject from JSON deserialization
        $cbkey = [string]$item
        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        # Exports of earlier versions can name entries that no longer exist
        $isKnown = switch ($listName) {
            'selectedApps' { $sync.configs.applicationsHashtable.ContainsKey($cbkey) }
            'selectedTweaks' { $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey] }
            'selectedToggles' { $null -ne $sync.configs.tweaks.PSObject.Properties[$cbkey] }
            'selectedFeatures' { $null -ne $sync.configs.feature.PSObject.Properties[$cbkey] }
            'selectedAppx' { $null -ne $sync.configs.appxHashtable -and $sync.configs.appxHashtable.ContainsKey($cbkey) }
            default { $false }
        }
        if (-not $isKnown) {
            Write-Host "Skipping unknown selection: $cbkey"
            $cbkey
            continue
        }

        if ($nextSelections[$listName] -notcontains $cbkey) {
            $nextSelections[$listName].Add($cbkey)
        }
    }

    foreach ($listName in $nextSelections.Keys) {
        if ($Replace) {
            $sync[$listName] = $nextSelections[$listName]
            continue
        }
        foreach ($cbkey in $nextSelections[$listName]) {
            # A preset and a configuration that both name an entry must not select it twice
            if ($sync.$listName -notcontains $cbkey) {
                $sync.$listName.Add($cbkey)
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "Selected AppX: $($sync.selectedAppx)"
    Write-Debug "--------------------------------------"
}
function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Installa o aggiorna $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Disinstalla $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Apri il sito web dell'applicazione nel browser predefinito`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
            Initialize-WinUtilAppCategoryChips -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}

function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Seconds 5
        while ($sync.ProcessRunning) {
                Start-Sleep -Seconds 5
            }
    }

    BusyWait

    # Only the steps with something selected run: the others would ask to select something first
    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedToggles.Count -gt 0) {
        Write-Host "Applying toggles..."
        $handle = Invoke-WPFRunspace -ScriptBlock {
            $Toggles = $sync.selectedToggles
            Write-Debug "Inside Number of toggles to process: $($Toggles.Count)"

            $sync.ProcessRunning = $true

            for ($i = 0; $i -lt $Toggles.Count; $i++) {
                Invoke-WinUtilTweaks $Toggles[$i]
            }

            $sync.ProcessRunning = $false
            Write-Host "================================="
            Write-Host "--     Toggles are Finished    ---"
            Write-Host "================================="
        }
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "Removing Windows apps..."
        Invoke-WPFAppxRemoval -Confirmed
        BusyWait
    }

    Write-Host "Done."
}
function Invoke-WPFAppxInstall {
    <#

    .SYNOPSIS
        Installs again the selected Windows apps, from the copy left on the PC or from the Microsoft Store

    #>

    if ($sync.ProcessRunning) {
        [System.Windows.MessageBox]::Show("Attendi la fine dell'operazione in corso.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $selected = @($sync.selectedAppx)
    if ($selected.Count -eq 0) {
        [System.Windows.MessageBox]::Show("Seleziona le app di Windows da reinstallare.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $appxScript = {
        param($Selected, $Apps)

        $installed = 0
        Write-Host "==========================================="
        Write-Host "--     Installing Windows apps         ---"
        Write-Host "==========================================="
        try {
            for ($i = 0; $i -lt $Selected.Count; $i++) {
                $app = $Apps[$Selected[$i]]
                Invoke-WPFUIThread -ScriptBlock {
                    $sync.WPFAppxStatus.Text = "Installazione {0} di {1}: {2}..." -f ($i + 1), $Selected.Count, $app.Content
                    Set-WinUtilTaskbaritem -state "Normal" -value ($i / $Selected.Count)
                }

                $ok = Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId
                if ($ok) {
                    $installed++
                }
                Add-WinUtilSessionAction -Area "App di Windows" -Text ("Installazione di {0}" -f $app.Content) -Status $(if ($ok) { "Success" } else { "Error" })
            }
            $status = "Installazione completata: {0} app su {1}." -f $installed, $Selected.Count
        } catch {
            $status = "Installazione interrotta: $($_.Exception.Message)"
        } finally {
            $sync.ProcessRunning = $false
            Invoke-WPFUIThread -ScriptBlock {
                $sync.WPFAppxStatus.Text = $status
                Set-WinUtilTaskbaritem -state "None" -overlay $(if ($installed -eq $Selected.Count) { "checkmark" } else { "warning" })
            }
        }
    }

    $sync.ProcessRunning = $true
    try {
        Invoke-WPFRunspace -ParameterList @(("Selected", $selected), ("Apps", $sync.configs.appxHashtable)) -ScriptBlock $appxScript | Out-Null
    } catch {
        $sync.ProcessRunning = $false
        $sync.WPFAppxStatus.Text = "Impossibile avviare l'installazione: $($_.Exception.Message)"
    }
}
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
function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","WinRUtil","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Expression $script
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFUpgradeStart" {Invoke-WPFUpgradeStart}
        "WPFUpgradeRefresh" {Invoke-WPFUpgradeRefresh}
        "WPFUpgradeClose" {Invoke-WPFUpgradeClose}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Do}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFPrinterRefresh" {Invoke-WPFPrinterRefresh}
        "WPFPrinterRestartSpooler" {Invoke-WPFPrinterSpooler -Action "Restart"}
        "WPFPrinterClearQueue" {Invoke-WPFPrinterSpooler -Action "ClearQueue"}
        "WPFPrinterInstallDriver" {Invoke-WPFPrinterDriver -Action "Install"}
        "WPFPrinterRemoveDriver" {Invoke-WPFPrinterDriver -Action "Remove"}
        "WPFWifiRefresh" {Invoke-WPFWifiRefresh}
        "WPFWifiCopyAll" {Invoke-WPFWifiCopyAll}
        "WPFWifiExport" {Invoke-WPFWifiExport}
        "WPFWifiImport" {Invoke-WPFWifiImport}
        "WPFWifiQrSave" {Invoke-WPFWifiQrSave}
        "WPFWifiQrClose" {Invoke-WPFWifiQrClose}
        "WPFOpenAppxTab" {Invoke-WPFTab "WPFTab9BT"}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFInstallSelectedAppx" {Invoke-WPFAppxInstall}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            foreach ($key in $sync.configs.appxHashtable.Keys) { $sync.$key.IsChecked = $true }
        }
        "WPFClearAppxSelection" {
            foreach ($key in $sync.configs.appxHashtable.Keys) { $sync.$key.IsChecked = $false }
        }
        "WPFGetInstalledAppx" {Invoke-WPFGetInstalledAppx}
        "WPFReportCreate" {Invoke-WPFReportCreate}
        "WPFReportClear" {Invoke-WPFReportClear}
        "WPFSystemInfoRefresh" {Invoke-WPFSystemInfoRefresh}
        "WPFSystemInfoExport" {Invoke-WPFSystemInfoExport}
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFMinimizeButton" {[Windows.SystemCommands]::MinimizeWindow($sync.Form)}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Maximized) {
                [Windows.SystemCommands]::RestoreWindow($sync.Form)
            } else {
                [Windows.SystemCommands]::MaximizeWindow($sync.Form)
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
        "WPFToggleFOSSHighlight" {
            if ($sync.WPFToggleFOSSHighlight.IsChecked) {
                 $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["FOSSHighlightColor"]
            } else {
                 $sync.Form.Resources["FOSSColor"] = $sync.Form.Resources["MainForegroundColor"]
            }
        }
    }
}
function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $handle = Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            $featureName = $sync.configs.feature.$_.Content
            if (-not $featureName) { $featureName = $_ }
            Set-WinUtilProgressBar -Label "Attivazione: $featureName" -Percent ($x / $Features.Count * 100)
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        Set-WinUtilProgressBar -Label "Attivazione completata" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}
function Invoke-WPFFixesNetwork {
    <#

    .SYNOPSIS
        Resets various network configurations

    #>

    Write-Host "Resetting Network with netsh"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo"
    # Reset WinSock catalog to a clean state
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.35 -overlay "logo"
    # Resets WinHTTP proxy setting to DIRECT
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"

    Set-WinUtilTaskbaritem -state "Normal" -value 0.7 -overlay "logo"
    # Removes all user configured IP settings
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    Write-Host "Process complete. Please reboot your computer."
    Add-WinUtilSessionAction -Area "Riparazione" -Text "Rete - Reimposta"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "WinRUtil - Rete"
    $Messageboxbody = ("Le impostazioni di rete sono state ripristinate.`nRiavvia il computer per completare l'operazione.")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "=========================================="
    Write-Host "-- Network Configuration has been Reset --"
    Write-Host "=========================================="
}
function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync
    Add-WinUtilSessionAction -Area "Configurazione" -Text "Server NTP - Usa pool.ntp.org"

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}
function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    Add-WinUtilSessionAction -Area "Riparazione" -Text $(if ($Aggressive) { "Windows Update - Reimposta (completo)" } else { "Windows Update - Reimposta" })

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "WinRUtil - Windows Update"
    $Messageboxbody = ("Le impostazioni di Windows Update sono state ripristinate.`nRiavvia il computer per completare l'operazione.")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}
function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
        Add-WinUtilSessionAction -Area "Riparazione" -Text "WinGet - Reinstalla"
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Add-WinUtilSessionAction -Area "Riparazione" -Text "WinGet - Reinstalla" -Status "Error"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}
function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("managerPreference", $managerPreference),("checkbox", $checkbox)) -ScriptBlock {
        param (
            [string]$checkbox,
            [PackageManagers]$managerPreference
        )
        $sync.ProcessRunning = $true
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            switch ($managerPreference) {
                "Choco"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco"; break}
                "Winget"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox; break}
            }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })

        Write-Host "Done..."
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" }
    }
}
function Invoke-WPFGetInstalledAppx {
    <#

    .SYNOPSIS
        Selects the Windows apps of the list that are installed on this PC

    #>

    if ($sync.ProcessRunning) {
        [System.Windows.MessageBox]::Show("Attendi la fine dell'operazione in corso.", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $sync.WPFAppxStatus.Text = "Ricerca delle app installate..."
    Invoke-WPFRunspace -ScriptBlock {
        # Reading the packages takes a few seconds, so it runs in the background
        $installed = @(Get-WinUtilInstalledAPPX)
        Invoke-WPFUIThread -ScriptBlock {
            $found = 0
            foreach ($key in $sync.configs.appxHashtable.Keys) {
                if ($installed -contains $sync.configs.appxHashtable[$key].PackageId) {
                    $sync.$key.IsChecked = $true
                    $found++
                }
            }
            $sync.WPFAppxStatus.Text = "App dell'elenco installate su questo PC: $found."
        }
    } | Out-Null
}
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
function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>

    $PackagesToInstall = $sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ }


    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Seleziona i programmi da installare o aggiornare."
        [System.Windows.MessageBox]::Show($WarningMsg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager

    $handle = Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        try {
            $sync.ProcessRunning = $true
            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Show-WPFInstallAppBusy -text "Installazione app in corso..."
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False
    }
}
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

    $searchScript = {
        param($Manager)
        $updates = @()
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }
        try {
            if ($Manager -eq "Choco" -and -not (Get-Command choco -ErrorAction SilentlyContinue)) {
                $status = "Chocolatey non {0} installato: non ci sono applicazioni da aggiornare con Chocolatey." -f [char]0x00E8
            } else {
                if ($Manager -eq "Winget" -and (Test-WinUtilPackageManager -winget) -ne "installed") {
                    # Right after an update of App Installer WinGet can be missing for a while: installing
                    # it takes some minutes, so say what is happening
                    Invoke-WPFUIThread -ScriptBlock {
                        $sync.WPFUpgradeStatus.Text = "WinGet non {0} disponibile: installazione di WinGet in corso..." -f [char]0x00E8
                    }
                    Install-WinUtilWinget
                    Invoke-WPFUIThread -ScriptBlock {
                        $sync.WPFUpgradeStatus.Text = "Ricerca degli aggiornamenti con WinGet in corso..."
                    }
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

    try {
        Invoke-WPFRunspace -ParameterList @(, @("Manager", $manager)) -ScriptBlock $searchScript | Out-Null
    } catch {
        # Without the background search the list would wait for ever
        $sync.UpgradeState = "Ready"
        $sync.ProcessRunning = $false
        $sync.WPFUpgradeStatus.Text = "Impossibile cercare gli aggiornamenti: $($_.Exception.Message)"
        Update-WinUtilUpgradeView
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

    $updateScript = {
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

    try {
        Invoke-WPFRunspace -ParameterList @(, @("Programs", $selected)) -ScriptBlock $updateScript | Out-Null
    } catch {
        foreach ($item in $selected) {
            $item.Status = ""
            $item.Level = ""
        }
        $sync.UpgradeState = "Ready"
        $sync.ProcessRunning = $false
        $sync.WPFUpgradeList.Items.Refresh()
        $sync.WPFUpgradeStatus.Text = "Impossibile avviare l'aggiornamento: $($_.Exception.Message)"
        Update-WinUtilUpgradeView
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
    # Only the package manager is waited for: an installer may leave the updated application open
    if ($Program.Manager -eq "Choco") {
        $exitCode = Invoke-WinUtilProcess -FilePath "choco" -ArgumentList "upgrade $($Program.Id) -y"
        $result = switch ($exitCode) {
            0 { @{ Success = $true; Text = "Aggiornata"; Level = "Success" } }
            { $_ -in 1641, 3010 } { @{ Success = $true; Text = "Aggiornata, riavvia il PC"; Level = "Warning" } }
            default { @{ Success = $false; Text = "Non riuscito (codice $exitCode)"; Level = "Danger" } }
        }
    } elseif ($Program.Id -eq "Microsoft.PowerShell" -and ($msiResult = Update-WinUtilPowerShellMSI).Outcome -ne "NotInstalled") {
        # WinGet does not upgrade PowerShell installed with the official MSI package
        Write-Host $msiResult.Detail
        $exitCode = $msiResult.Outcome
        $result = switch ($msiResult.Outcome) {
            "Succeeded" { @{ Success = $true; Text = "Aggiornata"; Level = "Success" } }
            "Skipped" { @{ Success = $false; Text = "Nessun aggiornamento applicabile"; Level = "Warning" } }
            default { @{ Success = $false; Text = "Non riuscito (pacchetto MSI di PowerShell)"; Level = "Danger" } }
        }
    } else {
        $arguments = "upgrade --id $($Program.Id) --exact --include-unknown --silent --accept-source-agreements --accept-package-agreements"
        if ($Program.Source) {
            $arguments += " --source $($Program.Source)"
        }
        $exitCode = Invoke-WinUtilProcess -FilePath "winget" -ArgumentList $arguments -NoNewWindow
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
function Invoke-WPFOOSU {
    <#
    .SYNOPSIS
        Downloads and runs OO Shutup 10
    #>
    try {
        $OOSU_filepath = "$ENV:temp\OOSU10.exe"
        $Initial_ProgressPreference = $ProgressPreference
        $ProgressPreference = "SilentlyContinue" # Disables the Progress Bar to drasticly speed up Invoke-WebRequest
        Invoke-WebRequest -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -OutFile $OOSU_filepath
        Write-Host "Starting OO Shutup 10 ..."
        Start-Process $OOSU_filepath
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "O&O ShutUp10++" -Status "Info"
    } catch {
        Write-Host "Error Downloading and Running OO Shutup 10" -ForegroundColor Red
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "O&O ShutUp10++" -Status "Error"
    }
    finally {
        $ProgressPreference = $Initial_ProgressPreference
    }
}
function Invoke-WPFPanelAutologin {
    <#

    .SYNOPSIS
        Enables autologin using Sysinternals Autologon.exe

    #>

    # Official Microsoft recommendation: https://learn.microsoft.com/en-us/sysinternals/downloads/autologon
    Invoke-WebRequest -Uri "https://live.sysinternals.com/Autologon.exe" -OutFile "$env:temp\autologin.exe"
    cmd /c "$env:temp\autologin.exe" /accepteula
    Add-WinUtilSessionAction -Area "Configurazione" -Text "Accesso automatico (Sysinternals Autologon)" -Status "Info"
}
function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}
function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFFeature*" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle*" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        $null = Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}
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
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Riavvio dello spooler di stampa"
            } catch {
                Write-WinUtilPrinterLog "Riavvio dello spooler non riuscito: $($_.Exception.Message)" -Level Error
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Riavvio dello spooler di stampa" -Status "Error"
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
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Svuotamento della coda di stampa"
            } catch {
                Write-WinUtilPrinterLog "Svuotamento della coda non riuscito: $($_.Exception.Message)" -Level Error
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Svuotamento della coda di stampa" -Status "Error"
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
            $reportText = "Installazione del driver di stampa {0}" -f [System.IO.Path]::GetFileName($inf)
            Write-WinUtilPrinterLog "Installazione del driver da: $inf"
            try {
                $output = & pnputil.exe /add-driver "$inf" /install 2>&1
                $output | ForEach-Object { Write-WinUtilPrinterLog $_ }
                if ($LASTEXITCODE -eq 0) {
                    Write-WinUtilPrinterLog "Driver installato correttamente." -Level Success
                    Add-WinUtilSessionAction -Area "Stampanti" -Text $reportText
                } else {
                    Write-WinUtilPrinterLog "pnputil ha restituito il codice $LASTEXITCODE." -Level Warning
                    Add-WinUtilSessionAction -Area "Stampanti" -Text $reportText -Status "Error"
                }
            } catch {
                Write-WinUtilPrinterLog "Installazione del driver non riuscita: $($_.Exception.Message)" -Level Error
                Add-WinUtilSessionAction -Area "Stampanti" -Text $reportText -Status "Error"
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
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Rimozione del driver di stampa $driverName"
            } catch {
                Write-WinUtilPrinterLog "Impossibile rimuovere il driver (potrebbe essere ancora in uso): $($_.Exception.Message)" -Level Error
                Add-WinUtilSessionAction -Area "Stampanti" -Text "Rimozione del driver di stampa $driverName" -Status "Error"
            }
            Invoke-WPFPrinterRefresh
        }
    }
}
function Write-WinUtilReportLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Report tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFReportLog
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

function Get-WinUtilReportSettings {
    <#
        .SYNOPSIS
            Returns the technician and the header saved with the last intervention report, or $null.
    #>
    $path = Join-Path $winutildir "rapporto.json"
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    try {
        [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        Write-Debug "Unable to read the report settings: $($_.Exception.Message)"
        $null
    }
}

function Save-WinUtilReportSettings {
    <#
        .SYNOPSIS
            Saves the technician and the header, so that the next intervention reports start with them.
    #>
    param(
        [string]$Technician,
        [string]$Header
    )

    try {
        $json = [pscustomobject]@{ Technician = $Technician; Header = $Header } | ConvertTo-Json
        [System.IO.File]::WriteAllText((Join-Path $winutildir "rapporto.json"), $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Debug "Unable to save the report settings: $($_.Exception.Message)"
    }
}

function Update-WinUtilReportView {
    <#
        .SYNOPSIS
            Lists the operations recorded in this session in the Report tab and, the first time,
            fills in the technician and the header saved with the last report.
    #>
    $actions = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() })
    $sync.WPFReportActions.ItemsSource = $actions
    $hasActions = $actions.Count -gt 0
    $sync.WPFReportActionsTable.Visibility = if ($hasActions) { "Visible" } else { "Collapsed" }
    $sync.WPFReportActionsEmpty.Visibility = if ($hasActions) { "Collapsed" } else { "Visible" }

    if (-not $sync.ReportSettingsLoaded) {
        $sync.ReportSettingsLoaded = $true
        $settings = Get-WinUtilReportSettings
        if ($settings) {
            $sync.WPFReportTechnician.Text = [string]$settings.Technician
            $sync.WPFReportHeader.Text = [string]$settings.Header
        }
    }
}

function Invoke-WPFReportClear {
    <#
        .SYNOPSIS
            Empties the list of the operations recorded in this session, after a confirmation.
    #>
    if (-not $sync.SessionActions -or $sync.SessionActions.Count -eq 0) {
        return
    }

    $answer = [System.Windows.MessageBox]::Show(
        "Vuoi svuotare l'elenco delle operazioni eseguite? Le operazioni tolte non compariranno nel rapporto.",
        "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    $sync.SessionActions.Clear()
    Update-WinUtilReportView
    Write-WinUtilReportLog "Elenco delle operazioni svuotato."
}

function ConvertTo-WinUtilInterventionReportHtml {
    <#
        .SYNOPSIS
            Formats the intervention report for the customer as a standalone, printable HTML page.
        .PARAMETER Details
            Customer, Technician, Reference, Header, Notes, Date and Actions (the operations recorded in this session).
        .PARAMETER Report
            The system report of the PC (see Get-WinUtilSystemReport).
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Details,
        [Parameter(Mandatory)][hashtable]$Report
    )

    $r = $Report
    $enc = { param($value) [System.Net.WebUtility]::HtmlEncode([string]$value) }
    $lines = { param($value) (@(([string]$value) -split "\r?\n") | ForEach-Object { & $enc $_.TrimEnd() }) -join "<br>" }
    $row = { param($label, $value) "<tr><td class=""k"">$label</td><td>$value</td></tr>" }
    $dash = "&ndash;"
    $orDash = { param($value) if ([string]::IsNullOrWhiteSpace($value)) { $dash } else { & $enc $value } }
    $date = $Details.Date

    $css = @'
:root{--fg:#111827;--muted:#5b6475;--border:#dde2e8;--accent:#047857;--danger:#b91c1c;--soft:#f6f8fa}
*{box-sizing:border-box}
body{margin:0;background:#eef1f5;color:var(--fg);font:13.5px/1.5 "Segoe UI",system-ui,sans-serif}
.toolbar{max-width:840px;margin:24px auto 0;padding:0 16px;display:flex;justify-content:flex-end}
.toolbar button{font:inherit;font-weight:600;color:#fff;background:var(--accent);border:0;border-radius:8px;padding:9px 18px;cursor:pointer}
.page{max-width:840px;margin:12px auto 32px;background:#fff;border:1px solid var(--border);border-radius:12px;padding:40px 44px}
header{display:flex;justify-content:space-between;align-items:flex-start;gap:24px;padding-bottom:18px;border-bottom:2px solid var(--fg)}
.company{color:var(--muted);font-size:12.5px;overflow-wrap:anywhere}
.company strong{display:block;color:var(--fg);font-size:17px;margin-bottom:2px}
.title{text-align:right;margin-left:auto}
.title:only-child{text-align:left;margin-left:0}
.title h1{margin:0;font-size:19px;letter-spacing:.04em;text-transform:uppercase}
.title p{margin:3px 0 0;color:var(--muted)}
.parties{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:20px 0 4px}
.parties span{display:block;font-size:10.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.parties b{display:block;font-size:14px;overflow-wrap:anywhere}
h2{margin:28px 0 8px;font-size:11.5px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--accent)}
table{width:100%;border-collapse:collapse}
.facts td{padding:6px 0;border-bottom:1px solid var(--border);vertical-align:top;overflow-wrap:anywhere}
.facts td.k{width:30%;color:var(--muted);padding-right:16px}
.ops th{text-align:left;font-size:10.5px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);padding:6px 14px 6px 0;border-bottom:1px solid var(--fg)}
.ops td{padding:7px 14px 7px 0;border-bottom:1px solid var(--border);vertical-align:top}
.ops td:last-child,.ops th:last-child{padding-right:0}
.nw{white-space:nowrap}
.muted{color:var(--muted)}
.ok{color:var(--accent);font-weight:600}
.err{color:var(--danger);font-weight:600}
.info{color:var(--muted);font-weight:600}
.notes{border:1px solid var(--border);border-radius:8px;padding:12px 14px;background:var(--soft);overflow-wrap:anywhere}
.empty{color:var(--muted);font-style:italic;margin:4px 0}
.signs{display:grid;grid-template-columns:1fr 1fr;gap:56px;margin-top:56px}
.signs div{border-top:1px solid var(--fg);padding-top:6px;font-size:12px;color:var(--muted)}
footer{margin-top:32px;font-size:11px;color:var(--muted);text-align:center}
@page{size:A4;margin:14mm}
@media print{body{background:#fff}.toolbar{display:none}.page{max-width:none;margin:0;border:0;border-radius:0;padding:0}tr,.signs,.notes{break-inside:avoid}h2{break-after:avoid}}
@media (max-width:640px) {.page{margin:0;border-radius:0;padding:24px 18px}header{flex-direction:column}.title{text-align:left;margin-left:0}.parties{grid-template-columns:1fr 1fr}}
'@

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="it">')
    $null = $sb.AppendLine('<head>')
    $null = $sb.AppendLine('<meta charset="utf-8">')
    $null = $sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $titleName = if ($Details.Customer) { $Details.Customer } else { $r.Hostname }
    $null = $sb.AppendLine("<title>Rapporto di intervento - $(& $enc $titleName)</title>")
    $null = $sb.AppendLine("<style>`r`n$css</style>")
    $null = $sb.AppendLine('</head>')
    $null = $sb.AppendLine('<body>')
    $null = $sb.AppendLine('<div class="toolbar"><button type="button" onclick="window.print()">Stampa o salva in PDF</button></div>')
    $null = $sb.AppendLine('<main class="page">')

    # Header: the technician's company on the left, title, date and reference on the right
    $null = $sb.AppendLine('<header>')
    if (-not [string]::IsNullOrWhiteSpace($Details.Header)) {
        $headerLines = @(([string]$Details.Header).Trim() -split "\r?\n")
        $company = "<strong>$(& $enc $headerLines[0].Trim())</strong>"
        if ($headerLines.Count -gt 1) {
            $company += & $lines (($headerLines | Select-Object -Skip 1) -join "`n")
        }
        $null = $sb.AppendLine("<div class=""company"">$company</div>")
    }
    $titleMeta = $date.ToString("d MMMM yyyy", [System.Globalization.CultureInfo]::GetCultureInfo("it-IT"))
    if ($Details.Reference) {
        $titleMeta += " &middot; Rif. $(& $enc $Details.Reference)"
    }
    $null = $sb.AppendLine("<div class=""title""><h1>Rapporto di intervento</h1><p>$titleMeta</p></div>")
    $null = $sb.AppendLine('</header>')

    $null = $sb.AppendLine('<section class="parties">')
    $null = $sb.AppendLine("<div><span>Cliente</span><b>$(& $orDash $Details.Customer)</b></div>")
    $null = $sb.AppendLine("<div><span>Tecnico</span><b>$(& $orDash $Details.Technician)</b></div>")
    $null = $sb.AppendLine("<div><span>Data</span><b>$($date.ToString('dd/MM/yyyy'))</b></div>")
    $null = $sb.AppendLine("<div><span>Computer</span><b>$(& $orDash $r.Hostname)</b></div>")
    $null = $sb.AppendLine('</section>')

    # PC details, as they are at the end of the intervention
    $null = $sb.AppendLine('<h2>Dati del computer</h2>')
    $null = $sb.AppendLine('<table class="facts">')
    $null = $sb.AppendLine((& $row 'Sistema operativo' ("{0}<br><span class=""muted"">{1}</span>" -f (& $enc $r.OSCaption), (& $enc $r.OSBuild))))
    $null = $sb.AppendLine((& $row 'Attivazione di Windows' (& $enc $r.ActivationText)))
    # Many models already start with the manufacturer name (e.g. "HP" and "HP ProDesk 400 G5")
    $model = if ($r.Model -and $r.Manufacturer -and $r.Model.StartsWith($r.Manufacturer, [System.StringComparison]::OrdinalIgnoreCase)) {
        $r.Model
    } else {
        @($r.Manufacturer, $r.Model | Where-Object { $_ -and $_ -ne 'Non disponibile' }) -join ' '
    }
    $null = $sb.AppendLine((& $row 'Produttore e modello' (& $orDash $model)))
    $null = $sb.AppendLine((& $row 'Numero di serie' (& $enc $r.Serial)))
    $null = $sb.AppendLine((& $row 'Processore' ("{0}<br><span class=""muted"">{1}</span>" -f (& $enc $r.CpuName), (& $enc $r.CpuCores))))
    $memory = if ($r.RamTotalGB) { "{0:N1} GB" -f $r.RamTotalGB } else { $r.RamText }
    if ($r.RamModules) { $memory = "{0} ({1})" -f $memory, $r.RamModules }
    $null = $sb.AppendLine((& $row 'Memoria RAM' (& $enc $memory)))
    # Labels are the drive letter, followed by the volume name when there is one
    $disks = @($r.Disks | ForEach-Object {
        $drive, $volume = ([string]$_.Label).Trim() -split '\s+', 2
        & $enc $(if ($volume) { "{0} {1}, {2}" -f $drive, $volume, $_.Text } else { "{0} {1}" -f $drive, $_.Text })
    })
    $disks += "<span class=""muted"">$(& $enc $r.DiskHealthText)</span>"
    $null = $sb.AppendLine((& $row 'Archiviazione' ($disks -join "<br>")))
    $null = $sb.AppendLine((& $row 'Scheda grafica' (& $enc $r.GpuName)))
    $security = @("Secure Boot: $($r.SecureBoot)", "TPM: $($r.Tpm)", "BitLocker ($env:SystemDrive): $($r.BitLocker)") | ForEach-Object { & $enc $_ }
    $null = $sb.AppendLine((& $row 'Sicurezza' ($security -join " &middot; ")))
    if ($r.HasBattery) {
        $null = $sb.AppendLine((& $row 'Batteria' (& $enc ("Carica {0}, {1}" -f $r.BatteryCharge, $r.BatteryHealth))))
    }
    $null = $sb.AppendLine((& $row 'Aggiornamenti di Windows' (& $enc "Ultima installazione: $($r.UpdatesLastInstall)")))
    $null = $sb.AppendLine('</table>')

    # Operations performed with WinRUtil
    $null = $sb.AppendLine('<h2>Operazioni eseguite</h2>')
    $actions = @($Details.Actions)
    if ($actions.Count -gt 0) {
        $status = @{ Success = 'ok'; Error = 'err'; Info = 'info' }
        $null = $sb.AppendLine('<table class="ops"><thead><tr><th>Ora</th><th>Categoria</th><th>Operazione</th><th>Esito</th></tr></thead><tbody>')
        foreach ($action in $actions) {
            $null = $sb.AppendLine(("<tr><td class=""nw muted"">{0}</td><td class=""nw"">{1}</td><td>{2}</td><td class=""nw {3}"">{4}</td></tr>" -f
                (& $enc $action.Time), (& $enc $action.Area), (& $enc $action.Text), $status[[string]$action.Status], (& $enc $action.Result)))
        }
        $null = $sb.AppendLine('</tbody></table>')
    } else {
        $null = $sb.AppendLine('<p class="empty">Nessuna operazione registrata con WinRUtil in questa sessione.</p>')
    }

    if (-not [string]::IsNullOrWhiteSpace($Details.Notes)) {
        $null = $sb.AppendLine('<h2>Note</h2>')
        $null = $sb.AppendLine("<div class=""notes"">$(& $lines ([string]$Details.Notes).Trim())</div>")
    }

    $null = $sb.AppendLine('<section class="signs"><div>Firma del tecnico</div><div>Firma del cliente</div></section>')
    $null = $sb.AppendLine("<footer>Rapporto creato con WinRUtil $(& $enc $sync.version) il $($date.ToString('dd/MM/yyyy')) alle $($date.ToString('HH:mm'))</footer>")
    $null = $sb.AppendLine('</main>')
    $null = $sb.AppendLine('</body>')
    $null = $sb.AppendLine('</html>')
    $sb.ToString()
}

function Invoke-WPFReportCreate {
    <#
        .SYNOPSIS
            Asks where to save the intervention report, then writes it as an HTML page and opens it
            in the default browser, ready to print or save as PDF. The PC details are read again,
            so that the report shows the PC as it is at the end of the intervention.
    #>
    if ($sync.ReportCreating) {
        return
    }

    $details = @{
        Customer   = $sync.WPFReportCustomer.Text.Trim()
        Technician = $sync.WPFReportTechnician.Text.Trim()
        Reference  = $sync.WPFReportReference.Text.Trim()
        Header     = $sync.WPFReportHeader.Text.Trim()
        Notes      = $sync.WPFReportNotes.Text.Trim()
        Actions    = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() })
        Date       = Get-Date
    }
    Save-WinUtilReportSettings -Technician $details.Technician -Header $details.Header

    $name = if ($details.Customer) { $details.Customer } else { $env:COMPUTERNAME }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Salva il rapporto di intervento"
    $dialog.Filter = "Pagina HTML (*.html)|*.html"
    $dialog.FileName = "Rapporto_{0}_{1}" -f (($name -replace '[\\/:*?"<>|]', '' -replace '\s+', '-').Trim('-.')), $details.Date.ToString('yyyyMMdd-HHmm')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilReportLog "Creazione del rapporto annullata." -Level Warning
        return
    }
    $details.Path = $dialog.FileName

    $sync.ReportDetails = $details
    $sync.ReportCreating = $true
    $sync.WPFReportCreate.IsEnabled = $false
    Write-WinUtilReportLog "Lettura dei dati del computer e creazione del rapporto..."

    Invoke-WPFRunspace -ScriptBlock {
        try {
            $details = $sync.ReportDetails
            $html = ConvertTo-WinUtilInterventionReportHtml -Details $details -Report (Get-WinUtilSystemReport)
            [System.IO.File]::WriteAllText($details.Path, $html, [System.Text.UTF8Encoding]::new($true))
            Write-WinUtilReportLog "Rapporto salvato: $($details.Path)" -Level Success
            Start-Process -FilePath $details.Path
        } catch {
            Write-WinUtilReportLog "Impossibile creare il rapporto: $($_.Exception.Message)" -Level Error
        } finally {
            $sync.ReportCreating = $false
            Invoke-WPFUIThread -ScriptBlock { $sync.WPFReportCreate.IsEnabled = $true }
        }
    }
}
function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    # Dispose the PowerShell instances of earlier calls that have finished. The runspace pool is
    # shared by the whole session and stays open until the window is closed.
    if ($null -eq $sync.RunspaceShells) {
        $sync.RunspaceShells = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    }
    foreach ($shell in $sync.RunspaceShells.ToArray()) {
        if ($shell.Handle.IsCompleted) {
            try {
                $null = $shell.PowerShell.EndInvoke($shell.Handle)
            } catch {
                Write-Debug "Background task ended with an error: $($_.Exception.Message)"
            }
            $shell.PowerShell.Dispose()
            $sync.RunspaceShells.Remove($shell)
        }
    }

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()
    [void]$sync.RunspaceShells.Add([pscustomobject]@{ PowerShell = $powershell; Handle = $handle })

    # Return the handle
    return $handle
}
function Invoke-WPFSelectedCheckboxesUpdate{
    <#
        .SYNOPSIS
            This is a helper function that is called by the Checked and Unchecked events of the Checkboxes.
            It also Updates the "Selected Apps" selectedAppLabel on the Install Tab to represent the current collection
        .PARAMETER type
            Either: Add | Remove
        .PARAMETER checkboxName
            should contain the name of the current instance of the checkbox that triggered the Event.
            Most of the time will be the automatic variable $this.Parent.Tag
        .EXAMPLE
            $checkbox.Add_Unchecked({Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag})
            OR
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $specificCheckbox.Parent.Tag
    #>
    param (
        $type,
        $checkboxName
    )

    if (($type -ne "Add") -and ($type -ne "Remove"))
    {
        Write-Error "Type: $type not implemented"
        return
    }

    $appKey = [string]$checkboxName
    $listName = switch -Regex ($appKey) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }
    if (-not $listName) {
        Write-Host "Unknown group for checkbox: $($appKey)"
        return
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if ($sync.$listName -notcontains $appKey) {
            $sync.$listName.Add($appKey)
            $selectionChanged = $true
        }
    } else {
        # Every copy is removed, also one imported with a different case
        for ($index = $sync.$listName.Count - 1; $index -ge 0; $index--) {
            if ($sync.$listName[$index] -eq $appKey) {
                $sync.$listName.RemoveAt($index)
                $selectionChanged = $true
            }
        }
    }

    if ($listName -eq "selectedApps" -and $selectionChanged) {
        $sync.WPFselectedAppsButton.Content = "App selezionate: $($sync.selectedApps.Count)"
        # The menu is rebuilt on every change, to keep it in alphabetical order
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
    }
}
function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer
        Add-WinUtilSessionAction -Area "Configurazione" -Text "Server OpenSSH - Attiva"

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}
function Write-WinUtilSystemLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the System tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFSystemLog
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

function Format-WinUtilUptime {
    <#
        .SYNOPSIS
            Formats the time elapsed since the given boot time, e.g. "2g 4h 11m".
    #>
    param([datetime]$BootTime)

    $up = (Get-Date) - $BootTime
    if ($up.Days -gt 0) { "{0}g {1}h {2}m" -f $up.Days, $up.Hours, $up.Minutes } else { "{0}h {1}m" -f $up.Hours, $up.Minutes }
}

function Set-WinUtilSystemMemory {
    <#
        .SYNOPSIS
            Fills the memory fields of a system report from the total and the free memory in GB.
    #>
    param($Report, [double]$TotalGB, [double]$FreeGB)

    $free = [math]::Round($FreeGB, 1)
    $used = [math]::Round($TotalGB - $free, 1)
    $Report.RamTotalGB = $TotalGB
    $Report.RamText = "{0:N1} / {1:N1} GB" -f $used, $TotalGB
    $Report.RamUsedPct = if ($TotalGB -gt 0) { [math]::Round(($used / $TotalGB) * 100) } else { 0 }
    $Report.RamFree = "{0:N1} GB" -f $free
}

function Get-WinUtilSystemReport {
    <#
        .SYNOPSIS
            Gathers OS, activation, hardware, BitLocker, CPU, RAM, storage (with SMART health),
            GPU, network, battery and Windows Update information via CIM/WMI and COM. Returns a
            hashtable of preformatted strings (plus numeric percentages for the progress bars).
            Every section is isolated so a single failing query never aborts the report.
    #>

    $r = @{}

    # Helpers (local) ----------------------------------------------------------
    $toGB = { param($bytes) try { [math]::Round([double]$bytes / 1GB, 1) } catch { 0 } }
    $nd   = "Non disponibile"
    $dot  = [char]0x00B7

    # OS / build ---------------------------------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $r.OSCaption = ($os.Caption -replace 'Microsoft ', '').Trim()
        $display = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
        $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
        $buildStr = "$($os.Version)"
        if ($ubr) { $buildStr = "$($os.Version).$ubr" }
        $verPart = if ($display) { "versione $display" } else { "" }
        $r.OSBuild = ("{0}  {3}  build {1}  {3}  {2}" -f $verPart, $buildStr, $os.OSArchitecture, $dot).TrimStart(" $dot").Trim()
        $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = try { (Get-Date $os.InstallDate -Format 'dd/MM/yyyy') } catch { $nd }
        $r.BootTime = $os.LastBootUpTime
        $r.Uptime = Format-WinUtilUptime $os.LastBootUpTime
    } catch {
        $r.OSCaption = "Windows"; $r.OSBuild = $nd; $r.Hostname = $env:COMPUTERNAME
        $r.InstallDate = $nd; $r.Uptime = $nd
    }

    # Activation ---------------------------------------------------------------
    try {
        $lic = Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
            -ErrorAction Stop | Select-Object -First 1
        switch ([int]$lic.LicenseStatus) {
            1       { $r.ActivationText = "Windows attivato";        $r.ActivationColorKey = "SuccessColor" }
            2       { $r.ActivationText = "Periodo di prova (OOB)";  $r.ActivationColorKey = "WarningColor" }
            3       { $r.ActivationText = "Periodo di prova (OOT)";  $r.ActivationColorKey = "WarningColor" }
            4       { $r.ActivationText = "Copia non genuina";       $r.ActivationColorKey = "DangerColor" }
            5       { $r.ActivationText = "Non attivato";            $r.ActivationColorKey = "DangerColor" }
            6       { $r.ActivationText = "Tolleranza estesa";       $r.ActivationColorKey = "WarningColor" }
            default { $r.ActivationText = "Non attivato";            $r.ActivationColorKey = "DangerColor" }
        }
    } catch {
        $r.ActivationText = "Stato sconosciuto"; $r.ActivationColorKey = "MutedForegroundColor"
    }

    # Hardware -----------------------------------------------------------------
    try {
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $r.Manufacturer = if ($cs.Manufacturer) { $cs.Manufacturer.Trim() } else { $nd }
        $r.Model = if ($cs.Model) { $cs.Model.Trim() } else { $nd }
        $r.Serial = if ($bios -and $bios.SerialNumber -and $bios.SerialNumber -notmatch '^(0+|To be filled.*|Default.*|System Serial.*)$') { $bios.SerialNumber.Trim() } else { $nd }
        $r.Bios = if ($bios) { ("{0}" -f $bios.SMBIOSBIOSVersion).Trim() } else { $nd }
    } catch {
        $r.Manufacturer = $nd; $r.Model = $nd; $r.Serial = $nd; $r.Bios = $nd
    }

    # Secure Boot
    $r.SecureBoot = try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { "Attivo" } else { "Disattivato" }
    } catch { $nd }

    # TPM
    $r.Tpm = try {
        $t = Get-Tpm -ErrorAction Stop
        if (-not $t.TpmPresent) { "Assente" }
        elseif ($t.TpmEnabled) { "Presente e attivo" }
        else                    { "Presente (disattivato)" }
    } catch {
        try {
            $tc = Get-CimInstance -Namespace 'root/cimv2/security/microsofttpm' -Class Win32_Tpm -ErrorAction Stop
            if ($tc.IsEnabled_InitialValue) { "Presente e attivo" } else { "Presente (disattivato)" }
        } catch { $nd }
    }

    # BitLocker on the system drive (requires administrator rights)
    $r.BitLocker = $nd
    try {
        $vol = Get-CimInstance -Namespace 'root/cimv2/security/microsoftvolumeencryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1
        if ($vol) {
            $protected = ([int]$vol.ProtectionStatus -eq 1)
            $conv = $null
            try { $conv = Invoke-CimMethod -InputObject $vol -MethodName GetConversionStatus -ErrorAction Stop } catch { }
            if ($conv -and $conv.ReturnValue -eq 0) {
                $pct = [int]$conv.EncryptionPercentage
                $r.BitLocker = switch ([int]$conv.ConversionStatus) {
                    0 { "Disattivato" }
                    1 { if ($protected) { "Attivo" } else { "Protezione sospesa" } }
                    2 { "Cifratura in corso ($pct%)" }
                    3 { "Decifratura in corso ($pct%)" }
                    4 { "Cifratura in pausa ($pct%)" }
                    5 { "Decifratura in pausa ($pct%)" }
                    default { if ($protected) { "Attivo" } else { "Disattivato" } }
                }
            } else {
                $r.BitLocker = if ($protected) { "Attivo" } else { "Disattivato" }
            }
        }
    } catch { }

    # CPU ----------------------------------------------------------------------
    try {
        $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        $cpu = $cpus[0]
        $r.CpuName = ($cpu.Name -replace '\s+', ' ').Trim()
        $cores = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $threads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
        $r.CpuCores = "$cores core / $threads thread"
        $r.CpuClock = "{0:N2} GHz" -f ([double]$cpu.MaxClockSpeed / 1000)
        $load = [math]::Round(($cpus | Measure-Object -Property LoadPercentage -Average).Average)
        $r.CpuLoadPct = [double]$load
        $r.CpuLoad = "$load%"
    } catch {
        $r.CpuName = $nd; $r.CpuCores = $nd; $r.CpuClock = $nd; $r.CpuLoadPct = 0; $r.CpuLoad = "-"
    }

    # RAM ----------------------------------------------------------------------
    try {
        if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
        if (-not $cs) { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
        Set-WinUtilSystemMemory -Report $r -TotalGB (& $toGB $cs.TotalPhysicalMemory) -FreeGB (([double]$os.FreePhysicalMemory * 1KB) / 1GB)
        $mods = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        if ($mods.Count -gt 0) {
            $speed = ($mods | Select-Object -First 1).Speed
            $r.RamModules = "{0} modulo/i @ {1} MHz" -f $mods.Count, $speed
        } else { $r.RamModules = $nd }
    } catch {
        $r.RamText = $nd; $r.RamUsedPct = 0; $r.RamFree = $nd; $r.RamModules = $nd
    }

    # Storage ------------------------------------------------------------------
    $disks = New-Object System.Collections.Generic.List[object]
    try {
        $vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
        foreach ($v in ($vols | Select-Object -First 4)) {
            if (-not $v.Size -or $v.Size -eq 0) { continue }
            $sizeGB = & $toGB $v.Size
            $freeGB = & $toGB $v.FreeSpace
            $usedPct = [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100)
            $label = $v.DeviceID
            if ($v.VolumeName) { $label = "{0}  {1}" -f $v.DeviceID, $v.VolumeName }
            $disks.Add(@{
                Label   = $label
                Text    = ("{0:N0} GB liberi su {1:N0} GB" -f $freeGB, $sizeGB)
                UsedPct = $usedPct
                Warn    = ($usedPct -ge 90)
            })
        }
    } catch { }
    $r.Disks = $disks

    # SMART / physical-disk health
    try {
        $health = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object -ExpandProperty HealthStatus -Unique)
        if ($health -contains 'Unhealthy') { $r.DiskHealthText = "Salute: Critico";    $r.DiskHealthColorKey = "DangerColor" }
        elseif ($health -contains 'Warning') { $r.DiskHealthText = "Salute: Attenzione"; $r.DiskHealthColorKey = "WarningColor" }
        elseif ($health -contains 'Healthy') { $r.DiskHealthText = "Salute: OK";         $r.DiskHealthColorKey = "SuccessColor" }
        else                                 { $r.DiskHealthText = "Salute: n/d";        $r.DiskHealthColorKey = "MutedForegroundColor" }
    } catch {
        $r.DiskHealthText = "Salute: n/d"; $r.DiskHealthColorKey = "MutedForegroundColor"
    }

    # GPU ----------------------------------------------------------------------
    $r.GpuName = $nd; $r.GpuVram = $nd; $r.GpuDriver = $nd; $r.GpuResolution = $nd
    try {
        $allGpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        # Prefer real adapters, but keep the basic/remote one if it is all we have
        $real = @($allGpus | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Mirror|Basic Display|DameWare|Meta Virtual' })
        $gpus = if ($real.Count -gt 0) { $real } else { $allGpus }

        $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { $_ })
        if ($names.Count -gt 0) { $r.GpuName = ($names -join "  $dot  ") }

        $g0 = $gpus | Select-Object -First 1
        if ($g0) {
            # VRAM: Win32_VideoController.AdapterRAM is a 32-bit value capped at ~4 GB,
            # so prefer the accurate qwMemorySize from the display-adapter registry key.
            $vramBytes = 0
            try {
                $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
                Get-ChildItem $base -ErrorAction Stop | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                    $q = (Get-ItemProperty -Path $_.PSPath -Name 'HardwareInformation.qwMemorySize' -ErrorAction SilentlyContinue).'HardwareInformation.qwMemorySize'
                    if ($q -and [double]$q -gt $vramBytes) { $vramBytes = [double]$q }
                }
            } catch { }
            try {
                if ($vramBytes -le 0 -and $g0.AdapterRAM) { $vramBytes = [double]$g0.AdapterRAM }
                if ($vramBytes -gt 0) {
                    $vramGB = [math]::Round($vramBytes / 1GB, 0)
                    if ($vramGB -ge 1) { $r.GpuVram = "{0:N0} GB" -f $vramGB }
                }
            } catch { }
            if ($g0.DriverVersion) { $r.GpuDriver = $g0.DriverVersion }
        }

        $active = $gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($active) { $r.GpuResolution = "{0} x {1}" -f $active.CurrentHorizontalResolution, $active.CurrentVerticalResolution }
    } catch { }

    # Network ------------------------------------------------------------------
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4Address -and $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' })
        # Prefer the adapter with a default gateway, so virtual switches and VPNs do not hide the real connection
        $cfg = @($configs | Where-Object { $_.IPv4DefaultGateway }) + $configs | Select-Object -First 1
        if ($cfg) {
            $r.NetAdapter = $cfg.InterfaceAlias
            $r.NetIp = ($cfg.IPv4Address | Select-Object -First 1).IPAddress
            $r.NetMac = if ($cfg.NetAdapter.MacAddress) { $cfg.NetAdapter.MacAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } else { throw "no up adapter" }
    } catch {
        try {
            $na = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop | Select-Object -First 1
            $r.NetAdapter = $na.Description
            $r.NetIp = ($na.IPAddress | Where-Object { $_ -match '\.' } | Select-Object -First 1)
            $r.NetMac = if ($na.MACAddress) { $na.MACAddress } else { $nd }
            $r.NetStatus = "Connesso"
        } catch {
            $r.NetAdapter = $nd; $r.NetIp = "n/d"; $r.NetMac = $nd; $r.NetStatus = "Non connesso"
        }
    }

    # Battery ------------------------------------------------------------------
    try {
        $batt = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($batt) {
            $r.HasBattery = $true
            $r.BatteryPct = [double]$batt.EstimatedChargeRemaining
            $r.BatteryCharge = "{0}%" -f [int]$batt.EstimatedChargeRemaining
            $r.BatteryStatus = switch ([int]$batt.BatteryStatus) {
                1 { "In uso (a batteria)" }
                2 { "Alimentazione di rete" }
                3 { "Carica completa" }
                4 { "Bassa" }
                5 { "Critica" }
                6 { "In carica" }
                7 { "In carica (alta)" }
                8 { "In carica (bassa)" }
                9 { "In carica (critica)" }
                default { "Sconosciuto" }
            }
            $r.BatteryHealth = $nd
            try {
                $static = Get-CimInstance -Namespace root/wmi -Class BatteryStaticData -ErrorAction Stop | Select-Object -First 1
                $full   = Get-CimInstance -Namespace root/wmi -Class BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1
                if ($static.DesignedCapacity -gt 0 -and $full.FullChargedCapacity -gt 0) {
                    $wear = [math]::Round((1 - ($full.FullChargedCapacity / $static.DesignedCapacity)) * 100, 1)
                    if ($wear -lt 0) { $wear = 0 }
                    $r.BatteryHealth = "{0:N0}% usura" -f $wear
                }
            } catch { }
        } else { $r.HasBattery = $false }
    } catch { $r.HasBattery = $false }

    # Windows Update -----------------------------------------------------------
    # The Windows Update Agent reports dates in UTC
    $toLocalDate = {
        param($value)
        $date = [datetime]$value
        if ($date.Year -lt 2000) { return $nd }
        [datetime]::SpecifyKind($date, [System.DateTimeKind]::Utc).ToLocalTime().ToString('dd/MM/yyyy HH:mm')
    }
    $r.UpdatesLastInstall = $nd; $r.UpdatesLastSearch = $nd; $r.UpdatesRecent = @()
    try {
        $results = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results
        if ($results.LastInstallationSuccessDate) { $r.UpdatesLastInstall = & $toLocalDate $results.LastInstallationSuccessDate }
        if ($results.LastSearchSuccessDate) { $r.UpdatesLastSearch = & $toLocalDate $results.LastSearchSuccessDate }
    } catch { }
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $total = $searcher.GetTotalHistoryCount()
        if ($total -gt 0) {
            $recent = New-Object System.Collections.Generic.List[object]
            foreach ($entry in $searcher.QueryHistory(0, [math]::Min($total, 300))) {
                # Completed installations and removals (Operation 1/2, ResultCode 2-5), newest first and
                # one row per update, without the daily Defender definition updates (KB2267602 / KB915597)
                # and the Microsoft Store app updates
                if ($entry.Operation -notin @(1, 2) -or $entry.ResultCode -notin @(2, 3, 4, 5) -or -not $entry.Title) { continue }
                if ($entry.Title -match '2267602|915597' -or $entry.Title -match '^9[0-9A-Z]{11}-') { continue }
                if ($recent | Where-Object { $_.Title -eq $entry.Title }) { continue }

                # Localized titles use either "(KB5031234)" or "- 4052623 KB"
                $kb = if ($entry.Title -match 'KB\s*(\d{6,8})' -or $entry.Title -match '(\d{6,8})\s*KB') { "KB$($Matches[1])" } else { "" }
                $result, $level = if ($entry.Operation -eq 2) {
                    if ($entry.ResultCode -in @(2, 3)) { "Rimosso", "Muted" } else { "Rimozione non riuscita", "Danger" }
                } else {
                    switch ($entry.ResultCode) {
                        2 { "Installato", "Success" }
                        3 { "Installato con errori", "Warning" }
                        4 { "Non riuscito", "Danger" }
                        default { "Annullato", "Warning" }
                    }
                }
                if ($entry.ResultCode -ne 2 -and $entry.HResult -ne 0) { $result = "{0} ({1})" -f $result, ('0x{0:X8}' -f $entry.HResult) }
                $recent.Add([pscustomobject]@{
                    Date = (& $toLocalDate $entry.Date); Title = $entry.Title; KB = $kb; Result = $result; Level = $level
                })
                if ($recent.Count -ge 15) { break }
            }
            $r.UpdatesRecent = $recent.ToArray()
        }
    } catch { }

    return $r
}

function Set-WinUtilSystemBar {
    <#
        .SYNOPSIS
            Fills one of the System dashboard progress bars (a two-column star grid).
            Colors are theme resource references, so they follow a later theme change.
    #>
    param($Grid, [double]$Percent, [bool]$Warn)

    if (-not $Grid) { return }
    $p = [math]::Max(0, [math]::Min(100, $Percent))
    $Grid.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new($p, [System.Windows.GridUnitType]::Star)
    $Grid.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new((100 - $p), [System.Windows.GridUnitType]::Star)
    $colorKey = if ($Warn) { "DangerColor" } else { "AccentColor" }
    $Grid.Children[0].SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $colorKey)
}

function Invoke-WPFSystemInfoRefresh {
    <#
        .SYNOPSIS
            Refreshes the System dashboard. Gathers the report on a background runspace
            and pushes every value to the WPF controls on the UI thread, so the window
            never freezes while data is collected.
    #>

    if ($sync.SystemInfoLoading) { return }
    $sync.SystemInfoLoading = $true
    Write-WinUtilSystemLog "Raccolta delle informazioni di sistema in corso..."

    Invoke-WPFRunspace -ScriptBlock {
        try {
            $report = Get-WinUtilSystemReport
            $sync.SystemReport = $report

            Invoke-WPFUIThread -ScriptBlock {
                $r = $sync.SystemReport

                # Hero
                $sync.WPFSysOSCaption.Text   = $r.OSCaption
                $sync.WPFSysOSBuild.Text      = $r.OSBuild
                $sync.WPFSysHostname.Text     = $r.Hostname
                $sync.WPFSysUptime.Text       = $r.Uptime
                $sync.WPFSysInstallDate.Text  = $r.InstallDate
                $sync.WPFSysActivation.Text   = $r.ActivationText
                $sync.WPFSysActivation.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $r.ActivationColorKey)
                $sync.WPFSysActivationDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $r.ActivationColorKey)

                # Hardware
                $sync.WPFSysManufacturer.Text = $r.Manufacturer
                $sync.WPFSysModel.Text        = $r.Model
                $sync.WPFSysSerial.Text       = $r.Serial
                $sync.WPFSysBios.Text         = $r.Bios
                $sync.WPFSysSecureBoot.Text   = $r.SecureBoot
                $sync.WPFSysTpm.Text          = $r.Tpm
                $sync.WPFSysBitLocker.Text    = $r.BitLocker

                # CPU
                $sync.WPFSysCpuName.Text  = $r.CpuName
                $sync.WPFSysCpuCores.Text = $r.CpuCores
                $sync.WPFSysCpuClock.Text = $r.CpuClock
                $sync.WPFSysCpuLoad.Text  = $r.CpuLoad
                Set-WinUtilSystemBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                # RAM
                $sync.WPFSysRamText.Text    = $r.RamText
                $sync.WPFSysRamFree.Text    = $r.RamFree
                $sync.WPFSysRamModules.Text = $r.RamModules
                Set-WinUtilSystemBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)

                # Storage
                $sync.WPFSysDiskHealth.Text       = $r.DiskHealthText
                $sync.WPFSysDiskHealth.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $r.DiskHealthColorKey)
                for ($i = 0; $i -lt 4; $i++) {
                    $panel = $sync["WPFSysDisk$i"]
                    if (-not $panel) { continue }
                    if ($i -lt $r.Disks.Count) {
                        $d = $r.Disks[$i]
                        $sync["WPFSysDisk${i}Label"].Text = $d.Label
                        $sync["WPFSysDisk${i}Text"].Text  = $d.Text
                        Set-WinUtilSystemBar $sync["WPFSysDisk${i}Bar"] $d.UsedPct $d.Warn
                        $panel.Visibility = "Visible"
                    } else {
                        $panel.Visibility = "Collapsed"
                    }
                }

                # GPU
                $sync.WPFSysGpuName.Text       = $r.GpuName
                $sync.WPFSysGpuVram.Text       = $r.GpuVram
                $sync.WPFSysGpuResolution.Text = $r.GpuResolution
                $sync.WPFSysGpuDriver.Text     = $r.GpuDriver

                # Network
                $sync.WPFSysNetAdapter.Text = $r.NetAdapter
                $sync.WPFSysNetIp.Text      = $r.NetIp
                $sync.WPFSysNetMac.Text     = $r.NetMac
                $sync.WPFSysNetStatus.Text  = $r.NetStatus

                # Windows Update
                $sync.WPFSysUpdLastInstall.Text = $r.UpdatesLastInstall
                $sync.WPFSysUpdLastSearch.Text  = $r.UpdatesLastSearch
                $sync.WPFSysUpdList.ItemsSource = @($r.UpdatesRecent)
                $hasUpdates = @($r.UpdatesRecent).Count -gt 0
                $sync.WPFSysUpdTable.Visibility = if ($hasUpdates) { "Visible" } else { "Collapsed" }
                $sync.WPFSysUpdEmpty.Visibility = if ($hasUpdates) { "Collapsed" } else { "Visible" }

                # Battery
                if ($r.HasBattery) {
                    $sync.WPFSysBatteryCard.Visibility = "Visible"
                    $sync.WPFSysBatteryCharge.Text = $r.BatteryCharge
                    $sync.WPFSysBatteryStatus.Text = $r.BatteryStatus
                    $sync.WPFSysBatteryHealth.Text = $r.BatteryHealth
                    Set-WinUtilSystemBar $sync.WPFSysBatteryBar $r.BatteryPct ($r.BatteryPct -le 15)
                } else {
                    $sync.WPFSysBatteryCard.Visibility = "Collapsed"
                }
            }

            Write-WinUtilSystemLog "Informazioni di sistema aggiornate." -Level Success
        } catch {
            Write-WinUtilSystemLog "Errore durante la lettura del sistema: $($_.Exception.Message)" -Level Error
        } finally {
            $sync.SystemInfoLoading = $false
        }
    }
}

function Start-WinUtilSystemLiveUpdate {
    <#
        .SYNOPSIS
            Refreshes CPU load, memory usage and uptime of the System dashboard every two seconds
            while the dashboard is open. The values are read on the runspace pool, so the UI never waits.
    #>

    if (-not $sync.SystemLiveTimer) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromSeconds(2)
        $timer.Add_Tick({ Update-WinUtilSystemLiveData })
        $sync.SystemLiveTimer = $timer
    }
    $sync.SystemLiveTimer.Start()
}

function Stop-WinUtilSystemLiveUpdate {
    <#
        .SYNOPSIS
            Stops the live refresh of the System dashboard.
    #>

    if ($sync.SystemLiveTimer) { $sync.SystemLiveTimer.Stop() }
}

function Update-WinUtilSystemLiveData {
    <#
        .SYNOPSIS
            Timer tick of the live System dashboard (UI thread): shows the result of the previous
            query and starts the next one. Reading the CPU load takes about one second.
    #>

    $job = $sync.SystemLiveJob
    if ($job) {
        if (-not $job.Handle.IsCompleted) { return }
        try {
            $data = @($job.PowerShell.EndInvoke($job.Handle)) | Select-Object -Last 1
            $r = $sync.SystemReport
            if ($data -and $r) {
                $r.CpuLoadPct = [double]$data.CpuLoadPct
                $r.CpuLoad = "$($data.CpuLoadPct)%"
                $sync.WPFSysCpuLoad.Text = $r.CpuLoad
                Set-WinUtilSystemBar $sync.WPFSysCpuLoadBar $r.CpuLoadPct ($r.CpuLoadPct -ge 90)

                if ($r.RamTotalGB -gt 0) {
                    Set-WinUtilSystemMemory -Report $r -TotalGB $r.RamTotalGB -FreeGB $data.FreeGB
                    $sync.WPFSysRamText.Text = $r.RamText
                    $sync.WPFSysRamFree.Text = $r.RamFree
                    Set-WinUtilSystemBar $sync.WPFSysRamBar $r.RamUsedPct ($r.RamUsedPct -ge 90)
                }

                if ($r.BootTime) {
                    $r.Uptime = Format-WinUtilUptime $r.BootTime
                    $sync.WPFSysUptime.Text = $r.Uptime
                }
            }
        } catch {
            Write-Debug "Live system update failed: $($_.Exception.Message)"
        } finally {
            $job.PowerShell.Dispose()
            $sync.SystemLiveJob = $null
        }
    }

    if (-not $sync.runspace -or $sync.Form.WindowState -eq [System.Windows.WindowState]::Minimized) { return }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $sync.runspace
    [void]$ps.AddScript({
        $load = (Get-CimInstance -ClassName Win32_Processor -Property LoadPercentage | Measure-Object -Property LoadPercentage -Average).Average
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory
        [pscustomobject]@{
            CpuLoadPct = [math]::Round([double]$load)
            FreeGB     = ([double]$os.FreePhysicalMemory * 1KB) / 1GB
        }
    }.ToString())
    $sync.SystemLiveJob = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function ConvertTo-WinUtilSystemReportText {
    <#
        .SYNOPSIS
            Formats a system report (see Get-WinUtilSystemReport) as plain text.
    #>
    param([Parameter(Mandatory)][hashtable]$Report)

    $r = $Report
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("WinRUtil - Report di sistema")
    $null = $sb.AppendLine("Generato il $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
    $null = $sb.AppendLine(("=" * 56))
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ WINDOWS ]")
    $null = $sb.AppendLine("  Edizione        : $($r.OSCaption)")
    $null = $sb.AppendLine("  Build           : $($r.OSBuild)")
    $null = $sb.AppendLine("  Attivazione     : $($r.ActivationText)")
    $null = $sb.AppendLine("  Nome PC         : $($r.Hostname)")
    $null = $sb.AppendLine("  Installato il   : $($r.InstallDate)")
    $null = $sb.AppendLine("  Acceso da       : $($r.Uptime)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ HARDWARE ]")
    $null = $sb.AppendLine("  Produttore      : $($r.Manufacturer)")
    $null = $sb.AppendLine("  Modello         : $($r.Model)")
    $null = $sb.AppendLine("  N. di serie     : $($r.Serial)")
    $null = $sb.AppendLine("  BIOS / UEFI     : $($r.Bios)")
    $null = $sb.AppendLine("  Secure Boot     : $($r.SecureBoot)")
    $null = $sb.AppendLine("  TPM             : $($r.Tpm)")
    $null = $sb.AppendLine("  BitLocker ($env:SystemDrive)  : $($r.BitLocker)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ PROCESSORE ]")
    $null = $sb.AppendLine("  Modello         : $($r.CpuName)")
    $null = $sb.AppendLine("  Core / Thread   : $($r.CpuCores)")
    $null = $sb.AppendLine("  Frequenza base  : $($r.CpuClock)")
    $null = $sb.AppendLine("  Carico attuale  : $($r.CpuLoad)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ MEMORIA ]")
    $null = $sb.AppendLine("  Utilizzo        : $($r.RamText)")
    $null = $sb.AppendLine("  Disponibile     : $($r.RamFree)")
    $null = $sb.AppendLine("  Moduli          : $($r.RamModules)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine(("[ ARCHIVIAZIONE ]  {0}" -f $r.DiskHealthText))
    foreach ($d in $r.Disks) {
        $null = $sb.AppendLine("  $($d.Label)  -  $($d.Text)  ($($d.UsedPct)% usato)")
    }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ GRAFICA ]")
    $null = $sb.AppendLine("  Scheda          : $($r.GpuName)")
    $null = $sb.AppendLine("  Memoria video   : $($r.GpuVram)")
    $null = $sb.AppendLine("  Risoluzione     : $($r.GpuResolution)")
    $null = $sb.AppendLine("  Driver          : $($r.GpuDriver)")
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ RETE ]")
    $null = $sb.AppendLine("  Scheda          : $($r.NetAdapter)")
    $null = $sb.AppendLine("  Indirizzo IPv4  : $($r.NetIp)")
    $null = $sb.AppendLine("  Indirizzo MAC   : $($r.NetMac)")
    $null = $sb.AppendLine("  Stato           : $($r.NetStatus)")
    if ($r.HasBattery) {
        $null = $sb.AppendLine("")
        $null = $sb.AppendLine("[ BATTERIA ]")
        $null = $sb.AppendLine("  Carica          : $($r.BatteryCharge)")
        $null = $sb.AppendLine("  Stato           : $($r.BatteryStatus)")
        $null = $sb.AppendLine("  Salute          : $($r.BatteryHealth)")
    }
    $null = $sb.AppendLine("")
    $null = $sb.AppendLine("[ AGGIORNAMENTI WINDOWS ]")
    $null = $sb.AppendLine("  Ultima installazione : $($r.UpdatesLastInstall)")
    $null = $sb.AppendLine("  Ultima ricerca       : $($r.UpdatesLastSearch)")
    if (@($r.UpdatesRecent).Count -gt 0) {
        $null = $sb.AppendLine("  Cronologia recente:")
        foreach ($u in $r.UpdatesRecent) {
            $null = $sb.AppendLine(("    {0}  {1,-26} {2}" -f $u.Date, $u.Result, $u.Title))
        }
    }
    $sb.ToString()
}

function ConvertTo-WinUtilSystemReportHtml {
    <#
        .SYNOPSIS
            Formats a system report (see Get-WinUtilSystemReport) as a standalone, printable HTML page.
    #>
    param([Parameter(Mandatory)][hashtable]$Report)

    $r = $Report
    $enc = { param($value) [System.Net.WebUtility]::HtmlEncode([string]$value) }
    $row = { param($label, $value, $class) "<tr><td class=""k"">$label</td><td class=""v $class"">$(& $enc $value)</td></tr>" }
    $bar = {
        param($pct, $warn)
        $width = [math]::Max(0, [math]::Min(100, [double]$pct)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $class = if ($warn) { ' class="danger"' } else { '' }
        "<div class=""bar""><i$class style=""width:$width%""></i></div>"
    }
    $card = { param($title, $body) "<section class=""card""><h3>$title</h3>$body</section>" }
    $state = @{ SuccessColor = 'ok'; WarningColor = 'warn'; DangerColor = 'danger' }

    $css = @'
:root{--bg:#f1f4f8;--card:#fff;--border:#d6dce4;--fg:#0f172a;--muted:#556275;--accent:#047857;--warn:#b45309;--danger:#dc2626;--track:#e2e8f0}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
main{max-width:1000px;margin:0 auto;padding:32px 16px}
header{margin-bottom:20px}
.brand{margin:0;color:var(--accent);font-weight:700}
h1{margin:2px 0 0;font-size:26px;line-height:1.2}
.meta{margin:4px 0 0;color:var(--muted)}
.hero{display:flex;flex-wrap:wrap;gap:16px;justify-content:space-between;align-items:flex-start;background:#ecfdf5;border:1px solid #a7f3d0;border-radius:16px;padding:20px 22px;margin-bottom:16px}
.hero h2{margin:0;font-size:22px}
.facts{display:flex;flex-wrap:wrap;gap:28px;margin-top:12px}
.facts span{display:block;font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted)}
.facts b{font-size:14px}
.pill{border-radius:999px;padding:6px 14px;font-weight:600;background:#fff;border:1px solid var(--border)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:16px}
.card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:16px 18px}
h3{margin:0 0 10px;font-size:12px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
table{width:100%;border-collapse:collapse}
td{padding:3px 0;vertical-align:top}
td.k{color:var(--muted);padding-right:12px;white-space:nowrap}
td.v{text-align:right;overflow-wrap:anywhere}
.big{font-size:20px;font-weight:700;margin:0}
.bar{height:6px;border-radius:3px;background:var(--track);overflow:hidden;margin:4px 0 10px}
.bar i{display:block;height:100%;background:var(--accent)}
.bar i.danger{background:var(--danger)}
.disk{display:flex;justify-content:space-between;gap:12px;font-weight:600}
.disk span{font-weight:400;color:var(--muted);font-size:12px}
.ok{color:var(--accent)}
.warn{color:var(--warn)}
.danger{color:var(--danger)}
.muted{color:var(--muted)}
.nw{white-space:nowrap}
.wide{margin-top:16px}
.wide .facts{margin-top:0}
table.list{margin-top:14px}
table.list th{text-align:left;font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--muted);padding:4px 14px 6px 0}
table.list td{padding:6px 14px 6px 0;border-top:1px solid var(--border)}
footer{margin-top:24px;color:var(--muted);font-size:12px}
@media print{body{background:#fff}main{padding:0}.hero,.card{break-inside:avoid}.card.wide{break-inside:auto}tr{break-inside:avoid}}
'@

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('<!DOCTYPE html>')
    $null = $sb.AppendLine('<html lang="it">')
    $null = $sb.AppendLine('<head>')
    $null = $sb.AppendLine('<meta charset="utf-8">')
    $null = $sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    $null = $sb.AppendLine("<title>Report di sistema - $(& $enc $r.Hostname)</title>")
    $null = $sb.AppendLine("<style>`r`n$css</style>")
    $null = $sb.AppendLine('</head>')
    $null = $sb.AppendLine('<body>')
    $null = $sb.AppendLine('<main>')
    $null = $sb.AppendLine('<header><p class="brand">WinRUtil</p><h1>Report di sistema</h1>')
    $null = $sb.AppendLine("<p class=""meta"">$(& $enc $r.Hostname) &middot; generato il $(Get-Date -Format 'dd/MM/yyyy HH:mm')</p></header>")

    $null = $sb.AppendLine('<section class="hero"><div>')
    $null = $sb.AppendLine("<h2>$(& $enc $r.OSCaption)</h2><p class=""meta"">$(& $enc $r.OSBuild)</p>")
    $null = $sb.AppendLine("<div class=""facts""><div><span>Nome PC</span><b>$(& $enc $r.Hostname)</b></div><div><span>Acceso da</span><b>$(& $enc $r.Uptime)</b></div><div><span>Installato il</span><b>$(& $enc $r.InstallDate)</b></div></div>")
    $null = $sb.AppendLine("</div><span class=""pill $($state[[string]$r.ActivationColorKey])"">$(& $enc $r.ActivationText)</span></section>")

    $null = $sb.AppendLine('<div class="grid">')

    $body = '<table>' +
        (& $row 'Produttore' $r.Manufacturer) +
        (& $row 'Modello' $r.Model) +
        (& $row 'N. di serie' $r.Serial) +
        (& $row 'BIOS / UEFI' $r.Bios) +
        (& $row 'Secure Boot' $r.SecureBoot) +
        (& $row 'TPM' $r.Tpm) +
        (& $row "BitLocker ($env:SystemDrive)" $r.BitLocker) + '</table>'
    $null = $sb.AppendLine((& $card 'Hardware' $body))

    $body = "<p><b>$(& $enc $r.CpuName)</b></p><table>" +
        (& $row 'Core / Thread' $r.CpuCores) +
        (& $row 'Frequenza base' $r.CpuClock) +
        (& $row 'Carico' $r.CpuLoad) + '</table>' + (& $bar $r.CpuLoadPct ($r.CpuLoadPct -ge 90))
    $null = $sb.AppendLine((& $card 'Processore' $body))

    $body = "<p class=""big"">$(& $enc $r.RamText)</p>" + (& $bar $r.RamUsedPct ($r.RamUsedPct -ge 90)) + '<table>' +
        (& $row 'Disponibile' $r.RamFree) +
        (& $row 'Moduli' $r.RamModules) + '</table>'
    $null = $sb.AppendLine((& $card 'Memoria' $body))

    $body = "<p class=""$($state[[string]$r.DiskHealthColorKey])"">$(& $enc $r.DiskHealthText)</p>"
    foreach ($d in $r.Disks) {
        $body += "<div class=""disk"">$(& $enc $d.Label)<span>$(& $enc $d.Text)</span></div>" + (& $bar $d.UsedPct $d.Warn)
    }
    $null = $sb.AppendLine((& $card 'Archiviazione' $body))

    $body = "<p><b>$(& $enc $r.GpuName)</b></p><table>" +
        (& $row 'Memoria video' $r.GpuVram) +
        (& $row 'Risoluzione' $r.GpuResolution) +
        (& $row 'Driver' $r.GpuDriver) + '</table>'
    $null = $sb.AppendLine((& $card 'Grafica' $body))

    $body = '<table>' +
        (& $row 'Scheda' $r.NetAdapter) +
        (& $row 'Indirizzo IPv4' $r.NetIp) +
        (& $row 'Indirizzo MAC' $r.NetMac) +
        (& $row 'Stato' $r.NetStatus) + '</table>'
    $null = $sb.AppendLine((& $card 'Rete' $body))

    if ($r.HasBattery) {
        $body = "<p class=""big"">$(& $enc $r.BatteryCharge)</p>" + (& $bar $r.BatteryPct ($r.BatteryPct -le 15)) + '<table>' +
            (& $row 'Stato' $r.BatteryStatus) +
            (& $row 'Salute' $r.BatteryHealth) + '</table>'
        $null = $sb.AppendLine((& $card 'Batteria' $body))
    }

    $null = $sb.AppendLine('</div>')

    # Windows Update history as a full-width table, as in the dashboard
    $level = @{ Success = 'ok'; Warning = 'warn'; Danger = 'danger'; Muted = 'muted' }
    $body = "<div class=""facts""><div><span>Ultima installazione</span><b>$(& $enc $r.UpdatesLastInstall)</b></div>" +
        "<div><span>Ultima ricerca</span><b>$(& $enc $r.UpdatesLastSearch)</b></div></div>"
    if (@($r.UpdatesRecent).Count -gt 0) {
        $body += '<table class="list"><thead><tr><th>Data</th><th>Aggiornamento</th><th>KB</th><th>Esito</th></tr></thead><tbody>' +
            (-join (@($r.UpdatesRecent) | ForEach-Object {
                "<tr><td class=""nw muted"">$(& $enc $_.Date)</td><td>$(& $enc $_.Title)</td><td class=""nw"">$(& $enc $_.KB)</td>" +
                "<td class=""nw $($level[[string]$_.Level])"">$(& $enc $_.Result)</td></tr>"
            })) + '</tbody></table>'
    }
    $null = $sb.AppendLine("<section class=""card wide""><h3>Aggiornamenti Windows</h3>$body</section>")
    $null = $sb.AppendLine("<footer>Generato con WinRUtil $(& $enc $sync.version) &middot; https://github.com/rtecnocopy89/WinRUtil</footer>")
    $null = $sb.AppendLine('</main>')
    $null = $sb.AppendLine('</body>')
    $null = $sb.AppendLine('</html>')
    $sb.ToString()
}

function Invoke-WPFSystemInfoExport {
    <#
        .SYNOPSIS
            Asks where to save the system report and writes it as an HTML page (opened in the
            default browser, ready to print or save as PDF) or as plain text.
    #>

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Esporta il report di sistema"
    $dialog.Filter = "Report HTML (*.html)|*.html|Testo semplice (*.txt)|*.txt"
    $dialog.FileName = "WinRUtil-Sistema_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilSystemLog "Esportazione del report annullata." -Level Warning
        return
    }
    $sync.SystemReportExportPath = $dialog.FileName

    Write-WinUtilSystemLog "Creazione del report di sistema..."
    Invoke-WPFRunspace -ScriptBlock {
        try {
            $path = $sync.SystemReportExportPath
            $r = $sync.SystemReport
            if (-not $r) { $r = Get-WinUtilSystemReport; $sync.SystemReport = $r }

            $isText = [System.IO.Path]::GetExtension($path) -ieq '.txt'
            $content = if ($isText) { ConvertTo-WinUtilSystemReportText -Report $r } else { ConvertTo-WinUtilSystemReportHtml -Report $r }
            [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($true))
            Write-WinUtilSystemLog "Report salvato: $path" -Level Success
            if (-not $isText) { Start-Process -FilePath $path }
        } catch {
            Write-WinUtilSystemLog "Impossibile creare il report: $($_.Exception.Message)" -Level Error
        }
    }
}
function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image

        The exit code of each step is checked: a failed step stops the repair, and the error of
        DISM is explained.
    #>

    # SuccessCodes are the exit codes other than 0 that a step treats as success. The same number
    # means different things: 1 and 2 are normal results of chkdsk, while 1 from sfc is a failure.
    $steps = @(
        @{
            Label = "CHKDSK (controllo del disco)"
            Arguments = "/c chkdsk /scan /perf"
            # 3: the disk could not be checked or has errors that an online scan cannot fix,
            # and the next steps are not worth running on a disk in that state
            SuccessCodes = @(1, 2)
        },
        @{
            Label = "SFC (controllo dei file di sistema)"
            Arguments = "/c sfc /scannow"
            SuccessCodes = @()
        },
        @{
            Label = "DISM (riparazione dell'immagine di Windows)"
            Arguments = "/c dism /online /cleanup-image /restorehealth"
            # 3010: repaired, a restart is needed
            SuccessCodes = @(3010)
        }
    )

    # The most common errors of DISM, which are Windows system error codes
    $dismErrors = @{
        2 = "file non trovato"
        3 = "percorso non trovato"
        5 = "accesso negato"
        21 = "dispositivo non pronto"
        32 = "file in uso da un altro programma"
        50 = "richiesta non supportata"
        87 = "parametro non valido"
        112 = "disco pieno"
        1168 = "elemento non trovato"
        1223 = "operazione annullata"
        1392 = "file o cartella danneggiati"
        1460 = "tempo scaduto"
        -2146498529 = "file di origine non trovati: serve Windows Update o un'immagine di Windows come origine"
        -2146498298 = "impossibile scaricare i file di origine: controlla la connessione a Internet e Windows Update"
        -2146498297 = "un criterio di gruppo impedisce di scaricare i file di origine da Windows Update"
    }

    $failure = $null
    foreach ($step in $steps) {
        Write-Host "==> $($step.Label)"
        $exitCode = Invoke-WinUtilProcess -FilePath "cmd.exe" -ArgumentList $step.Arguments -NoNewWindow
        if ($exitCode -ne 0 -and $step.SuccessCodes -notcontains $exitCode) {
            $failure = "{0}: codice di uscita {1} (0x{1:X8})" -f $step.Label, $exitCode
            if ($step.Label -like "DISM*" -and $dismErrors.ContainsKey($exitCode)) {
                $failure += ", " + $dismErrors[$exitCode]
            }
            break
        }
    }

    if ($failure) {
        Write-Warning "System repair stopped. $failure"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Add-WinUtilSessionAction -Area "Riparazione" -Text "Controllo e riparazione del sistema (CHKDSK, SFC, DISM) - $failure" -Status "Error"
        [System.Windows.MessageBox]::Show("Controllo e riparazione del sistema non completato.`n`n$failure", "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    Add-WinUtilSessionAction -Area "Riparazione" -Text "Controllo e riparazione del sistema (CHKDSK, SFC, DISM)"
}
function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header

    # Reflect the active section in the title bar (Italian display names)
    if ($sync.WPFCurrentTabTitle) {
        $titleMap = @{
            "Install"  = "Installa"
            "Tweaks"   = "Ottimizza"
            "Config"   = "Configura"
            "Updates"  = "Aggiornamenti"
            "Printers" = "Stampanti"
            "System"   = "Sistema"
            "WiFi"     = "Password Wi-Fi"
            "Report"   = "Rapporto di intervento"
            "AppX"     = "App di Windows"
        }
        $display = $titleMap[[string]$sync.currentTab]
        if (-not $display) { $display = $sync.currentTab }
        $sync.WPFCurrentTabTitle.Text = $display
    }

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset the search of the Install tab, keeping the categories chosen with the chips
        Find-AppsByNameOrDescription -SearchString "" -Categories @($sync.SelectedAppCategories)
    } elseif ($sync.currentTab -eq "Tweaks" -or $sync.currentTab -eq "AppX") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "System") {
        # Auto-populate the System dashboard when it is opened
        Invoke-WPFSystemInfoRefresh
    } elseif ($sync.currentTab -eq "Report") {
        # Show the operations recorded so far in this session
        Update-WinUtilReportView
    }

    # Live CPU / memory values only while the System dashboard is visible
    if ($sync.currentTab -eq "System") {
        Start-WinUtilSystemLiveUpdate
    } else {
        Stop-WinUtilSystemLiveUpdate
    }

    # Show search bar in Install, Tweaks and Windows apps tabs
    if ($sync.currentTab -in @("Install", "Tweaks", "AppX")) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}
function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}
function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "Attendi la fine dell'operazione in corso."
    [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Seleziona le ottimizzazioni da applicare."
    [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  Write-Debug "Number of tweaks to process: $($Tweaks.Count)"

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilProgressBar -Label "Creazione del punto di ripristino" -Percent 0
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilProgressBar -Label "Ottimizzazioni completate" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  $handle = Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)
    Write-Debug "Inside Number of tweaks to process: $($Tweaks.Count)"

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -and $dnsProvider -ne "Default") {
      Set-WinUtilProgressBar -Label "Impostazione del DNS: $dnsProvider" -Percent ($completedSteps / $totalSteps * 100)
      # Going on after a failed DNS change would leave the PC half configured
      if (@(Set-WinUtilDNS -DNSProvider $dnsProvider)[-1] -ne $true) {
        Set-WinUtilProgressBar -Label "DNS non impostato: ottimizzazioni non applicate" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock {
          Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
          [System.Windows.MessageBox]::Show("Impossibile impostare il DNS su $dnsProvider, quindi le altre ottimizzazioni non sono state applicate. I dettagli sono nella finestra della console.", "WinRUtil", "OK", "Warning") | Out-Null
        }
        return
      }
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      $tweakName = $sync.configs.tweaks.($tweaks[$i]).Content
      if (-not $tweakName) { $tweakName = $tweaks[$i] }
      Set-WinUtilProgressBar -Label "Applicazione: $tweakName" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilProgressBar -Label "Ottimizzazioni completate" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
  }
}
function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            ComboDescriptions = $entryInfo.ComboDescriptions
            Registry    = $entryInfo.registry
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        if ($entryInfo.Name -eq "WPFToggleFOSSHighlight") {
                             if ($entryInfo.Checked -eq $true) {
                                 $sync[$entryInfo.Name].IsChecked = $true
                             }

                             $sync[$entryInfo.Name].Add_Checked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                             $sync[$entryInfo.Name].Add_Unchecked({
                                 Invoke-WPFButton -Button "WPFToggleFOSSHighlight"
                             })
                        } else {
                            $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                            $sync[$entryInfo.Name].Add_Checked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                                # Skip applying tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtilTweaks $Sender.name
                                }
                            })

                            $sync[$entryInfo.Name].Add_Unchecked({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                                # Skip undoing tweaks while an import is restoring toggle states
                                if (-not $sync.ImportInProgress) {
                                    Invoke-WinUtiltweaks $Sender.name -undo $true
                                }
                            })
                        }
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $entryInfo.Content[0] }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        # A combo box with registry Values applies its choice as soon as it is selected
                        $comboBox.Tag = [pscustomobject]@{
                            Registry = $(if ($entryInfo.Registry -and @($entryInfo.Registry)[0].Values) { $entryInfo.Registry } else { $null })
                            State = $null
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        # The choices are separated by "|" when they contain spaces
                        $comboItems = if ($entryInfo.ComboItems.Contains("|")) { $entryInfo.ComboItems -split "\|" } else { $entryInfo.ComboItems -split " " }
                        foreach ($comboitem in $comboItems) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            if ($entryInfo.ComboDescriptions -and $entryInfo.ComboDescriptions.PSObject.Properties[$comboitem]) {
                                $comboBoxItem.ToolTip = $entryInfo.ComboDescriptions.PSObject.Properties[$comboitem].Value
                            }
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        if ($comboBox.Tag.Registry) {
                            try {
                                $comboBox.Tag.State = Get-WinUtilRegistryComboState -Registry $comboBox.Tag.Registry
                                $comboBox.SelectedIndex = [array]::IndexOf([string[]]$comboItems, [string]$comboBox.Tag.State)
                            } catch {
                                # Values written by hand or by another program: no choice is selected until one is chosen
                                $unknownStateItem = New-Object Windows.Controls.ComboBoxItem
                                $unknownStateItem.Content = "Personalizzato - scegli un'opzione"
                                $unknownStateItem.IsEnabled = $false
                                $unknownStateItem.ToolTip = $_.Exception.Message
                                $comboBox.Items.Add($unknownStateItem) | Out-Null
                                $comboBox.SelectedItem = $unknownStateItem
                            }
                        } else {
                            $comboBox.SelectedIndex = 0
                        }

                        # Set initial text
                        if ($comboBox.SelectedItem) {
                            $comboBox.Text = $comboBox.SelectedItem.Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if (-not $selectedItem) {
                                return
                            }
                            $this.Text = $selectedItem.Content
                            $registry = $this.Tag.Registry
                            if ($registry -and $selectedItem.IsEnabled -and $selectedItem.Content -ne $this.Tag.State) {
                                try {
                                    Set-WinUtilRegistryComboState -Registry $registry -State $selectedItem.Content
                                    $this.Tag.State = $selectedItem.Content
                                    $label = $this.Parent.Children[0].Content
                                    Add-WinUtilSessionAction -Area "Ottimizzazione" -Text ("{0}: {1}" -f $label, $selectedItem.Content)
                                    # The placeholder of an unknown state is no longer needed
                                    foreach ($item in @($this.Items)) {
                                        if (-not $item.IsEnabled) {
                                            $this.Items.Remove($item)
                                            break
                                        }
                                    }
                                } catch {
                                    $applyError = $_.Exception.Message
                                    $previous = $null
                                    foreach ($item in @($this.Items)) {
                                        if ($item.Content -eq $this.Tag.State -or (-not $this.Tag.State -and -not $item.IsEnabled)) {
                                            $previous = $item
                                            break
                                        }
                                    }
                                    $this.SelectedItem = $previous
                                    [System.Windows.MessageBox]::Show($applyError, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                                }
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)

                            # Add the group container to the ItemsControl and remember it for the next RadioButtons of the same group
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                            $radioButtonGroups[$entryInfo.GroupName] = $groupStackPanel
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkbox $Sender.name
                        })
                    }
                }
            }
        }
    }
}
function Invoke-WPFUIThread {
    <#

    .SYNOPSIS
        Creates and runs a task on Winutil's WPF Forms thread.

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the thread
    #>

    [CmdletBinding()]
    Param (
        $ScriptBlock
    )

    if ($PARAM_NOUI) {
        return;
    }

    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}
function Invoke-WPFUltimatePerformance {
    param(
        [switch]$Do
    )

    if ($Do) {
        if (-not (powercfg /list | Select-String "WinRUtil - Ultimate Power Plan")) {
            if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                powercfg /restoredefaultschemes
                if (-not (powercfg /list | Select-String "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c")) {
                    Write-Host "Failed to restore High Performance plan. Default plans do not include high performance. If you are on a laptop, do NOT use High Performance or Ultimate Performance plans." -ForegroundColor Red
                    return
                }
            }
            $guid = ((powercfg /duplicatescheme 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c) -split '\s+')[3]
            powercfg /changename $guid "WinRUtil - Ultimate Power Plan"
            powercfg /setacvalueindex $guid SUB_PROCESSOR IDLEDISABLE 1
            powercfg /setacvalueindex $guid 54533251-82be-4824-96c1-47b60b740d00 4d2b0152-7d5c-498b-88e2-34345392a2c5 1
            powercfg /setacvalueindex $guid SUB_PROCESSOR PROCTHROTTLEMIN 100
            powercfg /setactive $guid
            Write-Host "WinRUtil - Ultimate Power Plan plan installed and activated." -ForegroundColor Green
            Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "Profilo Prestazioni eccellenti - Attiva"
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is already installed." -ForegroundColor Red
            return
        }
    } else {
        if (powercfg /list | Select-String "WinRUtil - Ultimate Power Plan") {
            powercfg /setactive SCHEME_BALANCED
            powercfg /delete ((powercfg /list | Select-String "WinRUtil - Ultimate Power Plan").ToString().Split()[3])
            Write-Host "WinRUtil - Ultimate Power Plan plan was removed." -ForegroundColor Red
            Add-WinUtilSessionAction -Area "Ottimizzazione" -Text "Profilo Prestazioni eccellenti - Disattiva"
        } else {
            Write-Host "WinRUtil - Ultimate Power Plan plan is not installed." -ForegroundColor Yellow
        }
    }
}
function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Seleziona le ottimizzazioni da annullare."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            $tweakName = $sync.configs.tweaks.($tweaks[$i]).Content
            if (-not $tweakName) { $tweakName = $tweaks[$i] }
            Set-WinUtilProgressBar -Label "Annullamento: $tweakName" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilProgressBar -Label "Annullamento completato" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="

    }
}
function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "Attendi la fine dell'operazione in corso."
        [System.Windows.MessageBox]::Show($msg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Seleziona i programmi da disinstallare."
        [System.Windows.MessageBox]::Show($WarningMsg, "WinRUtil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $ButtonType = [System.Windows.MessageBoxButton]::YesNo
    $MessageboxTitle = "WinRUtil"
    $Messageboxbody = "Vuoi disinstallare i seguenti programmi?`n`n" + (($PackagesToUninstall | ForEach-Object { "- $($_.content)" }) -join "`n")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    $confirm = [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference -Action Uninstall
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

        if ($packagesWinget -contains "Microsoft.Edge") {
            # The Edge uninstaller refuses to run unless this file exists
            New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force | Out-Null
        }

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "Disinstallazione app in corso..."

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
           Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        }
        $sync.ProcessRunning = $False

    }
}
function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    .DESCRIPTION
        Removes the values written by the other update profiles and enables the update services and
        tasks again. Other Windows Update policies, such as a WSUS server, are kept.

    #>

    Write-Host "Removing the Windows Update settings managed by WinRUtil..." -ForegroundColor Green

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    # Earlier versions hid the Windows Update page of the Settings app when disabling the updates
    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue

    Write-Host "Restored UsoSvc to Automatic"
    Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc -ErrorAction SilentlyContinue

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Ripristina impostazioni predefinite"
}
function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    .PARAMETER Confirmed
        Disables the updates without asking, for the automatic runs

    #>
    param([switch]$Confirmed)

    if (-not $Confirmed) {
        $message = "Disattivando Windows Update si fermano i servizi di aggiornamento, si disattivano le attivit$([char]0x00E0) pianificate e si cancellano gli aggiornamenti scaricati. Gli aggiornamenti di sicurezza non verranno installati finch$([char]0x00E9) non ripristini le impostazioni predefinite.`n`nVuoi continuare?"
        $answer = [System.Windows.MessageBox]::Show($message, "WinRUtil", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($answer -ne "Yes") {
            return
        }
    }

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    # New-Item -Force on an existing key deletes the key and its subkeys first: only missing keys
    # are created, so the other policies stored there (WSUS, target version...) are kept
    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
    }

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config")) {
        New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
    }

    Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Cleared SoftwareDistribution folder"

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "---   Updates Are Disabled    ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Disabilita gli aggiornamenti"
}
function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Downloads the updates and asks before installing them, so the PC does not restart unexpectedly

    #>

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "Restoring Windows Update availability..."
    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    # A Windows 11 image made by the Win11 Creator of earlier versions blocks Windows Update until its
    # first-logon cleanup runs: clear what is left of that block, but keep a real WSUS server
    Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "DisableWindowsUpdateAccess" -ErrorAction SilentlyContinue
    if ((Get-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUServer" -ErrorAction SilentlyContinue).WUServer -eq "http://localhost:8080") {
        Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUServer" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $windowsUpdatePolicyPath -Name "WUStatusServer" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "UseWUServer" -ErrorAction SilentlyContinue
    }

    Set-Service -Name BITS -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    Set-Service -Name UsoSvc -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name UsoSvc -ErrorAction SilentlyContinue

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Disabling driver offering through Windows Update..."

    # New-Item -Force on an existing key deletes the key and its subkeys first: only missing keys
    # are created, so the other policies stored there (WSUS, target version...) are kept
    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching")) {
        New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force | Out-Null
    }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    if (-not (Test-Path $windowsUpdatePolicyPath)) {
        New-Item -Path $windowsUpdatePolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Deferring feature updates by 365 days and quality updates by 4 days..."
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    # The values that earlier versions wrote in the settings of Windows Update instead of the policies
    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "Configuring automatic updates to download and notify before installation..."
    if (-not (Test-Path $automaticUpdatePolicyPath)) {
        New-Item -Path $automaticUpdatePolicyPath -Force | Out-Null
    }

    # NoAutoRebootWithLoggedOnUsers is not reliable on recent versions of Windows: AUOptions 3 downloads
    # the updates and notifies before installing them, so nothing is installed or restarted unasked
    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 3
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Add-WinUtilSessionAction -Area "Aggiornamenti" -Text "Windows Update - Applica impostazioni di sicurezza"
}
function Write-WinUtilWifiLog {
    <#
        .SYNOPSIS
            Appends a timestamped line to the Wi-Fi tab status log (UI-thread safe).
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
    $logBox = $sync.WPFWifiStatusLog
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

function Get-WinRUtilWifiProfiles {
    <#
    .SYNOPSIS
        Lists saved Wi-Fi profiles (SSID, plaintext password, security type, autoconnect).
    .DESCRIPTION
        Locale independent: exports every WLAN profile to XML via
        "netsh wlan export profile key=clear" and parses the XML elements
        (name, authentication, keyMaterial, connectionMode) instead of reading
        the localized console output of "netsh wlan show profile ... key=clear".
        Works on Windows PowerShell 5.1+ and PowerShell 7. ASCII-only source.
    .OUTPUTS
        Array of [PSCustomObject] with properties: Ssid, Password, Security, AutoConnect, Hidden, CanShare.
    #>
    [CmdletBinding()]
    param()

    # Unique temp working folder; removed in finally.
    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    $results = New-Object System.Collections.Generic.List[object]
    $skipped = 0

    try {
        # Bail out gracefully if the WLAN AutoConfig service is not running.
        $svc = Get-Service -Name 'Wlansvc' -ErrorAction SilentlyContinue
        if ($null -eq $svc -or $svc.Status -ne 'Running') {
            return @()
        }

        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null

        # Export ALL profiles at once with cleartext keys. Names with spaces /
        # special chars are handled by netsh; SSIDs are read from the XML below,
        # never from the (mangled, locale-affected) file names.
        $null = netsh wlan export profile key=clear folder="$work" 2>&1

        $xmlFiles = @(Get-ChildItem -Path $work -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($xmlFiles.Count -eq 0) {
            return @()
        }

        foreach ($file in $xmlFiles) {
            try {
                # Read raw text first; used both for XML load and regex fallback.
                $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop

                $ssid          = $null
                $authentication = $null
                $keyMaterial    = $null
                $hasKeyElement  = $false
                $connectionMode = $null
                $hidden         = $false
                $encryption     = $null

                # Primary path: parse as XML using namespace-agnostic local-name()
                # XPath so the default v1 namespace (and nested v3/v4) do not matter.
                $parsedXml = $false
                try {
                    $doc = New-Object System.Xml.XmlDocument
                    $doc.PreserveWhitespace = $false
                    $doc.LoadXml($raw)

                    $nameNode = $doc.SelectSingleNode("//*[local-name()='WLANProfile']/*[local-name()='name']")
                    if ($null -eq $nameNode) {
                        $nameNode = $doc.SelectSingleNode("//*[local-name()='name']")
                    }
                    if ($nameNode) { $ssid = $nameNode.InnerText }

                    $authNode = $doc.SelectSingleNode("//*[local-name()='authentication']")
                    if ($authNode) { $authentication = $authNode.InnerText }

                    $encNode = $doc.SelectSingleNode("//*[local-name()='encryption']")
                    if ($encNode) { $encryption = $encNode.InnerText }

                    $keyNode = $doc.SelectSingleNode("//*[local-name()='keyMaterial']")
                    if ($keyNode) {
                        $hasKeyElement = $true
                        $keyMaterial = $keyNode.InnerText
                    }

                    $cmNode = $doc.SelectSingleNode("//*[local-name()='connectionMode']")
                    if ($cmNode) { $connectionMode = $cmNode.InnerText }

                    # Networks that do not broadcast their SSID
                    $hiddenNode = $doc.SelectSingleNode("//*[local-name()='nonBroadcast']")
                    $hidden = $hiddenNode -and $hiddenNode.InnerText -match '^(true|1)$'

                    # transitionMode (WPA2<->WPA3 mixed) lives in the v4 namespace.
                    $transNode = $doc.SelectSingleNode("//*[local-name()='transitionMode']")
                    $transitionMode = $false
                    if ($transNode -and $transNode.InnerText -match '^(true|1)$') {
                        $transitionMode = $true
                    }

                    $parsedXml = $true
                }
                catch {
                    $parsedXml = $false
                }

                # Robust fallback: regex the inner text of the elements if XML
                # parsing failed for any reason (e.g. unexpected encoding).
                if (-not $parsedXml) {
                    $transitionMode = $false
                    $hidden = $raw -match '(?s)<nonBroadcast>\s*(true|1)\s*</nonBroadcast>'
                    if ($raw -match '(?s)<name>(.*?)</name>') { $ssid = $matches[1] }
                    if ($raw -match '(?s)<authentication>(.*?)</authentication>') { $authentication = $matches[1] }
                    if ($raw -match '(?s)<encryption>(.*?)</encryption>') { $encryption = $matches[1] }
                    if ($raw -match '(?s)<keyMaterial>(.*?)</keyMaterial>') {
                        $hasKeyElement = $true
                        $keyMaterial = $matches[1]
                    }
                    if ($raw -match '(?s)<connectionMode>(.*?)</connectionMode>') { $connectionMode = $matches[1] }
                    if ($raw -match '(?s)<transitionMode[^>]*>(.*?)</transitionMode>') {
                        if ($matches[1] -match '^(true|1)$') { $transitionMode = $true }
                    }
                    # Decode the handful of XML entities that appear in SSIDs.
                    if ($null -ne $ssid) {
                        $ssid = $ssid -replace '&amp;', '&' -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&apos;', "'"
                    }
                }

                if ([string]::IsNullOrEmpty($ssid)) {
                    $skipped++
                    continue
                }

                # Normalize values.
                if ($null -eq $authentication) { $authentication = '' }
                $authUpper = $authentication.ToUpperInvariant()

                # Password: empty string for open networks (no keyMaterial element).
                if (-not $hasKeyElement -or $null -eq $keyMaterial) {
                    $password = ''
                }
                else {
                    $password = $keyMaterial
                }

                # AutoConnect: Italian yes / no based on connectionMode (char code keeps the source ASCII-only).
                if ($connectionMode -and $connectionMode.Trim().ToLowerInvariant() -eq 'auto') {
                    $autoConnect = "S$([char]0x00EC)"
                }
                else {
                    $autoConnect = 'No'
                }

                # Map the raw authentication token to a human-readable label.
                $security = switch -Regex ($authUpper) {
                    '^OPEN$'        { if ($hasKeyElement -and $encryption -match '^WEP$') { 'WEP' } else { 'Aperta' }; break }   # open-system WEP has a key
                    '^SHARED$'      { 'WEP'; break }            # legacy shared-key WEP
                    '^WPA3SAE$'     { if ($transitionMode) { 'WPA2/WPA3' } else { 'WPA3-SAE' }; break }
                    '^WPA3ENT.*'    { 'WPA3-Enterprise'; break }
                    '^WPA3$'        { 'WPA3-Enterprise'; break }
                    '^WPA2PSK$'     { 'WPA2-Personal'; break }
                    '^WPA2$'        { 'WPA2-Enterprise'; break }
                    '^WPAPSK$'      { 'WPA-Personal'; break }
                    '^WPA$'         { 'WPA-Enterprise'; break }
                    'OWE'           { 'OWE'; break }            # Enhanced Open
                    default {
                        if ([string]::IsNullOrEmpty($authentication)) {
                            if ($hasKeyElement) { 'Sconosciuta' } else { 'Aperta' }
                        }
                        else {
                            $authentication
                        }
                    }
                }

                # If there is genuinely no key element and auth says open, force Aperta.
                if (-not $hasKeyElement -and ($authUpper -eq 'OPEN' -or $authUpper -eq '')) {
                    $security = 'Aperta'
                    $password = ''
                }

                $results.Add([PSCustomObject]@{
                    Ssid        = $ssid
                    Password    = $password
                    Security    = $security
                    AutoConnect = $autoConnect
                    Hidden      = [bool]$hidden
                    # Enterprise (802.1X) networks use per-user credentials, which a Wi-Fi QR code cannot carry
                    CanShare    = ($security -notmatch 'Enterprise') -and ($password -ne '' -or $security -in @('Aperta', 'OWE'))
                })
            }
            catch {
                $skipped++
                continue
            }
        }
    }
    catch {
        # Any unexpected failure: return whatever we have (possibly empty), never throw.
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($skipped -gt 0) {
        Write-Verbose ("Get-WinRUtilWifiProfiles: skipped {0} profile(s) that failed to parse." -f $skipped)
    }

    # Sort by Ssid and always return an array.
    return @($results | Sort-Object -Property Ssid)
}

function Invoke-WPFWifiRefresh {
    <#
        .SYNOPSIS
            Scans saved Wi-Fi networks and fills the Wi-Fi DataGrid (SSID, password, security, autoconnect).
    #>
    Write-WinUtilWifiLog "Scansione delle reti Wi-Fi salvate..."
    try {
        $profiles = @(Get-WinRUtilWifiProfiles)
        $sync.WPFWifiList.ItemsSource = $profiles
        $withPwd = @($profiles | Where-Object { $_.Password -ne "" }).Count
        Write-WinUtilWifiLog ("Trovate {0} rete/i Wi-Fi ({1} con password)." -f $profiles.Count, $withPwd) -Level Success
    } catch {
        Write-WinUtilWifiLog "Impossibile leggere le reti Wi-Fi: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFWifiCopyAll {
    <#
        .SYNOPSIS
            Copies all scanned Wi-Fi networks (SSID, password, security) to the clipboard as tab-separated text.
    #>
    $items = @($sync.WPFWifiList.ItemsSource)
    if ($items.Count -eq 0) {
        Write-WinUtilWifiLog "Nessuna rete da copiare. Esegui prima una scansione." -Level Warning
        return
    }

    $lines = foreach ($it in $items) {
        "{0}`t{1}`t{2}" -f $it.Ssid, $it.Password, $it.Security
    }
    $text = "SSID`tPassword`tSicurezza`r`n" + ($lines -join "`r`n")

    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        Write-WinUtilWifiLog ("Copiate {0} rete/i negli appunti." -f $items.Count) -Level Success
    } catch {
        Write-WinUtilWifiLog "Copia negli appunti non riuscita: $($_.Exception.Message)" -Level Error
    }
}

function Test-WinUtilWlanService {
    <#
        .SYNOPSIS
            Returns $true when the WLAN AutoConfig service is running; otherwise logs why the Wi-Fi tools are unavailable.
    #>
    $svc = Get-Service -Name 'Wlansvc' -ErrorAction SilentlyContinue
    if ($null -eq $svc -or $svc.Status -ne 'Running') {
        Write-WinUtilWifiLog "Servizio WLAN (Wlansvc) non attivo: su questo PC non sono disponibili reti Wi-Fi." -Level Warning
        return $false
    }
    return $true
}

function Export-WinUtilWifiProfiles {
    <#
        .SYNOPSIS
            Exports every saved Wi-Fi profile, with its key in clear text, to a .zip archive that
            Import-WinUtilWifiProfiles (or "netsh wlan add profile") can import on another PC.
        .PARAMETER Path
            Full path of the .zip archive to create. An existing file is replaced.
        .OUTPUTS
            The number of exported profiles.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    try {
        New-Item -ItemType Directory -Path $work -Force -ErrorAction Stop | Out-Null
        $null = netsh wlan export profile key=clear folder="$work" 2>&1

        $files = @(Get-ChildItem -LiteralPath $work -Filter '*.xml' -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) {
            return 0
        }

        $readme = @(
            "Profili Wi-Fi esportati da WinRUtil ($env:COMPUTERNAME, $(Get-Date -Format 'dd/MM/yyyy HH:mm'))."
            "ATTENZIONE: i file contengono le password in chiaro, conserva questo archivio in un luogo sicuro."
            ""
            "Per importarli su un altro PC:"
            "- WinRUtil > Wi-Fi > Importa profili, poi scegli questo file .zip"
            "- oppure, da un prompt dei comandi come amministratore, per ogni file .xml:"
            "  netsh wlan add profile filename=""NomeFile.xml"" user=all"
        )
        Set-Content -LiteralPath (Join-Path $work 'LEGGIMI.txt') -Value $readme -Encoding ASCII

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($work, $Path)
        return $files.Count
    }
    finally {
        # The exported files contain the keys in clear text: never leave them behind
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Import-WinUtilWifiProfiles {
    <#
        .SYNOPSIS
            Imports Wi-Fi profiles for all users from .zip archives created by Export-WinUtilWifiProfiles
            or from .xml profile files exported by netsh.
        .PARAMETER Path
            One or more .zip or .xml files.
        .OUTPUTS
            One object per profile file, with Name, Success and Message.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    $work = Join-Path $env:TEMP ("winrutil_wifi_" + [guid]::NewGuid().ToString())
    try {
        $xmlFiles = New-Object System.Collections.Generic.List[string]
        foreach ($item in $Path) {
            if ([System.IO.Path]::GetExtension($item) -ieq '.zip') {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $target = Join-Path $work ([guid]::NewGuid().ToString())
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                [System.IO.Compression.ZipFile]::ExtractToDirectory($item, $target)
                Get-ChildItem -LiteralPath $target -Filter '*.xml' -File -Recurse | ForEach-Object { $xmlFiles.Add($_.FullName) }
            } else {
                $xmlFiles.Add($item)
            }
        }

        foreach ($file in $xmlFiles) {
            # Only WLAN profile documents are handed to netsh
            $name = $null
            try {
                $doc = New-Object System.Xml.XmlDocument
                $stream = [System.IO.File]::OpenRead($file)
                try { $doc.Load($stream) } finally { $stream.Dispose() }
                if ($doc.DocumentElement.LocalName -eq 'WLANProfile') {
                    $nameNode = $doc.DocumentElement.SelectSingleNode("*[local-name()='name']")
                    if ($nameNode) { $name = $nameNode.InnerText }
                }
            } catch {
                $name = $null
            }

            if ([string]::IsNullOrEmpty($name)) {
                [PSCustomObject]@{ Name = [System.IO.Path]::GetFileName($file); Success = $false; Message = "File non valido: non contiene un profilo Wi-Fi." }
                continue
            }

            $output = netsh wlan add profile filename="$file" user=all 2>&1
            [PSCustomObject]@{
                Name    = $name
                Success = ($LASTEXITCODE -eq 0)
                Message = (($output | Out-String) -replace '\s+', ' ').Trim()
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WPFWifiExport {
    <#
        .SYNOPSIS
            Asks for a destination file and exports all saved Wi-Fi profiles, with their passwords, to a .zip archive.
    #>
    if (-not (Test-WinUtilWlanService)) {
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Esporta i profili Wi-Fi"
    $dialog.Filter = "Archivio ZIP (*.zip)|*.zip"
    $dialog.FileName = "WinRUtil-WiFi_{0}_{1}.zip" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilWifiLog "Esportazione annullata." -Level Warning
        return
    }

    Write-WinUtilWifiLog "Esportazione dei profili Wi-Fi..."
    try {
        $count = Export-WinUtilWifiProfiles -Path $dialog.FileName
        if ($count -eq 0) {
            Write-WinUtilWifiLog "Nessun profilo Wi-Fi da esportare." -Level Warning
        } else {
            Write-WinUtilWifiLog ("Esportati {0} profilo/i in {1}" -f $count, $dialog.FileName) -Level Success
            Write-WinUtilWifiLog "Il file contiene le password in chiaro: conservalo in un luogo sicuro." -Level Warning
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Backup di {0} {1}" -f $count, $(if ($count -eq 1) { "profilo Wi-Fi" } else { "profili Wi-Fi" }))
        }
    } catch {
        Write-WinUtilWifiLog "Esportazione non riuscita: $($_.Exception.Message)" -Level Error
        Add-WinUtilSessionAction -Area "Wi-Fi" -Text "Backup dei profili Wi-Fi" -Status "Error"
    }
}

function Invoke-WPFWifiImport {
    <#
        .SYNOPSIS
            Asks for one or more exported files (.zip or .xml) and imports the Wi-Fi profiles they contain.
    #>
    if (-not (Test-WinUtilWlanService)) {
        return
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Importa profili Wi-Fi"
    $dialog.Filter = "Profili Wi-Fi (*.zip;*.xml)|*.zip;*.xml"
    $dialog.Multiselect = $true
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-WinUtilWifiLog "Importazione annullata." -Level Warning
        return
    }

    Write-WinUtilWifiLog "Importazione dei profili Wi-Fi..."
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    try {
        $results = @(Import-WinUtilWifiProfiles -Path $dialog.FileNames)
        foreach ($res in $results) {
            if ($res.Success) {
                Write-WinUtilWifiLog "Importata: $($res.Name)"
            } else {
                Write-WinUtilWifiLog "Non importata: $($res.Name) - $($res.Message)" -Level Warning
            }
        }

        $imported = @($results | Where-Object { $_.Success }).Count
        if ($results.Count -eq 0) {
            Write-WinUtilWifiLog "Nessun profilo Wi-Fi trovato nei file selezionati." -Level Warning
        } elseif ($imported -eq $results.Count) {
            Write-WinUtilWifiLog ("Importate {0} rete/i." -f $imported) -Level Success
        } else {
            Write-WinUtilWifiLog ("Importate {0} rete/i su {1}." -f $imported, $results.Count) -Level Warning
        }

        # One report line for the imported networks and one for those that failed
        $importedNames = @($results | Where-Object { $_.Success } | ForEach-Object { $_.Name })
        $failedNames = @($results | Where-Object { -not $_.Success } | ForEach-Object { $_.Name })
        if ($importedNames.Count -gt 0) {
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Configurazione {0}: {1}" -f $(if ($importedNames.Count -eq 1) { "della rete Wi-Fi" } else { "delle reti Wi-Fi" }), ($importedNames -join ", "))
        }
        if ($failedNames.Count -gt 0) {
            Add-WinUtilSessionAction -Area "Wi-Fi" -Text ("Configurazione {0}: {1}" -f $(if ($failedNames.Count -eq 1) { "della rete Wi-Fi" } else { "delle reti Wi-Fi" }), ($failedNames -join ", ")) -Status "Error"
        }
    } catch {
        Write-WinUtilWifiLog "Importazione non riuscita: $($_.Exception.Message)" -Level Error
        Add-WinUtilSessionAction -Area "Wi-Fi" -Text "Importazione dei profili Wi-Fi" -Status "Error"
    } finally {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    }

    Invoke-WPFWifiRefresh
}

function Get-WinUtilWifiQRText {
    <#
        .SYNOPSIS
            Returns the Wi-Fi configuration text that phone cameras recognize in a QR code
            (WIFI:T:<type>;S:<ssid>;P:<password>;;), with \ ; , : and " escaped.
        .PARAMETER Network
            A network returned by Get-WinRUtilWifiProfiles.
    #>
    param(
        [Parameter(Mandatory)]
        $Network
    )

    $escape = { param([string]$value) $value -replace '([\\;,:"])', '\$1' }
    $type = switch -Regex ($Network.Security) {
        '^(Aperta|OWE)$' { 'nopass'; break }
        '^WEP$' { 'WEP'; break }
        default { 'WPA' }
    }

    $text = "WIFI:T:{0};S:{1};" -f $type, (& $escape $Network.Ssid)
    if ($type -ne 'nopass') {
        $text += "P:{0};" -f (& $escape $Network.Password)
    }
    if ($Network.Hidden) {
        $text += "H:true;"
    }
    $text + ";"
}

function ConvertTo-WinUtilQRGeometry {
    <#
        .SYNOPSIS
            Returns the dark modules of a QR code (see ConvertTo-WinUtilQRCode) as a frozen geometry,
            one unit per module, without the quiet zone.
    #>
    param(
        [Parameter(Mandatory)]
        $QRCode
    )

    $size = $QRCode.Size
    $modules = $QRCode.Modules
    $geometry = [System.Windows.Media.StreamGeometry]::new()
    $context = $geometry.Open()
    try {
        for ($y = 0; $y -lt $size; $y++) {
            $x = 0
            while ($x -lt $size) {
                if (-not $modules[$y * $size + $x]) {
                    $x++
                    continue
                }
                # One rectangle for each horizontal run of dark modules
                $start = $x
                while ($x -lt $size -and $modules[$y * $size + $x]) { $x++ }
                $context.BeginFigure([System.Windows.Point]::new($start, $y), $true, $true)
                $context.LineTo([System.Windows.Point]::new($x, $y), $false, $false)
                $context.LineTo([System.Windows.Point]::new($x, $y + 1), $false, $false)
                $context.LineTo([System.Windows.Point]::new($start, $y + 1), $false, $false)
            }
        }
    } finally {
        $context.Close()
    }
    $geometry.FillRule = [System.Windows.Media.FillRule]::Nonzero
    $geometry.Freeze()
    $geometry
}

function ConvertTo-WinUtilWifiQRCard {
    <#
        .SYNOPSIS
            Draws the QR code of a Wi-Fi network as a printable card with the network name and the password.
        .PARAMETER QRCode
            The QR code of the network (see ConvertTo-WinUtilQRCode).
        .PARAMETER Network
            The network the QR code connects to.
        .OUTPUTS
            A frozen 96 DPI bitmap.
    #>
    param(
        [Parameter(Mandatory)]
        $QRCode,
        [Parameter(Mandatory)]
        $Network
    )

    # Whole pixels per module keep the module edges sharp; the white margin is the 4-module quiet zone
    $moduleSize = [math]::Max(6, [int][math]::Floor(400 / ($QRCode.Size + 8)))
    $quietZone = 4 * $moduleSize
    $qrSide = $QRCode.Size * $moduleSize
    $width = $qrSide + 2 * $quietZone
    $padding = 24

    $culture = [System.Globalization.CultureInfo]::GetCultureInfo("it-IT")
    $family = [System.Windows.Media.FontFamily]::new("Segoe UI")
    $newText = {
        param([string]$value, $weight, [double]$emSize, [string]$color)
        $typeface = [System.Windows.Media.Typeface]::new($family, [System.Windows.FontStyles]::Normal, $weight, [System.Windows.FontStretches]::Normal)
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($color))
        $formatted = [System.Windows.Media.FormattedText]::new($value, $culture, [System.Windows.FlowDirection]::LeftToRight, $typeface, $emSize, $brush, 1.0)
        $formatted.MaxTextWidth = $width - 2 * $padding
        $formatted.TextAlignment = [System.Windows.TextAlignment]::Center
        $formatted
    }
    $secret = if ($Network.Password) { "Password: $($Network.Password)" } else { "Rete aperta, senza password" }
    $lines = @(
        (& $newText $Network.Ssid ([System.Windows.FontWeights]::Bold) 22 "#111111")
        (& $newText $secret ([System.Windows.FontWeights]::Normal) 16 "#333333")
        (& $newText "Inquadra il codice con la fotocamera del telefono per collegarti alla rete Wi-Fi." ([System.Windows.FontWeights]::Normal) 12.5 "#666666")
    )
    $height = $quietZone + $qrSide + $quietZone + $padding
    foreach ($line in $lines) {
        $height += $line.Height + 6
    }

    $visual = [System.Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    $context.DrawRectangle([System.Windows.Media.Brushes]::White, $null, [System.Windows.Rect]::new(0, 0, $width, $height))
    $context.PushTransform([System.Windows.Media.MatrixTransform]::new($moduleSize, 0, 0, $moduleSize, $quietZone, $quietZone))
    $context.DrawGeometry([System.Windows.Media.Brushes]::Black, $null, (ConvertTo-WinUtilQRGeometry -QRCode $QRCode))
    $context.Pop()
    $top = $quietZone + $qrSide + $quietZone
    foreach ($line in $lines) {
        $context.DrawText($line, [System.Windows.Point]::new($padding, $top))
        $top += $line.Height + 6
    }
    $context.Close()

    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($width), [int][math]::Ceiling($height), 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $bitmap.Freeze()
    $bitmap
}

function Show-WinUtilWifiQRCode {
    <#
        .SYNOPSIS
            Shows, over the Wi-Fi tab, the QR code that connects a phone to the given network.
        .PARAMETER Network
            A network of the Wi-Fi list.
    #>
    param($Network)

    if (-not $Network) {
        return
    }
    if (-not $Network.CanShare) {
        if ($Network.Security -match 'Enterprise') {
            Write-WinUtilWifiLog "QR code non disponibile per $($Network.Ssid): le reti Enterprise (802.1X) usano credenziali personali." -Level Warning
        } else {
            Write-WinUtilWifiLog "QR code non disponibile per $($Network.Ssid): la password non risulta salvata su questo PC." -Level Warning
        }
        return
    }

    try {
        $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $Network)
    } catch {
        Write-WinUtilWifiLog "Impossibile creare il QR code: $($_.Exception.Message)" -Level Error
        return
    }

    # White background with the 4-module quiet zone, then the dark modules
    $side = $qr.Size + 8
    $drawing = [System.Windows.Media.DrawingGroup]::new()
    $drawing.Children.Add([System.Windows.Media.GeometryDrawing]::new([System.Windows.Media.Brushes]::White, $null, [System.Windows.Media.RectangleGeometry]::new([System.Windows.Rect]::new(0, 0, $side, $side))))
    $symbol = [System.Windows.Media.DrawingGroup]::new()
    $symbol.Transform = [System.Windows.Media.TranslateTransform]::new(4, 4)
    $symbol.Children.Add([System.Windows.Media.GeometryDrawing]::new([System.Windows.Media.Brushes]::Black, $null, (ConvertTo-WinUtilQRGeometry -QRCode $qr)))
    $drawing.Children.Add($symbol)
    $drawing.Freeze()

    $sync.WifiQrNetwork = $Network
    $sync.WifiQrCode = $qr
    $sync.WPFWifiQrImage.Source = [System.Windows.Media.DrawingImage]::new($drawing)
    $sync.WPFWifiQrSsid.Text = $Network.Ssid
    $sync.WPFWifiQrDetails.Text = if ($Network.Password) { "Sicurezza: $($Network.Security)" } else { "Rete aperta, senza password" }
    $sync.WPFWifiQrOverlay.Visibility = "Visible"
    Write-WinUtilWifiLog "QR code della rete $($Network.Ssid) pronto: inquadralo con la fotocamera del telefono."
}

function Invoke-WPFWifiQrSave {
    <#
        .SYNOPSIS
            Saves the QR code shown in the Wi-Fi tab as a PNG card, with the network name and the password, ready to print.
    #>
    $network = $sync.WifiQrNetwork
    $qr = $sync.WifiQrCode
    if (-not $network -or -not $qr) {
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = "Salva il QR code della rete Wi-Fi"
    $dialog.Filter = "Immagine PNG (*.png)|*.png"
    $dialog.FileName = "WiFi-{0}.png" -f ($network.Ssid -replace '[\\/:*?"<>|]', '_')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    try {
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create((ConvertTo-WinUtilWifiQRCard -QRCode $qr -Network $network)))
        $stream = [System.IO.File]::Create($dialog.FileName)
        try {
            $encoder.Save($stream)
        } finally {
            $stream.Dispose()
        }
        Write-WinUtilWifiLog "QR code salvato: $($dialog.FileName)" -Level Success
        if ($network.Password) {
            Write-WinUtilWifiLog "L'immagine contiene la password della rete: condividila solo con chi deve collegarsi." -Level Warning
        }
    } catch {
        Write-WinUtilWifiLog "Salvataggio del QR code non riuscito: $($_.Exception.Message)" -Level Error
    }
}

function Invoke-WPFWifiQrClose {
    <#
        .SYNOPSIS
            Closes the QR code shown in the Wi-Fi tab.
    #>
    $sync.WPFWifiQrOverlay.Visibility = "Collapsed"
    $sync.WPFWifiQrImage.Source = $null
    $sync.WifiQrNetwork = $null
    $sync.WifiQrCode = $null
}
Function Show-WinRUtilLogo {
    <#
        .SYNOPSIS
            Displays the WinRUtil logo in ASCII art.
        .DESCRIPTION
            Prints the WinRUtil banner with a green gradient based on the
            project's #3DF5A0 accent color when the console supports ANSI
            escape sequences (Windows Terminal, PowerShell 7+), falling back
            to standard console colors elsewhere.
        .EXAMPLE
            Show-WinRUtilLogo
    #>

    # The box-drawing characters are mapped at runtime so the source stays ASCII-only:
    # '#' full block, '|' and '=' double lines, '[' ']' '{' '}' double-line corners
    $glyphs = @{
        '#' = [char]0x2588; '|' = [char]0x2551; '=' = [char]0x2550
        '[' = [char]0x2554; ']' = [char]0x2557; '{' = [char]0x255A; '}' = [char]0x255D
    }
    $logo = @(
        '##]    ##]##]###]   ##]######] ##]   ##]########]##]##]'
        '##|    ##|##|####]  ##|##[==##]##|   ##|{==##[==}##|##|'
        '##| #] ##|##|##[##] ##|######[}##|   ##|   ##|   ##|##|'
        '##|###]##|##|##|{##]##|##[==##]##|   ##|   ##|   ##|##|'
        '{###[###[}##|##| {####|##|  ##|{######[}   ##|   ##|#######]'
        ' {==}{==} {=}{=}  {===}{=}  {=} {=====}    {=}   {=}{======}'
    ) | ForEach-Object {
        -join ($_.ToCharArray() | ForEach-Object { if ($glyphs.ContainsKey([string]$_)) { $glyphs[[string]$_] } else { $_ } })
    }

    $width = 60
    $bullet = [char]0x2022
    $tagline = "WinRUtil  $bullet  Windows Toolkit"
    if ($sync.version) { $tagline += "  $bullet  v$($sync.version)" }
    $rule = [string][char]0x2500 * $width
    $centered = (' ' * [math]::Max(0, [math]::Floor(($width - $tagline.Length) / 2))) + $tagline

    $supportsAnsi = ($null -ne $env:WT_SESSION) -or
                    ($PSVersionTable.PSVersion.Major -ge 7) -or
                    ($Host.UI.PSObject.Properties['SupportsVirtualTerminal'] -and $Host.UI.SupportsVirtualTerminal)

    Write-Host ''
    if ($supportsAnsi) {
        $esc = [char]27
        # Gradient: theme accent #3DF5A0 (top) -> darker green #1EA86C (bottom)
        $gradient = @('61;245;160', '55;230;150', '49;214;139', '42;199;129', '36;183;119', '30;168;108')
        for ($i = 0; $i -lt $logo.Count; $i++) {
            Write-Host "$esc[1m$esc[38;2;$($gradient[$i])m$($logo[$i])$esc[0m"
        }
        # Rules use the theme's secondary green #2BD389
        Write-Host "$esc[38;2;43;211;137m$rule$esc[0m"
        Write-Host "$esc[1m$esc[97m$centered$esc[0m"
        Write-Host "$esc[38;2;43;211;137m$rule$esc[0m"
    } else {
        foreach ($line in $logo) { Write-Host $line -ForegroundColor Green }
        Write-Host $rule -ForegroundColor DarkGreen
        Write-Host $centered -ForegroundColor White
        Write-Host $rule -ForegroundColor DarkGreen
    }
    Write-Host ''
}
$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "Utilities",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password is a password manager that allows you to store and manage your passwords securely.",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password",
    "foss": false
  },
  "WPFInstall7zip": {
    "category": "Utilities",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstallabdownloadmanager": {
    "category": "Utilities",
    "choco": "ab-download-manager",
    "content": "AB Download Manager",
    "description": "AB Download Manager is an open-source download accelerator and manager with multi-threaded downloads, queue scheduling, speed limiting, and browser integration.",
    "link": "https://abdownloadmanager.com/",
    "winget": "amir1376.ABDownloadManager",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "Document",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit",
    "foss": false
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner",
    "foss": false
  },
  "WPFInstallaimp": {
    "category": "Multimedia Tools",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP",
    "foss": false
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "Utilities",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk",
    "foss": false
  },
  "WPFInstallaudacity": {
    "category": "Multimedia Tools",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "Microsoft Tools",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "This utility shows you what programs are configured to run during system bootup or login.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns",
    "foss": false
  },
  "WPFInstallrdcman": {
    "category": "Microsoft Tools",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan",
    "foss": false
  },
  "WPFInstallautohotkey": {
    "category": "Utilities",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallbattlenet": {
    "category": "Games",
    "choco": "na",
    "winget": "Blizzard.BattleNet",
    "content": "Battle.net",
    "description": "Battle.net is a launcher for games created and developed by Activision Blizzard",
    "link": "https://battle.net",
    "foss": false
  },
  "WPFInstallbitwarden": {
    "category": "Utilities",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "Multimedia Tools",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "Browsers",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbruno": {
    "category": "Development",
    "choco": "bruno",
    "content": "Bruno",
    "description": "Bruno is a local-first API client that stores collections as plain text files for version control and collaboration.",
    "link": "https://www.usebruno.com/",
    "winget": "Bruno.Bruno",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "Utilities",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallblurautoclicker": {
    "category": "Utilities",
    "choco": "na",
    "content": "BlurAutoClicker",
    "description": "An Auto-clicker with a few advanced features and generally better performance than popular alternatives.",
    "link": "https://blur009.vercel.app/projects/blur-autoclicker/",
    "winget": "Blur009.BlurAutoClicker",
    "foss": true
  },
  "WPFInstallcalibre": {
    "category": "Multimedia Tools",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "Games",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu is a highly experimental software to emulate Wii U applications on PC.",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatgpt": {
    "category": "Development",
    "choco": "na",
    "content": "ChatGPT Desktop",
    "description": "The official ChatGPT desktop app for Windows, distributed through the Microsoft Store.",
    "link": "https://openai.com/chatgpt/download/",
    "winget": "msstore:9NT1R1C2HH7J",
    "foss": false
  },
  "WPFInstallchatterino": {
    "category": "Communications",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "Browsers",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome",
    "foss": false
  },
  "WPFInstallchromium": {
    "category": "Browsers",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
    "link": "https://www.chromium.org/",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallcinebenchr23": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "Cinebench R23",
    "description": "Cinebench R23 is a benchmark tool for comparing CPU rendering performance across systems.",
    "link": "https://www.maxon.net/en/cinebench",
    "winget": "Maxon.CinebenchR23",
    "foss": false
  },
  "WPFInstallclaude": {
    "category": "Development",
    "choco": "claude",
    "content": "Claude Desktop",
    "description": "Anthropic's Claude desktop application for focused AI-assisted work and chat.",
    "link": "https://claude.ai/download",
    "winget": "Anthropic.Claude",
    "foss": false
  },
  "WPFInstallclaude-code": {
    "category": "Development",
    "choco": "claude-code",
    "content": "Claude Code",
    "description": "Anthropic's agentic coding tool for terminal and IDE development workflows.",
    "link": "https://code.claude.com/",
    "winget": "Anthropic.ClaudeCode",
    "foss": false
  },
  "WPFInstallcmake": {
    "category": "Development",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcodex": {
    "category": "Development",
    "choco": "codex",
    "content": "Codex",
    "description": "Codex CLI is an OpenAI coding agent that runs locally in your terminal.",
    "link": "https://developers.openai.com/codex/cli",
    "winget": "OpenAI.Codex",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "Pro Tools",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer's hardware components, including the CPU, memory, and motherboard.",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z",
    "foss": false
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "Utilities",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "Utilities",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstallcursor": {
    "category": "Development",
    "choco": "cursoride",
    "content": "Cursor",
    "description": "AI-powered code editor (VS Code-based) with agentic coding features and integrated AI assistance for development workflows.",
    "link": "https://cursor.com/",
    "winget": "Anysphere.Cursor",
    "foss": false
  },
  "WPFInstallddu": {
    "category": "Pro Tools",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "Communications",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
    "link": "https://discord.com/",
    "winget": "Discord.Discord",
    "foss": false
  },
  "WPFInstalldismtools": {
    "category": "Microsoft Tools",
    "choco": "dismtools",
    "content": "DISMTools",
    "description": "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "Microsoft Tools",
    "choco": "ntlite-free",
    "content": "NTLite",
    "description": "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite",
    "foss": false
  },
  "WPFInstalldorion": {
    "category": "Communications",
    "choco": "dorion",
    "content": "Dorion",
    "description": "Tiny alternative Discord client with a smaller footprint, snappier startup, themes, plugins and more!",
    "link": "https://spikehd.dev/projects/dorion/",
    "winget": "SpikeHD.Dorion",
    "foss": true
  },
  "WPFInstalldockerdesktop": {
    "category": "Development",
    "choco": "docker-desktop",
    "content": "Docker Desktop",
    "description": "Docker Desktop provides a local environment for building, running, and testing containerized applications on Windows.",
    "link": "https://www.docker.com/products/docker-desktop/",
    "winget": "Docker.DockerDesktop",
    "foss": false
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft Tools",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6",
    "foss": true
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft Tools",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8",
    "foss": true
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft Tools",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9",
    "foss": true
  },
  "WPFInstalldotnet10": {
    "category": "Microsoft Tools",
    "choco": "dotnet-10.0-runtime",
    "content": ".NET Desktop Runtime 10",
    "description": ".NET Desktop Runtime 10 is a runtime environment required for running applications developed with .NET 10.",
    "link": "https://dotnet.microsoft.com/download/dotnet/10.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.10",
    "foss": true
  },
  "WPFInstalldropbox": {
    "category": "Utilities",
    "choco": "dropbox",
    "content": "Dropbox",
    "description": "Dropbox is a cloud storage client for syncing files, sharing content, and keeping documents available across devices.",
    "link": "https://www.dropbox.com/desktop",
    "winget": "Dropbox.Dropbox",
    "foss": false
  },
  "WPFInstalleaapp": {
    "category": "Games",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App is a platform for accessing and playing Electronic Arts games.",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop",
    "foss": false
  },
  "WPFInstalleartrumpet": {
    "category": "Multimedia Tools",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "Browsers",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge",
    "foss": false
  },
  "WPFInstalles-de": {
    "category": "Games",
    "choco": "",
    "content": "EmulationStation Desktop Edition",
    "_comment": "This and emulationstation are two completely different things. ES-DE is your frontend for everything and has its own set of emulators. Emulationstation is a graphical frontend for RetroArch.",
    "description": "EmulationStation Desktop Edition is a frontend for browsing and launching games from your multi-platform game collection.",
    "link": "https://es-de.org/",
    "winget": "ES-DE.EmulationStation-DE",
    "foss": true
  },
  "WPFInstallenteauth": {
    "category": "Utilities",
    "choco": "ente-auth",
    "content": "Ente Auth",
    "description": "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "Games",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher",
    "foss": false
  },
  "WPFInstallfiles": {
    "category": "Utilities",
    "choco": "files",
    "content": "Files",
    "description": "Alternative file explorer.",
    "link": "https://files.community",
    "winget": "FilesCommunity.Files",
    "foss": true
  },
  "WPFInstallfileconverter": {
    "category": "Multimedia Tools",
    "choco": "file-converter",
    "content": "File Converter",
    "description": "File Converter converts and compresses files from the Windows Explorer context menu.",
    "link": "https://file-converter.io/",
    "winget": "AdrienAllard.FileConverter",
    "foss": true
  },
  "WPFInstallfirefox": {
    "category": "Browsers",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "Browsers",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallfloorp": {
    "category": "Browsers",
    "choco": "floorp",
    "content": "Floorp",
    "description": "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "Utilities",
    "choco": "f.lux",
    "content": "F.lux",
    "description": "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux",
    "foss": false
  },
  "WPFInstallfoobar": {
    "category": "Multimedia Tools",
    "choco": "foobar2000",
    "content": "foobar2000 (Music Player)",
    "description": "foobar2000 is a highly customizable and extensible music player for Windows, known for its modular design and advanced features.",
    "link": "https://www.foobar2000.org/",
    "winget": "PeterPawlowski.foobar2000",
    "foss": false
  },
  "WPFInstallfnm": {
    "category": "Development",
    "choco": "fnm",
    "content": "Fast Node Manager",
    "description": "Fast Node Manager (fnm) is a fast, cross-platform tool for installing and switching between Node.js versions.",
    "link": "https://github.com/Schniz/fnm",
    "winget": "Schniz.fnm",
    "foss": true
  },
  "WPFInstallfoxpdfreader": {
    "category": "Document",
    "choco": "foxitreader",
    "content": "Foxit PDF Reader",
    "description": "Foxit PDF Reader is a free PDF viewer with a familiar ribbon-style interface.",
    "link": "https://www.foxit.com/pdf-reader/",
    "winget": "Foxit.FoxitReader",
    "foss": false
  },
  "WPFInstallgeforcenow": {
    "category": "Games",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow",
    "foss": false
  },
  "WPFInstallgimp": {
    "category": "Multimedia Tools",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "Development",
    "choco": "git",
    "content": "Git",
    "description": "Git is a distributed version control system widely used for tracking changes in source code during software development.",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgitextensions": {
    "category": "Development",
    "choco": "gitextensions",
    "content": "Git Extensions",
    "description": "Git Extensions is a graphical Git client for Windows with repository, history, and commit management tools.",
    "link": "https://gitextensions.github.io/",
    "winget": "GitExtensionsTeam.GitExtensions",
    "foss": true
  },
  "WPFInstallgithubcli": {
    "category": "Development",
    "choco": "gh",
    "content": "GitHub CLI",
    "description": "GitHub CLI brings pull requests, issues, releases, and other GitHub workflows to the terminal.",
    "link": "https://cli.github.com/",
    "winget": "GitHub.cli",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "Development",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "Games",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy",
    "foss": false
  },
  "WPFInstallgolang": {
    "category": "Development",
    "choco": "golang",
    "content": "Go",
    "description": "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "Utilities",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "File syncing across devices all tied to your Google account.",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive",
    "foss": false
  },
  "WPFInstallgpuz": {
    "category": "Pro Tools",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z provides detailed information about your graphics card and GPU.",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z",
    "foss": false
  },
  "WPFInstallgsudo": {
    "category": "Pro Tools",
    "choco": "gsudo",
    "content": "gsudo",
    "description": "gsudo is a sudo equivalent for Windows. It allows you to run commands with elevated administrative privileges directly within the current console window.",
    "link": "https://github.com/gerardog/gsudo",
    "winget": "gerardog.gsudo",
    "foss": true
  },
  "WPFInstallhelium": {
    "category": "Browsers",
    "choco": "helium",
    "content": "Helium",
    "description": "Private, fast, and honest web browser.",
    "link": "https://helium.computer",
    "winget": "ImputNet.Helium",
    "foss": true
  },
  "WPFInstallhugo": {
    "category": "Development",
    "choco": "hugo-extended",
    "content": "Hugo",
    "description": "The world's fastest framework for building websites.",
    "link": "https://gohugo.io",
    "winget": "Hugo.Hugo.Extended",
    "foss": true
  },
  "WPFInstallhandbrake": {
    "category": "Multimedia Tools",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "Games",
    "choco": "heroic-games-launcher",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "Pro Tools",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO",
    "foss": false
  },
  "WPFInstallhwmonitor": {
    "category": "Pro Tools",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor",
    "foss": false
  },
  "WPFInstallimhex": {
    "category": "Pro Tools",
    "choco": "imhex",
    "content": "ImHex",
    "description": "ImHex is a free and open-source hex editor for reverse engineers and programmers, featuring a custom pattern language for decoding binary formats, a disassembler, and data analysis tools.",
    "link": "https://imhex.werwolv.net/",
    "winget": "WerWolv.ImHex",
    "foss": true
  },
  "WPFInstallimageglass": {
    "category": "Multimedia Tools",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallinternetdownloadmanager": {
    "category": "Utilities",
    "choco": "internet-download-manager",
    "content": "Internet Download Manager",
    "description": "Internet Download Manager is a download manager for accelerating, resuming, and scheduling file downloads.",
    "link": "https://www.internetdownloadmanager.com/",
    "winget": "Tonec.InternetDownloadManager",
    "foss": false
  },
  "WPFInstallirfanview": {
    "category": "Multimedia Tools",
    "choco": "irfanview",
    "content": "IrfanView",
    "description": "IrfanView is a lightweight, fast, and free image viewer and editor. Supports multiple formats, batch processing, and powerful plugins.",
    "link": "https://irfanview.com/",
    "winget": "IrfanSkiljan.IrfanView",
    "foss": false
  },
  "WPFInstallitch": {
    "category": "Games",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io is a digital distribution platform for indie games and creative projects.",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "Multimedia Tools",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes",
    "foss": false
  },
  "WPFInstalljava8": {
    "category": "Development",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "Development",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "Development",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS)",
    "description": "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "Selfhosted Tools",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "Development",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox",
    "foss": false
  },
  "WPFInstalljpegview": {
    "category": "Utilities",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF, and TIFF images with a minimal GUI.",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstalljoplin": {
    "category": "Document",
    "choco": "joplin",
    "content": "Joplin",
    "description": "Joplin is an open-source note-taking and to-do application with synchronization capabilities.",
    "link": "https://joplinapp.org/",
    "winget": "Joplin.Joplin",
    "foss": true
  },
  "WPFInstallkeepassxc": {
    "category": "Utilities",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC is a modern, secure, and open-source password manager that stores and manages your most sensitive information. You can run KeePassXC on Windows, macOS, and Linux systems. KeePassXC is for people with extremely high demands of secure personal data management. It saves many different types of information, such as usernames, passwords, URLs, attachments, and notes in an offline, encrypted file that can be stored in any location, including private and public cloud solutions. For easy identification and management, user-defined titles and icons can be specified for entries. In addition, entries are sorted into customizable groups. An integrated search function allows you to use advanced patterns to easily find any entry in your database. A customizable, fast, and easy-to-use password generator utility allows you to create passwords with any combination of characters or easy to remember passphrases.",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "Multimedia Tools",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard",
    "foss": false
  },
  "WPFInstallkodi": {
    "category": "Selfhosted Tools",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "Development",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "Simple terminal UI for git commands.",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "Document",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "Browsers",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
    "link": "https://librewolf.net/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "Selfhosted Tools",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "An open-source cross-platform alternative to AirDrop.",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstallmpc-qt": {
    "category": "Multimedia Tools",
    "choco": "mpc-qt",
    "content": "mpc-qt",
    "description": "Media Player Classic Qute Theater",
    "link": "https://mpc-qt.github.io",
    "winget": "mpc-qt.mpc-qt",
    "foss": true
  },
  "WPFInstallmpv": {
    "category": "Multimedia Tools",
    "content": "mpv",
    "description": "mpv is a free, open source, and cross-platform media player supporting a wide variety of media formats, codecs, and subtitle types.",
    "link": "https://mpv.io/",
    "winget": "shinchiro.mpv",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "Communications",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element is a client for Matrix; an open network for secure, decentralized communication.",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallminitoolpartitionwizard": {
    "category": "Utilities",
    "choco": "partitionwizard",
    "content": "MiniTool Partition Wizard",
    "description": "Comprehensive free partition manager that performs advanced operations Windows natively cannot, such as merging partitions, converting file systems, and organizing disk capacity.",
    "link": "https://www.partitionwizard.com/",
    "winget": "MiniTool.PartitionWizard.Free",
    "foss": false
  },
  "WPFInstallmodrinth": {
    "category": "Games",
    "choco": "modrinth-app",
    "content": "Modrinth App",
    "description": "Modrinth App is a desktop application for managing Minecraft mods and modpacks.",
    "link": "https://modrinth.com/app",
    "winget": "Modrinth.ModrinthApp",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "Selfhosted Tools",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "Multimedia Tools",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
    "link": "https://mpc-hc.org/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "Utilities",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "A Tool to Redirect News, Search, Widgets, Weather, and More to your default browser.",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "Pro Tools",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner is a graphics card overclocking utility with advanced features.",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner",
    "foss": false
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "This is the VPN client software for the Mullvad VPN service.",
    "link": "https://mullvad.net/",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallnomacs": {
    "category": "Multimedia Tools",
    "choco": "nomacs",
    "content": "nomacs",
    "description": "nomacs is a free, open-source image viewer, which supports multiple platforms. You can use it for viewing all common image formats, including RAW and .psd images.",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnanazip": {
    "category": "Utilities",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip is a fast and efficient file compression and decompression tool.",
    "link": "https://nanazip.org",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "Selfhosted Tools",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird is an open-source alternative comparable to TailScale that can be connected to a self-hosted server.",
    "link": "https://netbird.io/",
    "winget": "Netbird.Netbird",
    "foss": true
  },
  "WPFInstalltailscale": {
    "category": "Pro Tools",
    "choco": "tailscale",
    "content": "Tailscale",
    "description": "The Tailscale client allows you to connect all your devices using WireGuard\u00ae, without the hassle. Tailscale makes it as easy as installing an app and signing in.",
    "link": "https://tailscale.com/",
    "winget": "Tailscale.Tailscale",
    "foss": false
  },
  "WPFInstallnaps2": {
    "category": "Document",
    "choco": "naps2",
    "content": "NAPS2 (Scanner)",
    "description": "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "Development",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim",
    "foss": true
  },
  "WPFInstallnextclouddesktop": {
    "category": "Selfhosted Tools",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "Development",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS is a JavaScript runtime built on Chrome's V8 JavaScript engine for building server-side and networking applications.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "Development",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS",
    "foss": true
  },
  "WPFInstallpnpm": {
    "category": "Development",
    "content": "pnpm",
    "description": "pnpm is a fast and disk space efficient package manager for JavaScript and Node.js applications.",
    "link": "https://pnpm.io/",
    "winget": "pnpm.pnpm",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "Development",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "Microsoft Tools",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "Utilities",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall",
    "foss": false
  },
  "WPFInstallobs": {
    "category": "Multimedia Tools",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "Document",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian is a powerful note-taking and knowledge management application.",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian",
    "foss": false
  },
  "WPFInstallokular": {
    "category": "Document",
    "choco": "okular",
    "content": "Okular",
    "description": "Okular is a versatile document viewer with advanced features.",
    "link": "https://okular.kde.org/",
    "winget": "KDE.Okular",
    "foss": true
  },
  "WPFInstallonedrive": {
    "category": "Microsoft Tools",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive",
    "foss": false
  },
  "WPFInstallonlyoffice": {
    "category": "Document",
    "choco": "onlyoffice",
    "content": "ONLYOFFICE Desktop",
    "description": "ONLYOFFICE Desktop is a comprehensive office suite for document editing and collaboration.",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "Utilities",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker",
    "foss": false
  },
  "WPFInstallopencode": {
    "category": "Development",
    "choco": "opencode",
    "content": "OpenCode",
    "description": "OpenCode is an open-source AI coding agent built for the terminal. It is provider-agnostic and supports local and hosted AI models.",
    "link": "https://opencode.ai/",
    "winget": "SST.opencode",
    "foss": true
  },
  "WPFInstallopenrgb": {
    "category": "Utilities",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect is a VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": false
  },
  "WPFInstallOVirtualBox": {
    "category": "Utilities",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "Utilities",
    "choco": "na",
    "content": "Policy Plus",
    "description": "Local Group Policy Editor plus more, for all Windows editions.",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallprocessexplorer": {
    "category": "Microsoft Tools",
    "choco": "procexp",
    "content": "Process Explorer",
    "description": "Process Explorer is a task manager and system monitor.",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer",
    "foss": false
  },
  "WPFInstallPaintdotnet": {
    "category": "Multimedia Tools",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet",
    "foss": false
  },
  "WPFInstallparsec": {
    "category": "Utilities",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec",
    "foss": false
  },
  "WPFInstallpeazip": {
    "category": "Utilities",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallpdf-xchange": {
    "category": "Document",
    "choco": "pdfxchangeeditor",
    "content": "PDF-XChange Editor",
    "description": "A comprehensive Windows-based software suite and editor for creating, viewing, editing, annotating, and signing PDF files.",
    "link": "https://www.pdf-xchange.com/",
    "winget": "TrackerSoftware.PDF-XChangeEditor",
    "foss": false
  },
  "WPFInstallpdf24creator": {
    "category": "Document",
    "choco": "pdf24",
    "content": "PDF24 Creator",
    "description": "Free and easy-to-use online/desktop PDF tools that make you more productive",
    "link": "https://tools.pdf24.org/en/creator",
    "winget": "geeksoftwareGmbH.PDF24Creator",
    "foss": false
  },
  "WPFInstallpdfgear": {
    "category": "Document",
    "choco": "pdfgear",
    "content": "PDFgear",
    "description": "PDFgear is a piece of full-featured PDF management software for Windows, macOS, and mobile, and it's completely free to use.",
    "link": "https://www.pdfgear.com/",
    "winget": "PDFgear.PDFgear",
    "foss": false
  },
  "WPFInstallpdfsam": {
    "category": "Document",
    "choco": "pdfsam",
    "content": "PDFsam Basic",
    "description": "PDFsam Basic is a free and open-source tool for splitting, merging, and rotating PDF files.",
    "link": "https://pdfsam.org/",
    "winget": "PDFsam.PDFsam",
    "foss": true
  },
  "WPFInstallplaynite": {
    "category": "Games",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite is an open-source video game library manager with one simple goal: To provide a unified interface for all of your games.",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "Selfhosted Tools",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer",
    "foss": false
  },
  "WPFInstallplexdesktop": {
    "category": "Selfhosted Tools",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows is the front end for Plex Media Server.",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex",
    "foss": false
  },
  "WPFInstallposh": {
    "category": "Development",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh is a cross-platform prompt theme engine for any shell.",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpostman": {
    "category": "Development",
    "choco": "postman",
    "content": "Postman",
    "description": "Postman is an API platform and desktop client for designing, testing, documenting, and collaborating on APIs.",
    "link": "https://www.postman.com/downloads/",
    "winget": "Postman.Postman",
    "foss": false
  },
  "WPFInstallpowershell": {
    "category": "Microsoft Tools",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft Tools",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "Games",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher is an open-source Minecraft launcher with the ability to manage multiple instances, accounts, and mods.",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "Utilities",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso",
    "foss": false
  },
  "WPFInstallprotonauth": {
    "category": "Utilities",
    "choco": "protonauth",
    "content": "Proton Authenticator",
    "description": "2FA app from Proton to securely sync and backup 2FA codes.",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprotonmail": {
    "category": "Communications",
    "choco": "protonmail",
    "content": "Proton Mail",
    "description": "Proton Mail is an end-to-end encrypted email service by Proton, protecting your privacy with zero-access encryption.",
    "link": "https://proton.me/mail",
    "winget": "Proton.ProtonMail",
    "foss": true
  },
  "WPFInstallprotondrive": {
    "category": "Utilities",
    "choco": "protondrive",
    "content": "Proton Drive",
    "description": "Proton Drive is an end-to-end encrypted Swiss vault for your files that protects your data.",
    "link": "https://proton.me/drive",
    "winget": "Proton.ProtonDrive",
    "foss": true
  },
  "WPFInstallprotonpass": {
    "category": "Utilities",
    "choco": "protonpass",
    "content": "Proton Pass",
    "description": "Proton Pass is a cloud-based password manager with end-to-end encryption and unique email aliases.",
    "link": "https://proton.me/pass",
    "winget": "Proton.ProtonPass",
    "foss": true
  },
  "WPFInstallprotonvpn": {
    "category": "Pro Tools",
    "choco": "protonvpn",
    "content": "Proton VPN",
    "description": "Proton VPN is a no-logs VPN service that protects your privacy online with features like Secure Core and Tor over VPN.",
    "link": "https://protonvpn.com/",
    "winget": "Proton.ProtonVPN",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft Tools",
    "choco": "procmon",
    "content": "Process Monitor",
    "description": "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor",
    "foss": false
  },
  "WPFInstallpstools": {
    "category": "Microsoft Tools",
    "choco": "pstools",
    "content": "PsTools",
    "description": "Microsoft Sysinternals PsTools provides utilities for managing local and remote Windows systems and monitoring processes. PsExec can run processes under the SYSTEM account when the user has local administrative rights on the target system.",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/pstools",
    "winget": "Microsoft.Sysinternals.PsTools",
    "foss": false
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "Development",
    "choco": "python",
    "content": "Python3",
    "description": "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "Utilities",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstallqownnotes": {
    "category": "Document",
    "choco": "qownnotes",
    "content": "QOwnNotes",
    "description": "QOwnNotes is a free open-source note-taking app with Nextcloud/ownCloud integration.",
    "link": "https://www.qownnotes.org/",
    "winget": "pbek.QOwnNotes",
    "foss": true
  },
  "WPFInstallqtox": {
    "category": "Communications",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "Utilities",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller",
    "foss": false
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "Utilities",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller",
    "foss": false
  },
  "WPFInstallrufus": {
    "category": "Pro Tools",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "Development",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "Utilities",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "Multimedia Tools",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "Utilities",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell",
    "foss": false
  },
  "WPFInstallsysteminformer": {
    "category": "Pro Tools",
    "choco": "systeminformer",
    "content": "System Informer",
    "description": "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsignal": {
    "category": "Communications",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "Utilities",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb",
    "foss": false
  },
  "WPFInstallsimplenote": {
    "category": "Document",
    "choco": "simplenote",
    "content": "Simplenote",
    "description": "Simplenote is an easy way to keep notes, lists, ideas and more.",
    "link": "https://simplenote.com/",
    "winget": "Automattic.Simplenote",
    "foss": true
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "Communications",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack",
    "foss": false
  },
  "WPFInstallstartallback": {
    "category": "Utilities",
    "choco": "StartAllBack",
    "content": "StartAllBack",
    "description": "StartAllBack restores and improves Windows taskbar, Start menu, File Explorer, and shell UI behavior.",
    "link": "https://www.startallback.com/",
    "winget": "StartIsBack.StartAllBack",
    "foss": false
  },
  "WPFInstallstarship": {
    "category": "Development",
    "choco": "starship",
    "content": "Starship (Shell Prompt)",
    "description": "Starship is a fast, customizable, cross-platform prompt for PowerShell and other shells.",
    "link": "https://starship.rs/",
    "winget": "Starship.Starship",
    "foss": true
  },
  "WPFInstallsteam": {
    "category": "Games",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam",
    "foss": false
  },
  "WPFInstallroblox": {
    "category": "Games",
    "choco": "na",
    "content": "Roblox",
    "description": "Roblox is a platform and game creation system that allows users to create and play games developed by the community.",
    "link": "https://www.roblox.com/",
    "winget": "Roblox.Roblox",
    "foss": false
  },
  "WPFInstallsublimetext": {
    "category": "Development",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text is a sophisticated text editor for code, markup, and prose.",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4",
    "foss": false
  },
  "WPFInstallsumatra": {
    "category": "Document",
    "choco": "sumatrapdf",
    "content": "Sumatra PDF",
    "description": "Sumatra PDF is a lightweight and fast PDF viewer with minimalistic design.",
    "link": "https://www.sumatrapdfreader.org/free-pdf-reader.html",
    "winget": "SumatraPDF.SumatraPDF",
    "foss": true
  },
  "WPFInstallsunshine": {
    "category": "Selfhosted Tools",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
    "link": "https://app.lizardbyte.dev/Sunshine/",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstallsynctrayzor": {
    "category": "Selfhosted Tools",
    "choco": "synctrayzor",
    "content": "SyncTrayzor",
    "description": "SyncTrayzor is a Windows tray utility that bundles and wraps Syncthing, making it behave like a native application to easily manage and monitor file synchronization.",
    "link": "https://github.com/GermanCoding/SyncTrayzor",
    "winget": "GermanCoding.SyncTrayzor"
  },
  "WPFInstallsyncthing": {
    "category": "Selfhosted Tools",
    "choco": "syncthing",
    "content": "Syncthing (CLI / Web UI)",
    "description": "Syncthing is a decentralized, peer-to-peer file synchronization tool that securely syncs files directly across devices without cloud servers, managed via a local web interface.",
    "link": "https://syncthing.net/",
    "winget": "Syncthing.Syncthing",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "Microsoft Tools",
    "choco": "tcpview",
    "content": "TCPView",
    "description": "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView",
    "foss": false
  },
  "WPFInstallteams": {
    "category": "Communications",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams",
    "foss": false
  },
  "WPFInstallteamviewer": {
    "category": "Utilities",
    "choco": "teamviewer",
    "content": "TeamViewer",
    "description": "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer",
    "foss": false
  },
  "WPFInstallteamspeak3": {
    "category": "Communications",
    "choco": "teamspeak",
    "content": "TeamSpeak 3",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient",
    "foss": false
  },
  "WPFInstallteamspeak6": {
    "category": "Communications",
    "choco": "na",
    "content": "TeamSpeak 6",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient.Beta.6",
    "foss": false
  },
  "WPFInstalltelegram": {
    "category": "Communications",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "Microsoft Tools",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "Communications",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "Communications",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltor": {
    "category": "Browsers",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "Utilities",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander",
    "foss": false
  },
  "WPFInstalltreesize": {
    "category": "Utilities",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free",
    "foss": false
  },
  "WPFInstallttaskbar": {
    "category": "Utilities",
    "choco": "translucenttb",
    "content": "TranslucentTB",
    "description": "TranslucentTB is a tool that allows you to customize the transparency of the Windows Taskbar.",
    "link": "https://translucenttb.github.io",
    "winget": "CharlesMilette.TranslucentTB",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "Games",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect is Ubisoft's digital distribution and online gaming service, providing access to Ubisoft's games and services.",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect",
    "foss": false
  },
  "WPFInstallungoogled": {
    "category": "Browsers",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled Chromium",
    "description": "Ungoogled Chromium is a version of Chromium without Google's integration for enhanced privacy and control.",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "Development",
    "choco": "unity-hub",
    "content": "Unity Game Engine",
    "description": "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub",
    "foss": false
  },
  "WPFInstallvagrant": {
    "category": "Development",
    "choco": "vagrant",
    "content": "Vagrant",
    "description": "Vagrant builds and manages reproducible virtual machine development environments from declarative configuration.",
    "link": "https://developer.hashicorp.com/vagrant",
    "winget": "Hashicorp.Vagrant",
    "foss": false
  },
  "WPFInstalleverything": {
    "category": "Utilities",
    "choco": "everything",
    "content": "Everything",
    "description": "Everything is a search engine that locates files and folders by filename instantly for Windows. Unlike Windows search Everything initially displays every file and folder on your computer (hence the name Everything). You type in a search filter to limit what files and folders are displayed.",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything",
    "foss": false
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86",
    "foss": false
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft Tools",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64",
    "foss": false
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "Communications",
    "choco": "na",
    "content": "Vesktop",
    "description": "A cross-platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
    "link": "https://vesktop.dev",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "Communications",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber",
    "foss": false
  },
  "WPFInstallvisualstudio2022": {
    "category": "Development",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community",
    "foss": false
  },
  "WPFInstallvisualstudio2026": {
    "category": "Development",
    "choco": "visualstudio2026community",
    "content": "Visual Studio 2026",
    "description": "Visual Studio 2026 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.Community",
    "foss": false
  },
  "WPFInstallvivaldi": {
    "category": "Browsers",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi",
    "foss": false
  },
  "WPFInstallvlc": {
    "category": "Multimedia Tools",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "Games",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer",
    "foss": false
  },
  "WPFInstallvscode": {
    "category": "Development",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "Development",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft's VS Code.",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "Browsers",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwhatsapp": {
    "category": "Communications",
    "choco": "na",
    "content": "WhatsApp Desktop",
    "description": "WhatsApp Desktop is the official Windows desktop messaging app from Meta, distributed through the Microsoft Store.",
    "link": "https://www.whatsapp.com/download",
    "winget": "msstore:9NKSQGP7F2NH",
    "foss": false
  },
  "WPFInstallwingetui": {
    "category": "Utilities",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI is a GUI for WinGet, Chocolatey, and other Windows CLI package managers.",
    "link": "https://devolutions.net/unigetui/",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "Utilities",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR",
    "foss": false
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwiztree": {
    "category": "Utilities",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree",
    "foss": false
  },
  "WPFInstallxeheditor": {
    "category": "Utilities",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD",
    "foss": false
  },
  "WPFInstallxournal": {
    "category": "Document",
    "choco": "xournalplusplus",
    "content": "Xournal++",
    "description": "Xournal++ is an open-source handwriting notetaking software with PDF annotation capabilities.",
    "link": "https://xournalpp.github.io/",
    "winget": "Xournal++.Xournal++",
    "foss": true
  },
  "WPFInstallyarn": {
    "category": "Development",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "Communications",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom",
    "foss": false
  },
  "WPFInstalluv": {
    "category": "Development",
    "choco": "uv",
    "content": "uv",
    "description": "uv is a fast Python package and project manager written in Rust.",
    "link": "https://docs.astral.sh/uv/getting-started/installation/",
    "winget": "astral-sh.uv",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "Utilities",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC is a free and open-source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there.",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "Utilities",
    "choco": "glazewm",
    "content": "GlazeWM",
    "description": "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar.",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallOverwolf": {
    "category": "Games",
    "content": "CurseForge",
    "description": "CurseForge is a desktop application for managing mods and modpacks across multiple games, powered by Overwolf.",
    "link": "https://www.overwolf.com/app/overwolf-curseforge",
    "winget": "Overwolf.CurseForge",
    "foss": false
  },
  "WPFInstallOFGB": {
    "category": "Utilities",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "GUI Tool to remove ads from various places around Windows 11",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallZenBrowser": {
    "category": "Browsers",
    "choco": "na",
    "content": "Zen Browser",
    "description": "The modern, privacy-focused, performance-driven browser built on Firefox.",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "Development",
    "choco": "zed",
    "content": "Zed",
    "description": "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  },
  "WPFInstallzotero": {
    "category": "Document",
    "choco": "zotero",
    "content": "Zotero",
    "description": "Zotero is a free, easy-to-use tool to help you collect, organize, cite, and share your research materials.",
    "link": "https://www.zotero.org/",
    "winget": "DigitalScholar.Zotero",
    "foss": true
  },
  "WPFInstalldeskflow": {
    "category": "Utilities",
    "choco": "deskflow",
    "content": "Deskflow",
    "description": "Deskflow is a free and open-source software KVM that lets you share a single keyboard and mouse across multiple computers.",
    "link": "https://github.com/deskflow/deskflow",
    "winget": "Deskflow.Deskflow",
    "foss": true
  },
  "WPFInstallRuby": {
    "category": "Development",
    "choco": "ruby",
    "winget": "RubyInstallerTeam.Ruby.4.0",
    "description": "A Ruby language execution environment with a MSYS2 installation.",
    "content": "Ruby",
    "link": "https://rubyinstaller.org/",
    "foss": true
  },
  "WPFInstallLua": {
    "category": "Development",
    "choco": "lua",
    "winget": "rjpcomputing.luaforwindows",
    "description": "A 'batteries included environment' for the Lua scripting language on Windows.",
    "content": "Lua",
    "link": "https://github.com/rjpcomputing/luaforwindows",
    "foss": true
  },
  "WPFInstallCloudflareWARP": {
    "category": "Utilities",
    "choco": "warp",
    "winget": "Cloudflare.Warp",
    "description": "WARP is a freemium VPN service provided by Cloudflare. Includes usage of Cloudflare's DNS",
    "content": "Cloudflare WARP",
    "link": "https://one.one.one.one",
    "foss": false
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "Installa/Aggiorna applicazioni",
    "Category": "____Azioni",
    "Type": "Button",
    "Order": "1",
    "Description": "Installa o aggiorna le applicazioni selezionate"
  },
  "WPFUninstall": {
    "Content": "Disinstalla applicazioni",
    "Category": "____Azioni",
    "Type": "Button",
    "Order": "2",
    "Description": "Disinstalla le applicazioni selezionate"
  },
  "WPFInstallUpgrade": {
    "Content": "Aggiorna applicazioni",
    "Category": "____Azioni",
    "Type": "Button",
    "Order": "3",
    "Description": "Mostra gli aggiornamenti disponibili per le applicazioni installate e scegli quali installare"
  },
  "WingetRadioButton": {
    "Content": "WinGet",
    "Category": "__Gestore pacchetti",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "Usa WinGet per la gestione dei pacchetti"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__Gestore pacchetti",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "Usa Chocolatey per la gestione dei pacchetti"
  },
  "WPFCollapseAllCategories": {
    "Content": "Comprimi tutte le categorie",
    "Category": "__Selezione",
    "Type": "Button",
    "Order": "1",
    "Description": "Comprimi tutte le categorie di applicazioni"
  },
  "WPFExpandAllCategories": {
    "Content": "Espandi tutte le categorie",
    "Category": "__Selezione",
    "Type": "Button",
    "Order": "2",
    "Description": "Espandi tutte le categorie di applicazioni"
  },
  "WPFClearInstallSelection": {
    "Content": "Azzera selezione",
    "Category": "__Selezione",
    "Type": "Button",
    "Order": "3",
    "Description": "Azzera la selezione delle applicazioni"
  },
  "WPFGetInstalled": {
    "Content": "Mostra app installate",
    "Category": "__Selezione",
    "Type": "Button",
    "Order": "4",
    "Description": "Mostra le applicazioni installate"
  },
  "WPFselectedAppsButton": {
    "Content": "App selezionate: 0",
    "Category": "__Selezione",
    "Type": "Button",
    "Order": "5",
    "Description": "Mostra le applicazioni selezionate"
  },
  "WPFToggleFOSSHighlight": {
    "Content": "Evidenzia FOSS",
    "Category": "__Selezione",
    "Type": "Toggle",
    "Checked": true,
    "Order": "6",
    "Description": "Attiva/disattiva l'evidenziazione verde per le applicazioni FOSS"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "App Microsoft",
    "Content": "Hub di Feedback",
    "Description": "Permette di inviare a Microsoft segnalazioni di problemi, suggerimenti e dati di diagnostica.",
    "Panel": "1",
    "PackageId": "Microsoft.WindowsFeedbackHub",
    "StoreId": "9NBLGGH4R32N"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "App Microsoft",
    "Content": "Richiedi assistenza",
    "Description": "Offre guide di risoluzione dei problemi, documentazione di supporto e il contatto con l'assistenza Microsoft.",
    "Panel": "1",
    "PackageId": "Microsoft.GetHelp",
    "StoreId": "9PKDZBMV1H3T"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "App Microsoft",
    "Content": "Outlook per Windows",
    "Description": "Il nuovo Outlook: posta elettronica, calendario e contatti.",
    "Panel": "1",
    "PackageId": "Microsoft.OutlookForWindows",
    "StoreId": "9NRX63209R7B"
  },
  "WPFAppxMSTeams": {
    "Category": "App Microsoft",
    "Content": "Microsoft Teams",
    "Description": "Messaggistica, videochiamate, condivisione di file e collaborazione.",
    "Panel": "1",
    "PackageId": "MSTeams",
    "StoreId": "XP8BT8DW290MPQ"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Clipchamp",
    "Description": "Editor video semplice da usare, con modelli, effetti e linea temporale.",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp",
    "StoreId": "9P1J8S7CCWWT"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "App Microsoft",
    "Content": "Microsoft 365",
    "Description": "Avvio rapido delle app di Microsoft 365 nel cloud e dei documenti recenti.",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftOfficeHub",
    "StoreId": "9WZDNCRD29V9"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Lettore multimediale",
    "Description": "Riproduce file audio e video locali, con playlist e trasmissione ad altri dispositivi.",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic",
    "StoreId": "9WZDNCRFJ3PT"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "Bing e servizi web",
    "Content": "Ricerca Bing",
    "Description": "Integra la ricerca e i servizi web di Bing nel sistema operativo.",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch",
    "StoreId": "9NZBF4GT040C"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Assistenza rapida",
    "Description": "Permette di ricevere o dare assistenza tecnica remota condividendo lo schermo via Internet.",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist",
    "StoreId": "9P7BP5VNWKX5"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "Strumenti per sviluppatori",
    "Content": "Dev Home",
    "Description": "Dashboard per gli sviluppatori: configurazione dell'ambiente, sincronizzazione dei repository e widget di sistema.",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.DevHome",
    "StoreId": "9N8MHTPHNGVV"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "Ecosistema Microsoft",
    "Content": "Dispositivi mobili",
    "Description": "Gestisce il collegamento in background con i telefoni associati. Rimuoverla pu\u00f2 disattivare le funzioni tra dispositivi delle Impostazioni, come lo schermo del telefono, il trasferimento dei file e l'hotspot.",
    "Panel": "1",
    "PackageId": "MicrosoftWindows.CrossDevice",
    "StoreId": "9NTXGKQ8P7N0"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Microsoft To Do",
    "Description": "Crea e sincronizza attivit\u00e0, elenchi e promemoria.",
    "Panel": "0",
    "PackageId": "Microsoft.Todos",
    "StoreId": "9NBLGGH5R558"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "Strumenti per sviluppatori",
    "Content": "Power Automate",
    "Description": "Automatizza attivit\u00e0 ripetitive del desktop con flussi visuali senza codice.",
    "Panel": "0",
    "PackageId": "Microsoft.PowerAutomateDesktop",
    "StoreId": "9NFTCH6J7FHV"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "Ecosistema Microsoft",
    "Content": "Collegamento al telefono",
    "Description": "Porta sul PC messaggi, notifiche, foto e chiamate del telefono.",
    "Panel": "1",
    "PackageId": "Microsoft.YourPhone",
    "StoreId": "9NMPJ99VJBWV"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Sticky Notes",
    "Description": "Note rapide sul desktop, sincronizzate tra i dispositivi.",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes",
    "StoreId": "9NBLGGH4QGHW"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Registratore di suoni",
    "Description": "Registra e taglia l'audio del microfono.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder",
    "StoreId": "9WZDNCRFHWKN"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Orologio",
    "Description": "Orologi del mondo, sveglie, timer, cronometro e sessioni di concentrazione.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms",
    "StoreId": "9WZDNCRFJ3PR"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Paint",
    "Description": "Disegno e modifica di base delle immagini.",
    "Panel": "0",
    "PackageId": "Microsoft.Paint",
    "StoreId": "9PCFS5B6T72H"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Blocco note",
    "Description": "Editor di testo leggero con le schede, per file di testo e frammenti di codice.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad",
    "StoreId": "9MSMLRH6LZF3"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Strumento di cattura",
    "Description": "Cattura schermate e registrazioni dello schermo, con annotazioni, ritaglio e riconoscimento del testo (OCR).",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch",
    "StoreId": "9MZ95KL8MR0L"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "Bing e servizi web",
    "Content": "Copilot",
    "Description": "L'assistente di intelligenza artificiale di Microsoft per risposte, scrittura e ricerca sul web.",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot",
    "StoreId": "9NHT9RB2F4HD"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Calcolatrice",
    "Description": "Calcoli standard, scientifici, da programmatore e conversioni di unit\u00e0.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator",
    "StoreId": "9WZDNCRFHVN5"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Fotocamera",
    "Description": "Scatta foto e registra video con la webcam o altre fotocamere collegate.",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera",
    "StoreId": "9WZDNCRFJBBG"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Foto",
    "Description": "Organizza, visualizza e ritaglia le immagini, con regolazioni di base e album.",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos",
    "StoreId": "9WZDNCRFJBH4"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "Bing e servizi web",
    "Content": "Notizie",
    "Description": "Notizie del giorno e articoli personalizzati.",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews",
    "StoreId": "9WZDNCRFHVFW"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "Bing e servizi web",
    "Content": "Meteo",
    "Description": "Meteo locale in tempo reale, mappe radar e previsioni.",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather",
    "StoreId": "9WZDNCRFJ3Q2"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox e giochi",
    "Content": "App Xbox",
    "Description": "Raccolta dei giochi, community e PC Game Pass.",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp",
    "StoreId": "9MV0B5HZVK9Z"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox e giochi",
    "Content": "Xbox Game Bar",
    "Description": "Widget durante il gioco, volumi, monitoraggio del sistema e registrazione delle partite.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay",
    "StoreId": "9NZKPSTSNW4P"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox e giochi",
    "Content": "Provider di identit\u00e0 Xbox",
    "Description": "Gestisce l'accesso alla rete Xbox per i giochi collegati. Attenzione: rimuoverlo pu\u00f2 impedire l'accesso con l'account Microsoft anche in giochi e app non Xbox che lo usano.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider",
    "StoreId": "9WZDNCRD1HKW"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox e giochi",
    "Content": "Xbox Speech To Text Overlay",
    "Description": "Sottotitoli in tempo reale e trascrizione vocale per le chat di gioco.",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox e giochi",
    "Content": "Xbox TCUI",
    "Description": "Finestre di accesso all'account usate dai giochi. Attenzione: rimuoverlo pu\u00f2 impedire l'accesso con l'account Microsoft in giochi e app che non richiedono l'app Xbox.",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "Bing e servizi web",
    "Content": "Start Experiences App (Widget)",
    "Description": "Fornisce la bacheca dei widget di Windows, con notizie, meteo, sport e finanza.",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp",
    "StoreId": "9PC1H9VN18CM"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox e giochi",
    "Content": "Microsoft Solitaire Collection",
    "Description": "Giochi di carte Klondike, Spider, FreeCell, Pyramid e TriPeaks, con sfide giornaliere.",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  },
  "WPFAppxMicrosoft_ZuneVideo": {
    "Category": "Utilit\u00e0 e produttivit\u00e0",
    "Content": "Film e TV",
    "Description": "Il lettore video predefinito, con il negozio per acquistare o noleggiare film.",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneVideo",
    "StoreId": "9WZDNCRFJ3P2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "BenchmarkEligible": true,
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844",
    "DohTemplate": "https://dns.google/dns-query"
  },
  "Cloudflare": {
    "BenchmarkEligible": true,
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001",
    "DohTemplate": "https://cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002",
    "DohTemplate": "https://security.cloudflare-dns.com/dns-query"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003",
    "DohTemplate": "https://family.cloudflare-dns.com/dns-query"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53",
    "DohTemplate": "https://doh.opendns.com/dns-query"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9",
    "DohTemplate": "https://dns.quad9.net/dns-query"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff",
    "DohTemplate": "https://dns.adguard-dns.com/dns-query"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff",
    "DohTemplate": "https://family.adguard-dns.com/dns-query"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": ".NET Framework (versioni 2, 3, 4) - Attiva",
    "Description": ".NET e .NET Framework sono una piattaforma di sviluppo, fatta di strumenti, linguaggi e librerie, che serve a molte applicazioni.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFixesNTPPool": {
    "Content": "Server NTP - Usa pool.ntp.org",
    "Description": "Sostituisce il server NTP predefinito di Windows (time.windows.com) con pool.ntp.org, per una sincronizzazione dell'ora pi\u00f9 precisa e affidabile.",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureshyperv": {
    "Content": "Hyper-V - Attiva",
    "Description": "Hyper-V \u00e8 la piattaforma di virtualizzazione di Microsoft per creare e gestire macchine virtuali.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureslegacymedia": {
    "Content": "Componenti multimediali legacy (WMP, DirectPlay) - Attiva",
    "Description": "Attiva i componenti richiesti dai programmi delle versioni precedenti di Windows.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeaturewsl": {
    "Content": "Sottosistema Windows per Linux (WSL) - Attiva",
    "Description": "Il Sottosistema Windows per Linux permette di eseguire programmi Linux direttamente in Windows, senza macchina virtuale n\u00e9 doppio avvio.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeaturenfs": {
    "Content": "Network File System (NFS) - Attiva",
    "Description": "Network File System (NFS) \u00e8 un sistema per accedere ai file condivisi in rete.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureRegBackup": {
    "Content": "Backup del registro (ogni giorno alle 00:30) - Attiva",
    "Description": "Attiva il backup giornaliero del registro, disattivato da Microsoft a partire da Windows 10 1803.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "Ripristino classico con F8 all'avvio - Attiva",
    "Description": "Attiva la schermata Opzioni di avvio avanzate, che permette di avviare Windows nelle modalit\u00e0 di risoluzione dei problemi.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "Ripristino classico con F8 all'avvio - Disattiva",
    "Description": "Disattiva la schermata Opzioni di avvio avanzate, che permette di avviare Windows nelle modalit\u00e0 di risoluzione dei problemi.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeaturesSandbox": {
    "Content": "Sandbox di Windows - Attiva",
    "Description": "Sandbox di Windows \u00e8 una macchina virtuale leggera che offre un desktop temporaneo per eseguire applicazioni in modo isolato e sicuro.",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFeatureInstall": {
    "Content": "Attiva le funzionalit\u00e0 selezionate",
    "category": "Funzionalit\u00e0 di Windows",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelAutologin": {
    "Content": "Accesso automatico (AutoLogon) - Esegui",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFixesUpdate": {
    "Content": "Windows Update - Reimposta",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFixesNetwork": {
    "Content": "Rete - Reimposta",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelDISM": {
    "Content": "Controllo e riparazione del sistema - Esegui",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFFixesWinget": {
    "Content": "WinGet - Reinstalla",
    "category": "Riparazioni",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelComputer": {
    "Content": "Gestione computer",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelControl": {
    "Content": "Pannello di controllo",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelMouse": {
    "Content": "Propriet\u00e0 del mouse",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "main.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelNetwork": {
    "Content": "Connessioni di rete",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelPower": {
    "Content": "Opzioni risparmio energia",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelPrinter": {
    "Content": "Dispositivi e stampanti",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelPrograms": {
    "Content": "Programmi e funzionalit\u00e0",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "appwiz.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelRegion": {
    "Content": "Area geografica",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelSecurity": {
    "Content": "Sicurezza e manutenzione",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "wscui.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelSound": {
    "Content": "Audio",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelSystem": {
    "Content": "Propriet\u00e0 del sistema",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelTimedate": {
    "Content": "Data e ora",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelFirewall": {
    "Content": "Windows Defender Firewall",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "firewall.cpl"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFPanelRestore": {
    "Content": "Ripristino configurazione di sistema",
    "category": "Pannelli classici di Windows",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFWinUtilSSHServer": {
    "Content": "Server OpenSSH - Attiva",
    "category": "z__Accesso remoto",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "220",
    "AppEntryFontSize": "11",
    "AppEntryIconSize": "18",
    "AppEntryMargin": "1,0,1,0",
    "AppEntryBorderThickness": "0",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Inter, Segoe UI Variable, Segoe UI",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Inter, Segoe UI Variable, Segoe UI",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "18",
    "WindowButtonFontSize": "11",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Inter, Segoe UI Variable, Segoe UI",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "8"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F1F4F8",
    "AppInstallHighlightedColor": "#E2E8F0",
    "AppInstallSelectedColor": "#DCFCE7",
    "AppInstallOverlayBackgroundColor": "#E6FFFFFF",
    "ComboBoxForegroundColor": "#0F172A",
    "ComboBoxBackgroundColor": "#FFFFFF",
    "LabelboxForegroundColor": "#047857",
    "MainForegroundColor": "#0F172A",
    "MainBackgroundColor": "#FFFFFF",
    "LabelBackgroundColor": "#00FFFFFF",
    "LinkForegroundColor": "#047857",
    "LinkHoverForegroundColor": "#0F172A",
    "ScrollBarBackgroundColor": "#C3CBD5",
    "ScrollBarHoverColor": "#059669",
    "ScrollBarDraggingColor": "#047857",
    "ProgressBarForegroundColor": "#059669",
    "ProgressBarBackgroundColor": "#E2E8F0",
    "ProgressBarTextColor": "#0F172A",
    "ButtonInstallBackgroundColor": "#F1F4F8",
    "ButtonTweaksBackgroundColor": "#F1F4F8",
    "ButtonConfigBackgroundColor": "#F1F4F8",
    "ButtonUpdatesBackgroundColor": "#F1F4F8",
    "ButtonInstallForegroundColor": "#0F172A",
    "ButtonTweaksForegroundColor": "#0F172A",
    "ButtonConfigForegroundColor": "#0F172A",
    "ButtonUpdatesForegroundColor": "#0F172A",
    "ButtonBackgroundColor": "#F1F4F8",
    "ButtonBackgroundPressedColor": "#CBD5E1",
    "ButtonBackgroundMouseoverColor": "#E2E8F0",
    "ButtonBackgroundSelectedColor": "#D1FAE5",
    "ButtonBackgroundDisabledColor": "#F1F4F8",
    "ButtonForegroundColor": "#0F172A",
    "ButtonForegroundDisabledColor": "#A0A8B4",
    "ToggleButtonOnColor": "#059669",
    "ToggleButtonOffColor": "#7C8798",
    "ToolTipBackgroundColor": "#FFFFFF",
    "BorderColor": "#D6DCE4",
    "BorderOpacity": "0.2",
    "WindowBackgroundStartColor": "#F8FAFC",
    "WindowBackgroundEndColor": "#EEF2F6",
    "SidebarBackgroundColor": "#0A0F172A",
    "GroupBorderBackgroundColor": "#FFFFFF",
    "AccentColor": "#047857",
    "AccentGlowColor": "#047857",
    "AccentGlowOpacity": "0.18",
    "MutedForegroundColor": "#556275",
    "CheckboxMouseOverColor": "#047857",
    "FOSSHighlightColor": "#15803D",
    "DataGridAlternatingRowColor": "#F5F7FA",
    "SuccessColor": "#047857",
    "WarningColor": "#B45309",
    "DangerColor": "#DC2626"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#14FFFFFF",
    "AppInstallHighlightedColor": "#26FFFFFF",
    "AppInstallSelectedColor": "#403DF5A0",
    "AppInstallOverlayBackgroundColor": "#CC07090F",
    "ComboBoxForegroundColor": "#F8FAFC",
    "ComboBoxBackgroundColor": "#FF121724",
    "LabelboxForegroundColor": "#3DF5A0",
    "MainForegroundColor": "#F8FAFC",
    "MainBackgroundColor": "#E60B0E16",
    "LabelBackgroundColor": "#00FFFFFF",
    "LinkForegroundColor": "#3DF5A0",
    "LinkHoverForegroundColor": "#F8FAFC",
    "ScrollBarBackgroundColor": "#1AFFFFFF",
    "ScrollBarHoverColor": "#3DF5A0",
    "ScrollBarDraggingColor": "#2BD389",
    "ProgressBarForegroundColor": "#3DF5A0",
    "ProgressBarBackgroundColor": "#1AFFFFFF",
    "ProgressBarTextColor": "#F8FAFC",
    "ButtonInstallBackgroundColor": "#59161B26",
    "ButtonTweaksBackgroundColor": "#59161B26",
    "ButtonConfigBackgroundColor": "#59161B26",
    "ButtonUpdatesBackgroundColor": "#59161B26",
    "ButtonInstallForegroundColor": "#F8FAFC",
    "ButtonTweaksForegroundColor": "#F8FAFC",
    "ButtonConfigForegroundColor": "#F8FAFC",
    "ButtonUpdatesForegroundColor": "#F8FAFC",
    "ButtonBackgroundColor": "#1AFFFFFF",
    "ButtonBackgroundPressedColor": "#3DF5A0",
    "ButtonBackgroundMouseoverColor": "#26FFFFFF",
    "ButtonBackgroundSelectedColor": "#403DF5A0",
    "ButtonBackgroundDisabledColor": "#403DF5A0",
    "ButtonForegroundColor": "#F8FAFC",
    "ButtonForegroundDisabledColor": "#696969",
    "ToggleButtonOnColor": "#3DF5A0",
    "ToggleButtonOffColor": "#4A5568",
    "ToolTipBackgroundColor": "#FF121724",
    "BorderColor": "#3DF5A0",
    "BorderOpacity": "0.10",
    "WindowBackgroundStartColor": "#0B0E16",
    "WindowBackgroundEndColor": "#07090F",
    "SidebarBackgroundColor": "#26000000",
    "GroupBorderBackgroundColor": "#59161B26",
    "AccentColor": "#3DF5A0",
    "AccentGlowColor": "#3DF5A0",
    "AccentGlowOpacity": "0.45",
    "MutedForegroundColor": "#8A93A6",
    "CheckboxMouseOverColor": "#3DF5A0",
    "FOSSHighlightColor": "#4CAF50",
    "DataGridAlternatingRowColor": "#14FFFFFF",
    "SuccessColor": "#3DF5A0",
    "WarningColor": "#F5A623",
    "DangerColor": "#EF4444"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "Cronologia attivit\u00e0 - Disattiva",
    "Description": "Impedisce a Windows di pubblicare o caricare le attivit\u00e0 dell'utente, senza cancellare la cronologia degli appunti.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksHiber": {
    "Content": "Ibernazione - Disattiva",
    "Description": "L'ibernazione \u00e8 pensata per i portatili: salva il contenuto della memoria prima di spegnere il PC. Di norma non \u00e8 necessaria.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksWidget": {
    "Content": "Widget - Rimuovi",
    "Description": "Rimuove i widget in basso a sinistra sulla barra delle applicazioni.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "Menu Start precedente - Attiva",
    "Description": "Ripristina il layout del menu Start in uso prima del nuovo menu introdotto gradualmente con la 25H2. Nelle versioni pi\u00f9 recenti di Windows NON FUNZIONA.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "Risultati consigliati del Microsoft Store nella ricerca - Disattiva",
    "Description": "Non mostra le app consigliate del Microsoft Store quando si cercano app dal menu Start.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny *S-1-1-0:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant *S-1-1-0:F"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksLocation": {
    "Content": "Rilevamento della posizione - Disattiva",
    "Description": "Disattiva il rilevamento della posizione.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksServices": {
    "Content": "Servizi - Imposta su Manuale",
    "Description": "Imposta l'avvio manuale per diversi servizi di sistema che non devono restare sempre attivi. \u00c8 un'operazione sicura: se un servizio serve, si avvia da solo quando viene richiesto.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksSvcHostSplitting": {
    "Content": "Suddivisione dei processi svchost.exe - Disattiva",
    "Description": "Disattiva la suddivisione dei servizi in processi svchost.exe separati: i processi diminuiscono e si risparmia un po' di memoria. Consigliato sui PC poco potenti con 12 GB di RAM o meno. Pu\u00f2 interferire con i servizi Xbox. Riavvia Windows dopo la modifica.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # A threshold above the physical memory disables svchost service splitting\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory -Type DWord\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Windows client default (0x380000): splitting back on\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value 3670016 -Type DWord -Force\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Browser Brave - Alleggerisci",
    "Description": "Disattiva varie funzioni non necessarie come Brave Rewards, Leo AI, Crypto Wallet e VPN.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "Avvisi per i file RDP non firmati - Disattiva",
    "Description": "Disattiva gli avvisi mostrati all'apertura di file RDP non firmati, introdotti con gli ultimi aggiornamenti di Windows 10 e 11.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Microsoft Edge - Alleggerisci",
    "Description": "Disattiva diverse opzioni di telemetria, le finestre a comparsa e altre funzioni superflue di Edge.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "Funzionalit\u00e0 consumer - Disattiva",
    "Description": "Impedisce l'installazione automatica delle app promosse e riduce i suggerimenti di app dal Microsoft Store.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksTelemetry": {
    "Content": "Telemetria - Disattiva",
    "Description": "Disattiva la telemetria di Microsoft, compresa quella di PowerShell 7.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "service": [
      {
        "Name": "diagtrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "WerSvc",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "PeriodInNanoSeconds",
        "Value": "<RemoveEntry>",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable PowerShell 7 telemetry\r\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "Ottimizzazione recapito - Disattiva",
    "Description": "Impedisce a Windows di usare la connessione del PC per inviare aggiornamenti ad altri computer su Internet o nella rete locale.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Microsoft Edge - Rimuovi",
    "Description": "Disinstalla Microsoft Edge creando un file MicrosoftEdge.exe fittizio nella cartella del vecchio Edge: cos\u00ec Windows sblocca il programma di disinstallazione ufficiale e Edge viene rimosso dal sistema.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $EdgeAppDir = \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\"\r\n      $Path = $null\r\n      if (Test-Path -LiteralPath $EdgeAppDir -ErrorAction Stop) {\r\n          $InstallerPattern = Join-Path $EdgeAppDir \"*\\Installer\\setup.exe\"\r\n          if (Test-Path -Path $InstallerPattern -ErrorAction Stop) {\r\n              $Path = Resolve-Path -Path $InstallerPattern -ErrorAction Stop | Select-Object -Last 1\r\n          }\r\n      }\r\n\r\n      if ($Path) {\r\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\r\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\r\n          Write-Host \"Microsoft Edge was removed\"\r\n      } else {\r\n          Write-Host \"Microsoft Edge is not installed\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing Microsoft Edge...\"\r\n      winget install Microsoft.Edge --source winget\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "BitLocker - Disattiva",
    "Description": "Disattiva BitLocker e decrittografa l'unit\u00e0 di sistema.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksUTC": {
    "Content": "Data e ora - Imposta l'orologio su UTC",
    "Description": "Indispensabile sui PC con doppio avvio: allinea l'orario con i sistemi Linux.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Microsoft OneDrive - Rimuovi",
    "Description": "Impedisce la cancellazione dei file utente di OneDrive, lo rimuove con il suo programma di disinstallazione e poi ripristina i permessi originali.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $OneDrivePath = $Env:OneDrive\r\n      $OneDriveFolderExists = -not [string]::IsNullOrWhiteSpace($OneDrivePath) -and (Test-Path -LiteralPath $OneDrivePath -PathType Container -ErrorAction Stop)\r\n\r\n      if ($OneDriveFolderExists) {\r\n          $OneDriveAcl = Get-Acl -LiteralPath $OneDrivePath -ErrorAction Stop\r\n      } else {\r\n          Write-Host \"OneDrive folder is already absent; skipping folder permissions and cleanup.\"\r\n      }\r\n\r\n      try {\r\n          if ($OneDriveFolderExists) {\r\n              # Protect user files while the uninstaller runs.\r\n              icacls $OneDrivePath /deny \"*S-1-5-32-544:(D,DC)\"\r\n              if ($LASTEXITCODE -ne 0) { throw \"Unable to protect the OneDrive folder (icacls exit code $LASTEXITCODE).\" }\r\n          }\r\n\r\n          Write-Host \"Uninstalling OneDrive...\"\r\n          Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList '/uninstall' -Wait -ErrorAction Stop\r\n\r\n          # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n          Write-Host \"Removing leftover OneDrive Files...\"\r\n\r\n          Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'FileCoAuth' | Stop-Process -ErrorAction Stop\r\n          Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'Explorer' | Stop-Process -ErrorAction Stop\r\n\r\n          $OneDriveLeftovers = @(\"$Env:LocalAppData\\Microsoft\\OneDrive\", \"$Env:ProgramData\\Microsoft OneDrive\")\r\n          foreach ($LeftoverPath in $OneDriveLeftovers) {\r\n              if (Test-Path -LiteralPath $LeftoverPath -ErrorAction Stop) {\r\n                  Remove-Item -LiteralPath $LeftoverPath -Recurse -Force -ErrorAction Stop\r\n              }\r\n          }\r\n      } finally {\r\n          if ($OneDriveFolderExists) {\r\n              # Restore access even when uninstall or leftover cleanup fails.\r\n              Set-Acl -LiteralPath $OneDrivePath -AclObject $OneDriveAcl -ErrorAction Stop\r\n          }\r\n      }\r\n\r\n      if ($OneDriveFolderExists -and -not (Get-ChildItem -LiteralPath $OneDrivePath -Force -ErrorAction Stop)) {\r\n          # Refuse to delete if files appeared after the emptiness check.\r\n          [System.IO.Directory]::Delete($OneDrivePath, $false)\r\n          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')\r\n      }\r\n\r\n      # OneSyncSvc is a per-user template; Get-Service only exposes user instances.\r\n      # Skip the operation if this Windows installation has no template.\r\n      if (Test-Path -LiteralPath 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\OneSyncSvc') {\r\n          Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enable OneSyncSvc when the per-user service template exists\r\n      if (Test-Path -LiteralPath 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\OneSyncSvc') {\r\n          Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      }\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "Home e Raccolta di Esplora file - Disattiva",
    "Description": "Rimuove Home e Raccolta da Esplora file e imposta Questo PC come cartella predefinita.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisplay": {
    "Content": "Effetti visivi - Imposta per le prestazioni migliori",
    "Description": "Imposta le opzioni di sistema per privilegiare le prestazioni. Si pu\u00f2 fare anche a mano da sysdm.cpl.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksReservedStorage": {
    "Content": "Archiviazione riservata - Disattiva",
    "Description": "Disattiva l'archiviazione riservata di Windows (7-10 GB tenuti da parte per aggiornamenti e file temporanei). Consigliato solo sui dischi piccoli: riattivala prima dei grandi aggiornamenti di Windows, per evitare errori di installazione.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRestorePoint": {
    "Content": "Punto di ripristino - Crea",
    "Description": "Crea un punto di ripristino prima di applicare le modifiche, per poter tornare indietro se necessario.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "Termina attivit\u00e0 con il tasto destro - Attiva",
    "Description": "Aggiunge l'opzione per terminare un programma facendo clic destro sulla sua icona nella barra delle applicazioni.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksStorage": {
    "Content": "Sensore memoria - Disattiva",
    "Description": "Sensore memoria elimina automaticamente i file temporanei.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksWindowsAI": {
    "Content": "Funzioni di intelligenza artificiale (Copilot, Recall) - Disattiva e rimuovi",
    "Description": "Rimuove e disattiva tutte le funzioni e i pacchetti di intelligenza artificiale di Windows, tra cui Copilot e Recall.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n\r\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\r\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      if ($Appx) {\r\n          Remove-AppxPackage $Appx\r\n      }\r\n\r\n      # WSAIFabricSvc only exists on some Windows 11 builds; without the guard a\r\n      # missing service aborts the rest of this script block and Recall stays enabled\r\n      if (Get-Service -Name WSAIFabricSvc -ErrorAction SilentlyContinue) {\r\n          Set-Service -Name WSAIFabricSvc -StartupType Disabled\r\n      }\r\n      # Store/MSIX PowerShell 7 can hang or fail COM activation in DISM.\r\n      $RecallCommand = {\r\n          Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart -ErrorAction Stop | Out-Null\r\n      }\r\n      $RecallOutput = powershell.exe -NoProfile -NonInteractive -Command $RecallCommand 2>&1\r\n      if ($LASTEXITCODE -ne 0) {\r\n          throw \"Failed to disable Recall (exit code $LASTEXITCODE): $(($RecallOutput | Out-String).Trim())\"\r\n      }\r\n      $RecallOutput | ForEach-Object { Write-Host $_ }\r\n\r\n      Write-Host \"Windows AI Disabled\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksWPBT": {
    "Content": "Windows Platform Binary Table (WPBT) - Disattiva",
    "Description": "Se attiva, la WPBT permette al produttore del PC di eseguire programmi all'avvio, come software antifurto o driver, e di installare software senza il consenso dell'utente. \u00c8 un potenziale rischio per la sicurezza.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksPreventDeviceMetadataFromNetwork": {
    "Content": "App complementari dei dispositivi - Blocca",
    "Description": "Impedisce l'installazione di software aggiuntivo quando si collega un dispositivo (ad es. pubblicit\u00e0 quando si collega un monitor), che pu\u00f2 essere un rischio per la sicurezza.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
        "Name": "PreventDeviceMetadataFromNetwork",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Installazione automatica del software Razer - Disattiva",
    "Description": "Blocca TUTTE le installazioni di software Razer. Le periferiche funzionano anche senza.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\r\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"*S-1-1-0:(W)\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d *S-1-1-0\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksLogiBlock": {
    "Content": "Installazione automatica di Logi Download Assistant - Disattiva",
    "Description": "Blocca Logi Download Assistant, che Windows Update reinstalla insieme ai driver dei dispositivi Logitech. Le periferiche Logitech funzionano anche senza.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      Stop-Process -Name \"logi_download_assistant\" -Force -ErrorAction SilentlyContinue\r\n\r\n      $ProgramFiles64 = if ($Env:ProgramW6432) { $Env:ProgramW6432 } else { $Env:ProgramFiles }\r\n      $LogiPath = \"$ProgramFiles64\\LogiDownloadAssistant\"\r\n\r\n      if (Test-Path $LogiPath) {\r\n        Remove-Item $LogiPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $LogiPath -ItemType Directory\r\n      }\r\n\r\n      icacls $LogiPath /deny \"*S-1-1-0:(W)\"\r\n      if ($LASTEXITCODE -ne 0) { throw \"icacls failed to deny write access on $LogiPath (exit code $LASTEXITCODE)\" }\r\n      "
    ],
    "UndoScript": [
      "\r\n      $ProgramFiles64 = if ($Env:ProgramW6432) { $Env:ProgramW6432 } else { $Env:ProgramFiles }\r\n      $LogiPath = \"$ProgramFiles64\\LogiDownloadAssistant\"\r\n\r\n      if (Test-Path $LogiPath) {\r\n        icacls $LogiPath /remove:d \"*S-1-1-0\"\r\n        if ($LASTEXITCODE -ne 0) { throw \"icacls failed to remove the write-deny rule on $LogiPath (exit code $LASTEXITCODE)\" }\r\n      }\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "Notifiche e calendario nell'area di notifica - Disattiva",
    "Description": "Disattiva tutte le notifiche, COMPRESO il calendario.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Blocco degli indirizzi Adobe - Attiva",
    "Description": "Riduce le interruzioni bloccando in modo selettivo le connessioni ai server di attivazione e telemetria di Adobe. Crediti: Ruddernation-Designs",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\r\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Added Adobe url block list from host file'\r\n      "
    ],
    "UndoScript": [
      "\r\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\r\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''\r\n      )\r\n\r\n      ipconfig /flushdns\r\n      Write-Host 'Removed Adobe url block list from host file'\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "Menu classico del tasto destro - Attiva",
    "Description": "Ripristina il menu contestuale classico di Esplora file al posto di quello semplificato di Windows 11.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "InvokeScript": [
      "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\r\n      Stop-Process -Name explorer\r\n      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "Pulizia disco - Esegui",
    "Description": "Esegue Pulizia disco sull'unit\u00e0 C: e rimuove i vecchi aggiornamenti di Windows.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "File temporanei - Elimina",
    "Description": "Svuota le cartelle dei file temporanei (TEMP).",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # A temp folder always holds files something has open, including this run's own, and\r\n      # the job layer counts a logged error as a failed step\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force -ErrorAction SilentlyContinue\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force -ErrorAction SilentlyContinue\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksIPv46": {
    "Content": "IPv6 - Preferisci IPv4",
    "Description": "Dare la precedenza a IPv4 pu\u00f2 ridurre la latenza e migliorare la sicurezza nelle reti private in cui IPv6 non \u00e8 configurato.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksTeredo": {
    "Content": "Teredo - Disattiva",
    "Description": "Il tunneling Teredo \u00e8 una funzione di IPv6 che pu\u00f2 aumentare la latenza; disattivarlo pu\u00f2 per\u00f2 causare problemi con alcuni giochi.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "IPv6 - Disattiva",
    "Description": "Disattiva IPv6.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "App in background - Disattiva",
    "Description": "Impedisce a tutte le app del Microsoft Store di funzionare in background, cosa che da Windows 11 andrebbe fatta app per app.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "Rilevamento automatico del tipo di cartella - Disattiva",
    "Description": "Esplora file cerca di indovinare il tipo di cartella in base al contenuto e questo rallenta la navigazione. ATTENZIONE: disattiva il raggruppamento in Esplora file.",
    "category": "Ottimizzazioni essenziali",
    "panel": "1",
    "InvokeScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "UndoScript": [
      "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "Schermata blu dettagliata",
    "Description": "Se attiva, la schermata blu (BSoD) mostra informazioni pi\u00f9 dettagliate.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "Percentuale della batteria nell'area di notifica",
    "Description": "Se attiva, mostra la percentuale della batteria accanto alla sua icona nell'area di notifica.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleDarkMode": {
    "Content": "Tema scuro di Windows",
    "Description": "Attiva o disattiva la modalit\u00e0 scura.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleShowExt": {
    "Content": "Estensioni dei file in Esplora file",
    "Description": "Se attivo, le estensioni dei file (ad es. .txt, .jpg) sono visibili.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleHiddenFiles": {
    "Content": "File nascosti in Esplora file",
    "Description": "Se attivo, i file nascosti vengono mostrati.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleVerboseLogon": {
    "Content": "Messaggi dettagliati all'accesso",
    "Description": "Mostra messaggi dettagliati durante l'accesso, utili per la diagnosi dei problemi.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleNewOutlook": {
    "Content": "Nuova versione di Microsoft Outlook",
    "Description": "Se disattivo, rimuove l'interruttore per il nuovo Outlook, blocca la migrazione al nuovo Outlook e mantiene l'Outlook classico.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleScrollbars": {
    "Content": "Barre di scorrimento sempre visibili",
    "Description": "Se attivo, le barre di scorrimento sono sempre visibili. Se disattivo, Windows le nasconde quando non servono.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFMultiplaneOverlay": {
    "Content": "Multiplane Overlay",
    "Description": "Il Multiplane Overlay compone pi\u00f9 livelli di immagine e con alcune schede video pu\u00f2 causare problemi. La modifica viene applicata subito.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Combobox",
    "ComboItems": "Attivo|Disattivato (compatibilit\u00e0)|Disattivato completamente",
    "ComboDescriptions": {
      "Attivo": "Usa il comportamento predefinito di Windows.",
      "Disattivato (compatibilit\u00e0)": "Disattiva l'MPO con OverlayTestMode=5, il metodo meno aggressivo.",
      "Disattivato completamente": "Disattiva l'MPO con OverlayTestMode=5 e DisableOverlays=1, il metodo pi\u00f9 aggressivo."
    },
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Type": "DWord",
        "DefaultValue": "0",
        "Values": {
          "Attivo": "<RemoveEntry>",
          "Disattivato (compatibilit\u00e0)": "5",
          "Disattivato completamente": "5"
        }
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Type": "DWord",
        "DefaultValue": "0",
        "Values": {
          "Attivo": "<RemoveEntry>",
          "Disattivato (compatibilit\u00e0)": "<RemoveEntry>",
          "Disattivato completamente": "1"
        }
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "Accelerazione del mouse",
    "Description": "Se attiva, il movimento del puntatore dipende dalla velocit\u00e0 con cui si sposta il mouse.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleNumLock": {
    "Content": "Bloc Num all'avvio",
    "Description": "Imposta lo stato del tasto Bloc Num all'avvio del computer.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleWindowSnapping": {
    "Content": "Ancoraggio delle finestre",
    "Description": "Attiva o disattiva l'ancoraggio delle finestre quando vengono trascinate verso i bordi dello schermo.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleStandbyFix": {
    "Content": "Rete durante la sospensione S0",
    "Description": "Attiva o disattiva la connessione di rete durante la sospensione S0 (Modern Standby).",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleS3Sleep": {
    "Content": "Sospensione S3",
    "Description": "Passa dalla sospensione moderna (Modern Standby) alla sospensione S3 e viceversa.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "Pagina Home delle Impostazioni",
    "Description": "Attiva o disattiva la pagina Home nell'app Impostazioni di Windows.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleBingSearch": {
    "Content": "Ricerca Bing nel menu Start",
    "Description": "Se attiva, la ricerca nel menu Start include anche i risultati web di Bing.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleLoginBlur": {
    "Content": "Sfocatura della schermata di accesso",
    "Description": "Se disattiva, rimuove l'effetto sfocato (acrilico) dallo sfondo della schermata di accesso di Windows 10/11.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleDisableLockscreen": {
    "Content": "Salta la schermata di blocco",
    "Description": "Salta del tutto la schermata di blocco: all'avvio e alla riattivazione compare subito la schermata di accesso.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "Consigliati nel menu Start",
    "Description": "Se disattivo, il menu Start non mostra pi\u00f9 i contenuti consigliati. ATTENZIONE: disattiva anche Windows Spotlight nella schermata di blocco.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleStickyKeys": {
    "Content": "Tasti permanenti",
    "Description": "Se attivo, abilita i Tasti permanenti, una funzione di accessibilit\u00e0 che aiuta chi ha difficolt\u00e0 a premere pi\u00f9 tasti insieme e riduce lo sforzo ripetitivo.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "Icone della barra delle applicazioni al centro",
    "Description": "[Windows 11] Se attivo, le icone della barra delle applicazioni sono al centro, altrimenti a sinistra.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "UndoScript": [
      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "Icona Cerca nella barra delle applicazioni",
    "Description": "Se attivo, il pulsante Cerca compare nella barra delle applicazioni.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleTaskView": {
    "Content": "Icona Visualizzazione attivit\u00e0 nella barra delle applicazioni",
    "Description": "Se attivo, il pulsante Visualizzazione attivit\u00e0 compare nella barra delle applicazioni.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleGameMode": {
    "Content": "Modalit\u00e0 gioco",
    "Description": "Attiva o disattiva la Modalit\u00e0 gioco, con cui Windows d\u00e0 la priorit\u00e0 ai giochi nell'uso delle risorse del sistema.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFToggleLongPaths": {
    "Content": "Percorsi lunghi",
    "Description": "Attiva o disattiva il supporto ai percorsi dei file pi\u00f9 lunghi di 260 caratteri.",
    "category": "Preferenze",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFOOSUbutton": {
    "Content": "O&O ShutUp10++ - Esegui",
    "Description": "Scarica O&O ShutUp10++ da oo-software.com e lo avvia, senza installarlo.",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "Type": "Button",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFchangedns": {
    "Content": "DNS - Imposta su:",
    "category": "z__Ottimizzazioni avanzate - ATTENZIONE",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Fastest Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFAddUltPerf": {
    "Content": "Profilo Prestazioni eccellenti - Attiva",
    "category": "z__Piani di alimentazione - NON PER I PORTATILI",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  },
  "WPFRemoveUltPerf": {
    "Content": "Profilo Prestazioni eccellenti - Disattiva",
    "category": "z__Piani di alimentazione - NON PER I PORTATILI",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://github.com/rtecnocopy89/WinRUtil"
  }
}
'@ | ConvertFrom-Json
$WinRUtilWebHtml = @'
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WinRUtil</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%2307090F'/%3E%3Cpath d='M7 9l3.5 14L16 12l5.5 11L25 9' stroke='%233DF5A0' stroke-width='3' fill='none' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E">
<style>
:root{
  --bg:#07090F; --bg2:#0B0E16; --elev:#121724; --glass:rgba(22,27,38,.55); --glass2:rgba(255,255,255,.04);
  --line:rgba(255,255,255,.08); --line2:rgba(255,255,255,.14);
  --tx:#F8FAFC; --mu:#8A93A6; --mu2:#667085;
  --accent:#3DF5A0; --accent2:#2BD389; --glow:rgba(61,245,160,.4); --indigo:#5E6AD2;
  --ok:#3DF5A0; --warn:#F5A623; --bad:#EF4444;
  --radius:14px; --ease:cubic-bezier(.16,1,.3,1);
}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;color:var(--tx);font:14px/1.5 "Inter","Segoe UI Variable Text","Segoe UI",system-ui,Arial,sans-serif;-webkit-font-smoothing:antialiased;
  background:radial-gradient(1100px 600px at 85% -10%,rgba(94,106,210,.16),transparent 60%),radial-gradient(900px 520px at -10% 110%,rgba(61,245,160,.08),transparent 60%),linear-gradient(180deg,var(--bg2),var(--bg))}
button,input,select,textarea{font:inherit}
.app{min-height:100%;display:flex;flex-direction:column}

/* header */
.top{display:flex;align-items:center;gap:14px;padding:14px 24px;border-bottom:1px solid var(--line);background:rgba(7,9,15,.72);backdrop-filter:blur(10px);position:sticky;top:0;z-index:10}
.brand{display:flex;align-items:center;gap:12px}
.brand h1{font-size:17px;margin:0;font-weight:700;letter-spacing:.2px}
.brand h1 span{color:var(--accent)}
.brand small{display:block;color:var(--mu);font-size:12px;margin-top:1px}
.top .meta{margin-left:auto;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.chip{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;border:1px solid var(--line2);color:var(--mu);font-size:12px;background:var(--glass2)}
.chip i{width:7px;height:7px;border-radius:50%;background:var(--ok);display:inline-block;box-shadow:0 0 8px var(--glow)}

/* layout */
.shell{flex:1;display:grid;grid-template-columns:230px 1fr;min-height:0}
@media (max-width:860px){.shell{grid-template-columns:1fr}.side{position:static!important;flex-direction:row!important;overflow-x:auto;height:auto!important}.side .foot{display:none}}
.side{position:sticky;top:61px;height:calc(100vh - 61px);display:flex;flex-direction:column;gap:3px;padding:16px 12px;border-right:1px solid var(--line);overflow-y:auto}
.nav{display:flex;align-items:center;gap:11px;padding:9px 12px;border-radius:10px;border:1px solid transparent;background:none;color:var(--mu);cursor:pointer;text-align:left;font-weight:500;white-space:nowrap;transition:all .2s var(--ease)}
.nav svg{width:18px;height:18px;flex:0 0 18px;stroke:currentColor;fill:none;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.nav:hover{color:var(--tx);background:var(--glass2)}
.nav.on{color:var(--tx);background:rgba(61,245,160,.08);border-color:rgba(61,245,160,.25);box-shadow:inset 3px 0 0 var(--accent)}
.nav.on svg{stroke:var(--accent)}
.side .foot{margin-top:auto;color:var(--mu2);font-size:12px;padding:12px;border:1px solid var(--line);border-radius:12px;background:var(--glass2);display:flex;flex-direction:column;gap:8px}
.side .foot p{margin:0}
.side .foot .btn{width:100%}
main{min-width:0;padding:26px 28px 150px;max-width:1240px;width:100%}
.view{display:none;animation:fade .3s var(--ease)}
.view.on{display:block}
@keyframes fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.head{display:flex;align-items:flex-end;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:18px}
.head h2{font-size:24px;margin:0 0 4px;font-weight:700;letter-spacing:-.2px}
.head p{margin:0;color:var(--mu);max-width:680px}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center}

/* buttons */
.btn{min-width:110px;position:relative;cursor:pointer;padding:10px 18px;border:0;border-radius:9px;box-shadow:inset 0 0 0 1px rgba(255,255,255,.1);
  background:radial-gradient(ellipse at bottom,rgba(71,81,92,1) 0%,rgba(11,21,30,1) 45%);color:rgba(255,255,255,.8);font-weight:600;letter-spacing:.2px;transition:all 1s var(--ease)}
.btn::before{content:"";width:70%;height:1px;position:absolute;bottom:0;left:15%;background:linear-gradient(90deg,rgba(255,255,255,0) 0%,rgba(255,255,255,1) 50%,rgba(255,255,255,0) 100%);opacity:.2;transition:all 1s var(--ease)}
.btn:hover{color:#fff;transform:scale(1.04) translateY(-2px)}
.btn:hover::before{opacity:1}
.btn:active{transform:scale(.97)}
.btn:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.btn:disabled{opacity:.45;cursor:not-allowed;transform:none}
.btn.primary{background:radial-gradient(ellipse at bottom,rgba(61,245,160,.85) 0%,rgba(8,34,26,1) 58%);color:#fff;box-shadow:inset 0 0 0 1px rgba(61,245,160,.35),0 8px 24px -12px var(--glow)}
.btn.danger{background:radial-gradient(ellipse at bottom,rgba(239,68,68,.85) 0%,rgba(40,14,18,1) 55%);color:#fff;box-shadow:inset 0 0 0 1px rgba(248,113,113,.35)}
.btn.ghost{background:transparent;box-shadow:inset 0 0 0 1px var(--line2)}
.btn.sm{min-width:0;padding:7px 12px;font-size:13px}

/* cards */
.card{background:linear-gradient(180deg,rgba(255,255,255,.035),rgba(255,255,255,.01)),var(--glass);border:1px solid var(--line);border-radius:var(--radius);padding:18px;position:relative;overflow:hidden;box-shadow:inset 0 1px 0 rgba(255,255,255,.04)}
.card h3{margin:0 0 10px;font-size:14px;font-weight:650;display:flex;align-items:center;gap:8px;color:var(--tx)}
.card h3 svg{width:16px;height:16px;stroke:var(--accent);fill:none;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}
.card.wide{grid-column:1/-1}
.grid{display:grid;gap:14px}
.g3{grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}
.kv{display:grid;grid-template-columns:auto 1fr;gap:5px 14px;font-size:13px}
.kv span{color:var(--mu)}.kv b{font-weight:500;text-align:right;word-break:break-word}
.big{font-size:22px;font-weight:700;letter-spacing:-.3px;margin:2px 0 8px}
.pill{display:inline-block;font-size:11px;font-weight:700;letter-spacing:.3px;padding:2px 9px;border-radius:999px;border:1px solid currentColor}
.sec{margin-top:24px}
.sec>h3{font-size:13px;text-transform:uppercase;letter-spacing:.6px;color:var(--mu);margin:0 0 10px;font-weight:650;display:flex;gap:8px;align-items:center}
.sec>h3 .n{color:var(--mu2);font-weight:500;text-transform:none;letter-spacing:0}
.c-ok{color:var(--ok)}.c-warn{color:var(--warn)}.c-bad{color:#f87171}.c-mu{color:var(--mu)}

/* progress bar */
.bar{width:100%;background:rgba(236,236,238,.1);height:8px;border-radius:7px;overflow:hidden}
.bar>i{display:block;width:0;height:100%;border-radius:7px;background:linear-gradient(90deg,#fff,var(--accent));transition:width .5s var(--ease);box-shadow:0 0 12px var(--glow)}
.bar.warn>i{background:linear-gradient(90deg,#fff,var(--warn));box-shadow:none}
.bar.indet>i{animation:loading 5s cubic-bezier(.4,1.01,1,1) infinite}
@keyframes loading{0%{width:0%}50%{width:100%}100%{width:0%}}

/* toolbar */
.tool{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:16px;padding:12px;border:1px solid var(--line);border-radius:12px;background:var(--glass2);position:sticky;top:72px;z-index:4;backdrop-filter:blur(10px)}
.search{flex:1;min-width:200px;padding:9px 12px;border:1px solid var(--line2);border-radius:9px;background:rgba(7,9,15,.6);color:var(--tx);outline:none}
.search:focus,.fld:focus{border-color:rgba(61,245,160,.5);box-shadow:0 0 0 3px rgba(61,245,160,.12)}
.seg{display:inline-flex;border:1px solid var(--line2);border-radius:9px;overflow:hidden}
.seg button{border:0;background:none;color:var(--mu);padding:8px 12px;cursor:pointer;font-weight:600;font-size:13px}
.seg button.on{background:rgba(61,245,160,.14);color:var(--accent)}
select{background:var(--elev);color:var(--tx);border:1px solid var(--line2);border-radius:8px;padding:8px 10px}
.count{color:var(--mu);font-size:13px;white-space:nowrap}
.count b{color:var(--accent)}
.chips{display:flex;gap:6px;flex-wrap:wrap;margin:-4px 0 14px}
.cchip{border:1px solid var(--line2);background:var(--glass2);color:var(--mu);border-radius:999px;padding:5px 12px;font-size:12.5px;font-weight:600;cursor:pointer;transition:all .2s var(--ease)}
.cchip:hover{color:var(--tx)}
.cchip.on{color:var(--accent);border-color:rgba(61,245,160,.45);background:rgba(61,245,160,.1)}

/* selectable items */
.items{display:grid;gap:8px;grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}
.items.wide{grid-template-columns:repeat(auto-fill,minmax(360px,1fr))}
.it{display:flex;gap:11px;align-items:flex-start;padding:11px 13px;border:1px solid var(--line);border-radius:11px;background:var(--glass2);cursor:pointer;transition:border-color .2s var(--ease),background .2s var(--ease)}
.it:hover{border-color:var(--line2);background:rgba(255,255,255,.06)}
.it.sel{border-color:rgba(61,245,160,.45);background:rgba(61,245,160,.07)}
.it input{position:absolute;opacity:0;pointer-events:none}
.box{flex:0 0 18px;width:18px;height:18px;border-radius:5px;border:1.5px solid var(--line2);margin-top:1px;display:grid;place-items:center;transition:all .2s var(--ease)}
.it.sel .box{background:var(--accent);border-color:var(--accent);box-shadow:0 0 10px var(--glow)}
.box svg{width:12px;height:12px;stroke:#07090F;stroke-width:3;fill:none;opacity:0}
.it.sel .box svg{opacity:1}
.it .t{font-weight:600;font-size:13.5px;display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.it .d{color:var(--mu);font-size:12.5px;margin-top:2px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.foss{font-size:10px;font-weight:800;color:var(--accent);border:1px solid rgba(61,245,160,.4);border-radius:5px;padding:0 5px}
.tag{font-size:10px;font-weight:700;color:var(--mu);border:1px solid var(--line2);border-radius:5px;padding:0 5px}
.ico{position:relative;flex:0 0 22px;width:22px;height:22px;border-radius:6px;background:rgba(255,255,255,.07);display:grid;place-items:center;overflow:hidden}
.ico b{font-size:11.5px;font-weight:800;color:var(--accent)}
.ico img{position:absolute;inset:2px;width:18px;height:18px;object-fit:contain}

/* switches */
.sw{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:11px 13px;border:1px solid var(--line);border-radius:11px;background:var(--glass2)}
.sw .t{font-weight:600;font-size:13.5px}.sw .d{color:var(--mu);font-size:12.5px}
.tg{position:relative;flex:0 0 44px;width:44px;height:24px;border-radius:999px;background:rgba(255,255,255,.12);border:0;cursor:pointer;transition:background .25s var(--ease)}
.tg::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;transition:transform .25s var(--ease)}
.tg.on{background:var(--accent);box-shadow:0 0 12px var(--glow)}
.tg.on::after{transform:translateX(20px);background:#07090F}
.tg:disabled{opacity:.5;cursor:wait}

details.adv{margin-top:24px;border:1px solid rgba(245,166,35,.35);border-radius:12px;background:rgba(245,166,35,.04);padding:0 14px}
details.adv summary{cursor:pointer;padding:13px 0;color:#f8d38b;font-weight:650}
details.adv .items{padding-bottom:14px}
.note{color:var(--mu);font-size:12.5px;margin:8px 0 0}
.warnbox{display:flex;gap:10px;padding:11px 14px;border-radius:11px;border:1px solid rgba(245,166,35,.35);background:rgba(245,166,35,.08);color:#f8d38b;font-size:13px;margin-bottom:12px}

/* updates */
.upd{display:flex;flex-direction:column;gap:12px}
.upd p{margin:0;color:var(--mu);flex:1}
.upd.rec{border-color:rgba(61,245,160,.35)}
.upd.rec::after{content:"Consigliata";position:absolute;top:16px;right:16px;font-size:11px;font-weight:700;letter-spacing:.4px;text-transform:uppercase;color:var(--accent);border:1px solid rgba(61,245,160,.35);padding:2px 8px;border-radius:999px}

/* tables */
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:middle}
th{color:var(--mu);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.5px}
tr:last-child td{border-bottom:0}
tr.pick{cursor:pointer}
tr.pick:hover td{background:rgba(255,255,255,.03)}
tr.pick.sel td{background:rgba(61,245,160,.07)}
td.nw{white-space:nowrap}
.pw{font-family:"Cascadia Mono",Consolas,monospace;font-size:13px}
.ib{border:1px solid var(--line2);background:none;color:var(--mu);border-radius:7px;padding:4px 8px;cursor:pointer;font-size:12px;margin-left:6px}
.ib:hover{color:var(--accent);border-color:rgba(61,245,160,.4)}
.ib:disabled{opacity:.4;cursor:not-allowed}
.tcard{padding:6px}
.tscroll{overflow:auto;max-height:52vh}

/* forms */
.form{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(260px,1fr))}
.form label{display:flex;flex-direction:column;gap:5px;font-size:12.5px;color:var(--mu);font-weight:600}
.form label.full{grid-column:1/-1}
.fld{width:100%;padding:9px 12px;border:1px solid var(--line2);border-radius:9px;background:rgba(7,9,15,.6);color:var(--tx);outline:none;font-weight:400;resize:vertical}

/* activity dock */
.dock{position:fixed;left:0;right:0;bottom:0;z-index:20;border-top:1px solid var(--line2);background:rgba(11,14,22,.92);backdrop-filter:blur(14px);transform:translateY(100%);transition:transform .35s var(--ease)}
.dock.on{transform:none}
.dock .in{max-width:1240px;margin:0 auto;padding:12px 24px;display:grid;grid-template-columns:1fr auto;gap:8px 16px;align-items:center}
.dock .ti{font-weight:650;display:flex;gap:10px;align-items:center;min-width:0}
.dock .ti span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dock .lb{color:var(--mu);font-size:12.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:420px}
.dot{width:9px;height:9px;border-radius:50%;background:var(--accent);box-shadow:0 0 10px var(--glow);flex:0 0 9px;animation:pulse 1.4s ease-in-out infinite}
.dot.done{animation:none}.dot.err{background:var(--bad);box-shadow:none;animation:none}
@keyframes pulse{50%{opacity:.35}}
.dock .bar{grid-column:1/-1}
.log{grid-column:1/-1;display:none;height:220px;overflow:auto;background:#05070c;border:1px solid var(--line);border-radius:10px;padding:10px 12px;font:12px/1.6 "Cascadia Mono",Consolas,monospace}
.dock.open .log{display:block}
.log div{white-space:pre-wrap;word-break:break-word;color:#94a3b8}
.log .warn{color:#fcd34d}.log .error{color:#fca5a5}.log .ok{color:#86efac}.log .head{color:#e5e7eb;font-weight:700;margin-top:6px}
.log .tm{color:var(--mu2);margin-right:8px}

/* modal + toast */
.modal{position:fixed;inset:0;display:none;place-items:center;background:rgba(0,0,0,.55);z-index:40;backdrop-filter:blur(3px)}
.modal.on{display:grid}
.modal .card{width:min(460px,calc(100% - 32px));padding:22px;max-height:calc(100vh - 40px);overflow:auto}
.modal .card.lg{width:min(920px,calc(100% - 32px))}
.modal h4{margin:0 0 8px;font-size:17px}
.modal p{margin:0 0 18px;color:var(--mu)}
.qr{background:#fff;border-radius:12px;padding:10px;width:300px;max-width:100%;margin:6px auto 14px;display:block}
.qr svg{display:block;width:100%;height:auto;shape-rendering:crispEdges}
.qrt{text-align:center}
.qrt b{display:block;font-size:18px}
.toast{position:fixed;right:20px;top:76px;z-index:50;display:flex;flex-direction:column;gap:8px}
.toast div{padding:10px 14px;border-radius:10px;border:1px solid var(--line2);background:var(--elev);box-shadow:0 12px 30px -12px rgba(0,0,0,.6);font-size:13px;max-width:360px;animation:fade .3s var(--ease)}
.toast .e{border-color:rgba(239,68,68,.5)}
.empty{color:var(--mu);padding:20px;text-align:center}
.skel{height:14px;border-radius:6px;background:linear-gradient(90deg,rgba(255,255,255,.04),rgba(255,255,255,.09),rgba(255,255,255,.04));background-size:200% 100%;animation:sh 1.4s infinite;margin:8px 0}
@keyframes sh{to{background-position:-200% 0}}
.spin{display:inline-block;width:14px;height:14px;border:2px solid rgba(255,255,255,.2);border-top-color:var(--accent);border-radius:50%;animation:rot 1s linear infinite;vertical-align:-2px;margin-right:8px}
@keyframes rot{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
</style>
</head>
<body>
<div class="app">
  <header class="top">
    <div class="brand">
      <svg width="34" height="34" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" rx="8" fill="#0B0E16" stroke="rgba(61,245,160,.35)"/><path d="M7 9l3.5 14L16 12l5.5 11L25 9" stroke="#3DF5A0" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
      <div><h1>Win<span>R</span>Util</h1><small>Toolkit per Windows</small></div>
    </div>
    <div class="meta">
      <span class="chip" id="chipPc"><i></i><span>PC</span></span>
      <span class="chip"><i></i><span>Amministratore</span></span>
      <span class="chip" id="chipVer">v</span>
    </div>
  </header>

  <div class="shell">
    <nav class="side" aria-label="Sezioni">
      <button type="button" class="nav on" data-v="sys" title="Alt+S"><svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 20h8M12 16v4"/></svg>Sistema</button>
      <button type="button" class="nav" data-v="inst" title="Alt+I"><svg viewBox="0 0 24 24"><path d="M12 3v12M7 10l5 5 5-5"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>Installa</button>
      <button type="button" class="nav" data-v="tw" title="Alt+T"><svg viewBox="0 0 24 24"><path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/></svg>Ottimizza</button>
      <button type="button" class="nav" data-v="appx" title="Alt+A"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><path d="M14 17.5h7M17.5 14v7"/></svg>App di Windows</button>
      <button type="button" class="nav" data-v="cfg" title="Alt+C"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>Configura</button>
      <button type="button" class="nav" data-v="upd" title="Alt+U"><svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/></svg>Aggiornamenti</button>
      <button type="button" class="nav" data-v="prn" title="Alt+P"><svg viewBox="0 0 24 24"><path d="M6 9V3h12v6"/><rect x="3" y="9" width="18" height="8" rx="2"/><path d="M6 14h12v7H6z"/></svg>Stampanti</button>
      <button type="button" class="nav" data-v="wifi" title="Alt+F"><svg viewBox="0 0 24 24"><path d="M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M2 9a15 15 0 0 1 20 0"/><circle cx="12" cy="19.5" r="1"/></svg>Wi-Fi</button>
      <button type="button" class="nav" data-v="rep" title="Alt+R"><svg viewBox="0 0 24 24"><path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h5"/></svg>Rapporto</button>
      <div class="foot">
        <p>Selezioni di app, ottimizzazioni e funzionalit&agrave;:</p>
        <div class="row" style="gap:6px"><button type="button" class="btn ghost sm" id="btnSelExport" style="flex:1">Esporta</button><button type="button" class="btn ghost sm" id="btnSelImport" style="flex:1">Importa</button></div>
        <input type="file" id="selFile" accept=".json,application/json" hidden>
        <button type="button" class="btn ghost sm" id="btnClassic">Apri versione classica</button>
      </div>
    </nav>

    <main>
      <!-- SISTEMA -->
      <section class="view on" id="v-sys">
        <div class="head"><div><h2>Sistema</h2><p>Riepilogo di hardware, Windows e rete di questo PC.</p></div>
          <div class="row"><button type="button" class="btn ghost sm" id="btnSysExport">Esporta report</button><button type="button" class="btn sm" id="btnSysRefresh">Aggiorna</button></div></div>
        <div class="grid g3" id="sysGrid"></div>
      </section>

      <!-- INSTALLA -->
      <section class="view" id="v-inst">
        <div class="head"><div><h2>Installa applicazioni</h2><p>Seleziona le app e installale o aggiornale in un clic.</p></div>
          <div class="row"><button type="button" class="btn sm" id="btnUpdates">Aggiorna applicazioni</button></div></div>
        <div class="tool">
          <input class="search" id="appSearch" type="search" placeholder="Cerca un'applicazione... (Ctrl+F)" aria-label="Cerca applicazioni">
          <div class="seg" id="mgrSeg"><button type="button" data-m="Winget" class="on">WinGet</button><button type="button" data-m="Choco">Chocolatey</button></div>
          <span class="count" id="appCount"><b>0</b> selezionate</span>
          <button type="button" class="btn ghost sm" id="btnAppInstalled">Seleziona installate</button>
          <button type="button" class="btn ghost sm" id="btnAppClear">Azzera</button>
          <button type="button" class="btn danger sm" id="btnUninstall">Disinstalla</button>
          <button type="button" class="btn primary sm" id="btnInstall">Installa / Aggiorna</button>
        </div>
        <div class="chips" id="appChips"></div>
        <div id="appList"></div>
      </section>

      <!-- OTTIMIZZA -->
      <section class="view" id="v-tw">
        <div class="head"><div><h2>Ottimizza</h2><p>Privacy, prestazioni e pulizia. Ogni ottimizzazione si pu&ograve; annullare.</p></div>
          <div class="row"><button type="button" class="btn ghost sm" data-preset="Standard">Preset Standard</button><button type="button" class="btn ghost sm" data-preset="Minimal">Preset Minimo</button><button type="button" class="btn ghost sm" data-preset="Advanced">Preset Avanzato</button><button type="button" class="btn ghost sm" data-preset="">Azzera</button></div></div>
        <div class="tool">
          <span class="count" id="twCount"><b>0</b> selezionate</span>
          <label class="count">DNS <select id="dnsSel" aria-label="DNS"></select></label>
          <span style="flex:1"></span>
          <button type="button" class="btn ghost sm" id="btnTwApplied">Seleziona gi&agrave; applicate</button>
          <button type="button" class="btn ghost sm" id="btnTwUndo">Annulla selezionate</button>
          <button type="button" class="btn primary sm" id="btnTwRun">Applica selezionate</button>
        </div>
        <div class="sec"><h3>Ottimizzazioni consigliate <span class="n" id="nEss"></span></h3><div class="items wide" id="twEss"></div></div>
        <details class="adv"><summary>Ottimizzazioni avanzate: usare con attenzione</summary><div class="items wide" id="twAdv"></div></details>
        <div class="sec"><h3>Piano energetico <span class="n">non per i portatili</span></h3><div class="row" id="perfRow"></div></div>
        <div class="sec"><h3>Preferenze di Windows <span class="n">si applicano subito</span></h3><div class="items wide" id="twPref"></div></div>
      </section>

      <!-- APP DI WINDOWS -->
      <section class="view" id="v-appx">
        <div class="head"><div><h2>App di Windows</h2><p>Rimuovi le app preinstallate per tutti gli utenti, anche per i profili creati in seguito, oppure reinstallale.</p></div></div>
        <div class="tool">
          <span class="count" id="axCount"><b>0</b> selezionate</span>
          <span class="count" id="axState"></span>
          <span style="flex:1"></span>
          <button type="button" class="btn ghost sm" id="btnAxInstalled">Seleziona installate</button>
          <button type="button" class="btn ghost sm" id="btnAxClear">Azzera</button>
          <button type="button" class="btn sm" id="btnAxInstall">Reinstalla selezionate</button>
          <button type="button" class="btn danger sm" id="btnAxRemove">Rimuovi selezionate</button>
        </div>
        <div id="axList"></div>
      </section>

      <!-- CONFIGURA -->
      <section class="view" id="v-cfg">
        <div class="head"><div><h2>Configura</h2><p>Funzionalit&agrave; di Windows, correzioni e pannelli classici.</p></div></div>
        <div class="sec"><h3>Funzionalit&agrave; di Windows</h3><div class="items wide" id="featList"></div>
          <div class="row" style="margin-top:12px"><button type="button" class="btn primary sm" id="btnFeat">Installa selezionate</button><span class="note">Alcune funzionalit&agrave; richiedono il riavvio.</span></div></div>
        <div class="sec"><h3>Correzioni</h3><div class="row" id="fixRow"></div></div>
        <div class="sec"><h3>Pannelli classici</h3><div class="row" id="panelRow"></div></div>
        <div class="sec"><h3>Accesso remoto</h3><div class="row" id="remoteRow"></div></div>
      </section>

      <!-- AGGIORNAMENTI -->
      <section class="view" id="v-upd">
        <div class="head"><div><h2>Aggiornamenti di Windows</h2><p>Scegli come Windows Update installa gli aggiornamenti.</p></div></div>
        <div class="grid g3">
          <article class="card upd rec"><h3>Impostazioni predefinite</h3><p>Windows installa tutti gli aggiornamenti in automatico, come da fabbrica.</p><div><button type="button" class="btn primary sm" data-btn="WPFUpdatesdefault" data-label="Aggiornamenti: impostazioni predefinite">Ripristina predefinite</button></div></article>
          <article class="card upd"><h3>Solo sicurezza</h3><p>Installa gli aggiornamenti di sicurezza e rimanda quelli delle funzionalit&agrave;.</p><div><button type="button" class="btn sm" data-btn="WPFUpdatessecurity" data-label="Aggiornamenti: solo sicurezza">Imposta solo sicurezza</button></div></article>
          <article class="card upd"><h3>Disattiva</h3><p>Blocca tutti gli aggiornamenti. Sconsigliato: il PC resta senza correzioni di sicurezza.</p><div><button type="button" class="btn danger sm" data-btn="WPFUpdatesdisable" data-label="Aggiornamenti: disattivati" data-confirm="Si fermano i servizi di aggiornamento e si cancellano gli aggiornamenti scaricati. Il PC non ricever&agrave; aggiornamenti di sicurezza finch&eacute; non ripristini le impostazioni predefinite. Continuare?">Disattiva aggiornamenti</button></div></article>
        </div>
      </section>

      <!-- STAMPANTI -->
      <section class="view" id="v-prn">
        <div class="head"><div><h2>Stampanti</h2><p>Stampanti installate, driver e coda di stampa.</p></div><button type="button" class="btn sm" id="btnPrnRefresh">Aggiorna</button></div>
        <div class="card tcard"><table><thead><tr><th>Stampante</th><th>Driver</th><th>Porta</th><th>Stato</th><th>In coda</th></tr></thead><tbody id="prnBody"></tbody></table></div>
        <div class="row" style="margin-top:14px">
          <button type="button" class="btn sm" id="btnPrnDriver">Installa driver (.inf)</button>
          <button type="button" class="btn ghost sm" id="btnPrnRemove">Rimuovi driver</button>
          <button type="button" class="btn ghost sm" id="btnPrnRestart">Riavvia spooler</button>
          <button type="button" class="btn danger sm" id="btnPrnClear">Svuota coda</button>
          <span class="note" id="prnHint" style="margin:0">Per rimuovere un driver, seleziona prima la stampante.</span>
        </div>
      </section>

      <!-- WIFI -->
      <section class="view" id="v-wifi">
        <div class="head"><div><h2>Reti Wi-Fi salvate</h2><p>Password delle reti memorizzate su questo PC. Con il QR code il telefono si collega senza digitare la password.</p></div>
          <div class="row"><button type="button" class="btn ghost sm" id="btnWifiImport">Importa</button><button type="button" class="btn ghost sm" id="btnWifiExport">Esporta (.zip)</button><button type="button" class="btn ghost sm" id="btnWifiCopy">Copia tutto</button><button type="button" class="btn sm" id="btnWifiRefresh">Aggiorna</button></div></div>
        <div class="card tcard"><table><thead><tr><th>Rete</th><th>Password</th><th>Sicurezza</th><th>Automatica</th><th></th></tr></thead><tbody id="wifiBody"></tbody></table></div>
        <p class="note">L'esportazione crea un file .zip con le password in chiaro, da importare su un altro PC.</p>
      </section>

      <!-- RAPPORTO -->
      <section class="view" id="v-rep">
        <div class="head"><div><h2>Rapporto di intervento</h2><p>Pagina da stampare o salvare in PDF con i dati del PC e le operazioni eseguite con WinRUtil.</p></div>
          <div class="row"><button type="button" class="btn ghost sm" id="btnRepClear">Svuota elenco</button><button type="button" class="btn primary sm" id="btnRepCreate">Crea rapporto</button></div></div>
        <div class="card">
          <div class="form">
            <label>Cliente<input class="fld" id="repCustomer" maxlength="200" autocomplete="off"></label>
            <label>Riferimento (es. n. ticket)<input class="fld" id="repReference" maxlength="200" autocomplete="off"></label>
            <label>Tecnico<input class="fld" id="repTechnician" maxlength="200" autocomplete="off"></label>
            <label class="full">Intestazione (la tua azienda: nome sulla prima riga, poi indirizzo e contatti)<textarea class="fld" id="repHeader" rows="3" maxlength="1000"></textarea></label>
            <label class="full">Note<textarea class="fld" id="repNotes" rows="3" maxlength="4000"></textarea></label>
          </div>
          <p class="note">Tecnico e intestazione vengono ricordati per i prossimi rapporti.</p>
        </div>
        <div class="sec"><h3>Operazioni eseguite <span class="n" id="repN"></span></h3>
          <div class="card tcard"><table><thead><tr><th>Ora</th><th>Categoria</th><th>Operazione</th><th>Esito</th></tr></thead><tbody id="repBody"></tbody></table></div></div>
      </section>
    </main>
  </div>

  <div class="dock" id="dock" aria-live="polite">
    <div class="in">
      <div class="ti"><i class="dot" id="dockDot"></i><span id="dockTitle">Operazione in corso</span></div>
      <div class="row"><span class="lb" id="dockLabel"></span><button type="button" class="btn ghost sm" id="btnLog">Dettagli</button><button type="button" class="btn ghost sm" id="btnDockClose">Chiudi</button></div>
      <div class="bar" id="dockBar"><i id="dockFill"></i></div>
      <div class="log" id="log"></div>
    </div>
  </div>
  <div class="modal" id="modal" role="dialog" aria-modal="true" aria-labelledby="mTitle"><div class="card"><h4 id="mTitle">Confermi?</h4><p id="mText"></p><div class="row" style="justify-content:flex-end"><button type="button" class="btn ghost sm" id="mNo">Annulla</button><button type="button" class="btn primary sm" id="mYes">Continua</button></div></div></div>
  <div class="modal" id="qrModal" role="dialog" aria-modal="true" aria-labelledby="qrTitle"><div class="card">
    <h4 id="qrTitle">QR code della rete Wi-Fi</h4>
    <div class="qr" id="qrBox"></div>
    <div class="qrt"><b id="qrSsid"></b><span class="note" id="qrInfo"></span></div>
    <p class="note" style="text-align:center;margin:10px 0 18px">Inquadralo con la fotocamera del telefono per collegarti. Chi lo inquadra ottiene la password: mostralo solo a chi deve collegarsi.</p>
    <div class="row" style="justify-content:flex-end"><button type="button" class="btn ghost sm" id="qrSave">Salva come immagine</button><button type="button" class="btn primary sm" id="qrClose">Chiudi</button></div>
  </div></div>
  <div class="modal" id="updModal" role="dialog" aria-modal="true" aria-labelledby="updTitle"><div class="card lg">
    <h4 id="updTitle">Aggiorna applicazioni</h4>
    <p id="updStatus"></p>
    <div class="card tcard tscroll"><table><thead><tr><th style="width:34px"><input type="checkbox" id="updAll" aria-label="Seleziona tutte"></th><th>Applicazione</th><th>Installata</th><th>Disponibile</th><th>Esito</th></tr></thead><tbody id="updBody"></tbody></table></div>
    <div class="row" style="justify-content:flex-end;margin-top:14px"><span class="count" id="updCount" style="margin-right:auto"></span><button type="button" class="btn ghost sm" id="updRefresh">Cerca di nuovo</button><button type="button" class="btn ghost sm" id="updClose">Chiudi</button><button type="button" class="btn primary sm" id="updStart">Aggiorna selezionate</button></div>
  </div></div>
  <div class="toast" id="toast"></div>
</div>

<script nonce="__NONCE__">
(function () {
  'use strict';
  var token = (location.hash || '').replace(/^#/, '');
  history.replaceState(null, '', location.pathname);
  var $ = function (id) { return document.getElementById(id); };
  var cat = null, mgr = 'Winget', selApps = {}, selTw = {}, selFeat = {}, selAx = {}, appCats = {}, toggles = {}, logIndex = 0, running = false, pollT = null, wifi = [];
  var afterRun = null, curKind = '', loaded = {};

  function api(method, path, body) {
    return fetch(path, { method: method, cache: 'no-store', headers: { 'X-Token': token, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
      .then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j && j.error ? j.error : 'HTTP ' + r.status); return j; }); });
  }
  /* letture lente: il server risponde "loading" finche' non ha finito */
  function query(path, refresh, every) {
    return new Promise(function (ok, ko) {
      (function ask(r) {
        api('GET', path + (path.indexOf('?') < 0 ? '?' : '&') + (r ? 'refresh=1' : 'refresh=0')).then(function (x) {
          if (x.loading) { setTimeout(function () { ask(false); }, every || 800); return; }
          if (x.error) { ko(new Error(x.error)); return; }
          ok(x.data);
        }).catch(ko);
      })(refresh);
    });
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }
  function toast(msg, err) { var d = el('div', err ? 'e' : '', msg); $('toast').appendChild(d); setTimeout(function () { d.remove(); }, 4500); }
  function confirmBox(title, text, yes) {
    return new Promise(function (ok) {
      $('mTitle').textContent = title; $('mText').textContent = text; $('mYes').textContent = yes || 'Continua'; $('modal').classList.add('on'); $('mYes').focus();
      function done(v) { $('modal').classList.remove('on'); $('mYes').onclick = $('mNo').onclick = null; ok(v); }
      $('mYes').onclick = function () { done(true); }; $('mNo').onclick = function () { done(false); };
    });
  }
  function emptyRow(tb, cols, text) { var tr = el('tr'), td = el('td', 'empty', text); td.colSpan = cols; tr.appendChild(td); tb.appendChild(tr); }
  function skelRow(tb, cols) { tb.innerHTML = ''; var tr = el('tr'), td = el('td'); td.colSpan = cols; td.appendChild(el('div', 'skel')); td.appendChild(el('div', 'skel')); tr.appendChild(td); tb.appendChild(tr); }
  var CHECK = '<svg viewBox="0 0 24 24"><path d="M5 12l5 5 9-10"/></svg>';
  var MASK = new Array(9).join(String.fromCharCode(8226));
  var LEVEL = { Success: 'c-ok', Warning: 'c-warn', Danger: 'c-bad', Error: 'c-bad', Muted: 'c-mu', Running: 'c-mu', Info: 'c-mu' };

  /* ---------- navigazione ---------- */
  function show(v) {
    document.querySelectorAll('.nav').forEach(function (x) { x.classList.toggle('on', x.getAttribute('data-v') === v); });
    document.querySelectorAll('.view').forEach(function (x) { x.classList.toggle('on', x.id === 'v-' + v); });
    window.scrollTo(0, 0);
    if (v === 'wifi' && !loaded.wifi) { loaded.wifi = true; loadWifi(false); }
    if (v === 'tw' && !loaded.tg) { loaded.tg = true; loadToggles(); }
    if (v === 'appx' && !loaded.ax) { loaded.ax = true; loadAppx(false); }
    if (v === 'prn' && !loaded.prn) { loaded.prn = true; loadPrinters(false); }
    if (v === 'rep') { loadReport(!loaded.rep); loaded.rep = true; }
  }
  document.querySelectorAll('.nav').forEach(function (b) { b.addEventListener('click', function () { show(b.getAttribute('data-v')); }); });
  function current() { var o = document.querySelector('.view.on'); return o ? o.id.substring(2) : ''; }

  /* ---------- avvio ---------- */
  api('GET', '/api/info').then(function (i) {
    $('chipPc').lastChild.textContent = i.pc; $('chipVer').textContent = 'v' + i.version;
    setMgr(i.manager === 'Choco' ? 'Choco' : 'Winget', false);
    return api('GET', '/api/catalog');
  }).then(function (c) { cat = c; renderChips(); renderApps(); renderTweaks(); renderConfig(); renderAppx(); loadSystem(false); poll(); })
    .catch(function () { document.body.innerHTML = '<p style="padding:40px;color:#fca5a5">Sessione non valida: riavviare WinRUtil.</p>'; });

  /* ---------- sistema ---------- */
  function sysCard(title, icon, rows, extra, after) {
    var c = el('article', 'card' + (after ? ' wide' : ''));
    var h = el('h3'); h.innerHTML = icon; h.appendChild(document.createTextNode(title)); c.appendChild(h);
    if (extra) extra(c);
    var kv = el('div', 'kv');
    rows.forEach(function (r) { if (r[1] == null || r[1] === '') return; kv.appendChild(el('span', '', r[0])); var b = el('b', '', String(r[1])); if (r[2]) b.id = r[2]; kv.appendChild(b); });
    c.appendChild(kv); if (after) after(c); return c;
  }
  function barEl(pct, warn, id) { var b = el('div', 'bar' + (warn ? ' warn' : '')), i = el('i'); if (id) b.id = id; b.appendChild(i); setTimeout(function () { i.style.width = Math.max(2, Math.min(100, pct || 0)) + '%'; }, 50); return b; }
  function setBar(id, pct, warn) { var b = $(id); if (!b) return; b.classList.toggle('warn', !!warn); b.firstChild.style.width = Math.max(2, Math.min(100, pct || 0)) + '%'; }
  function setText(id, t) { var e = $(id); if (e && t != null) e.textContent = t; }
  var COLOR = { SuccessColor: 'var(--ok)', WarningColor: 'var(--warn)', DangerColor: '#f87171' };
  function pillEl(text, key) { var p = el('span', 'pill', text || ''); p.style.color = COLOR[key] || 'var(--mu)'; var w = el('div'); w.style.marginBottom = '10px'; w.appendChild(p); return w; }
  var IC = {
    win: '<svg viewBox="0 0 24 24"><rect x="3" y="3" width="8" height="8"/><rect x="13" y="3" width="8" height="8"/><rect x="3" y="13" width="8" height="8"/><rect x="13" y="13" width="8" height="8"/></svg>',
    hw: '<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2"/><path d="M9 9h6v6H9z"/></svg>',
    cpu: '<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/></svg>',
    ram: '<svg viewBox="0 0 24 24"><rect x="2" y="7" width="20" height="10" rx="1"/><path d="M6 17v3M10 17v3M14 17v3M18 17v3"/></svg>',
    disk: '<svg viewBox="0 0 24 24"><ellipse cx="12" cy="6" rx="8" ry="3"/><path d="M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6"/></svg>',
    gpu: '<svg viewBox="0 0 24 24"><rect x="2" y="6" width="20" height="12" rx="2"/><circle cx="9" cy="12" r="2.5"/><path d="M15 10h4M15 14h4"/></svg>',
    net: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/></svg>',
    bat: '<svg viewBox="0 0 24 24"><rect x="2" y="7" width="18" height="10" rx="2"/><path d="M22 11v2"/></svg>',
    upd: '<svg viewBox="0 0 24 24"><path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/></svg>'
  };
  function loadSystem(refresh) {
    var g = $('sysGrid');
    if (!g.children.length || refresh) { g.textContent = ''; for (var i = 0; i < 6; i++) { var c = el('div', 'card'); c.appendChild(el('div', 'skel')); c.appendChild(el('div', 'skel')); c.appendChild(el('div', 'skel')); g.appendChild(c); } }
    query('/api/system', refresh, 900).then(function (s) {
      s = s || {}; g.textContent = '';
      g.appendChild(sysCard('Windows', IC.win, [['Versione', s.OSBuild], ['Nome PC', s.Hostname], ['Installato il', s.InstallDate], ['Acceso da', s.Uptime, 'sysUptime']], function (c) {
        c.appendChild(el('div', 'big', s.OSCaption || 'Windows')); c.appendChild(pillEl(s.ActivationText, s.ActivationColorKey));
      }));
      g.appendChild(sysCard('Hardware e sicurezza', IC.hw, [['Produttore', s.Manufacturer], ['Modello', s.Model], ['Numero di serie', s.Serial], ['BIOS', s.Bios], ['Secure Boot', s.SecureBoot], ['TPM', s.Tpm], ['BitLocker', s.BitLocker]]));
      g.appendChild(sysCard('Processore', IC.cpu, [['Core', s.CpuCores], ['Frequenza', s.CpuClock], ['Carico', s.CpuLoad, 'sysCpuLoad']], function (c) { c.appendChild(el('div', 'big', s.CpuName || '')); var b = barEl(s.CpuLoadPct, s.CpuLoadPct >= 90, 'sysCpuBar'); b.style.margin = '0 0 10px'; c.appendChild(b); }));
      g.appendChild(sysCard('Memoria', IC.ram, [['Libera', s.RamFree, 'sysRamFree'], ['Moduli', s.RamModules]], function (c) { var t = el('div', 'big', s.RamText || ''); t.id = 'sysRamText'; c.appendChild(t); var b = barEl(s.RamUsedPct, s.RamUsedPct >= 90, 'sysRamBar'); b.style.margin = '0 0 10px'; c.appendChild(b); }));
      g.appendChild(sysCard('Archiviazione', IC.disk, [], function (c) {
        c.appendChild(pillEl(s.DiskHealthText, s.DiskHealthColorKey));
        (s.Disks || []).forEach(function (d) { var r = el('div'); r.style.margin = '0 0 10px'; var t = el('div', 'kv'); t.appendChild(el('span', '', d.Label)); t.appendChild(el('b', '', d.Text)); r.appendChild(t); var b = barEl(d.UsedPct, d.Warn); b.style.marginTop = '5px'; r.appendChild(b); c.appendChild(r); });
      }));
      g.appendChild(sysCard('Scheda video', IC.gpu, [['Memoria', s.GpuVram], ['Driver', s.GpuDriver], ['Risoluzione', s.GpuResolution]], function (c) { c.appendChild(el('div', 'big', s.GpuName || '')); }));
      g.appendChild(sysCard('Rete', IC.net, [['Stato', s.NetStatus], ['Scheda', s.NetAdapter], ['Indirizzo IP', s.NetIp], ['MAC', s.NetMac]]));
      if (s.HasBattery) g.appendChild(sysCard('Batteria', IC.bat, [['Stato', s.BatteryStatus], ['Usura', s.BatteryHealth]], function (c) { c.appendChild(el('div', 'big', s.BatteryCharge || '')); var b = barEl(s.BatteryPct, s.BatteryPct <= 20); b.style.margin = '0 0 10px'; c.appendChild(b); }));
      g.appendChild(sysCard('Aggiornamenti di Windows', IC.upd, [['Ultima installazione', s.UpdatesLastInstall], ['Ultima ricerca', s.UpdatesLastSearch]], null, function (c) {
        var list = s.UpdatesRecent || [];
        if (!list.length) { c.appendChild(el('p', 'note', 'Nessun aggiornamento nella cronologia.')); return; }
        var t = el('table'), th = el('thead'), hr = el('tr'); ['Data', 'Aggiornamento', 'Esito'].forEach(function (x) { hr.appendChild(el('th', '', x)); }); th.appendChild(hr); t.appendChild(th);
        var tb = el('tbody'); list.forEach(function (u) { var tr = el('tr'); tr.appendChild(el('td', 'nw c-mu', u.Date)); tr.appendChild(el('td', '', u.Title)); tr.appendChild(el('td', 'nw ' + (LEVEL[u.Level] || ''), u.Result)); tb.appendChild(tr); });
        t.appendChild(tb); t.style.marginTop = '12px'; c.appendChild(t);
      }));
    }).catch(function (e) { g.textContent = ''; g.appendChild(el('div', 'empty', 'Informazioni non disponibili: ' + e.message)); });
  }
  $('btnSysRefresh').addEventListener('click', function () { loadSystem(true); });
  $('btnSysExport').addEventListener('click', function () { run('/api/sysexport', {}); });
  /* processore, memoria e tempo di accensione aggiornati ogni 3 secondi, come nella versione classica */
  setInterval(function () {
    if (current() !== 'sys' || document.hidden || !$('sysCpuBar')) return;
    api('GET', '/api/live?refresh=1').then(function (x) {
      if (x.loading || !x.data) return; var d = x.data;
      setText('sysCpuLoad', d.CpuLoad); setBar('sysCpuBar', d.CpuLoadPct, d.CpuLoadPct >= 90);
      setText('sysRamText', d.RamText); setText('sysRamFree', d.RamFree); setBar('sysRamBar', d.RamUsedPct, d.RamUsedPct >= 90); setText('sysUptime', d.Uptime);
    }).catch(function () { });
  }, 3000);

  /* ---------- elementi selezionabili ---------- */
  function selItem(o, store, onChange, icon, tag) {
    var lab = el('label', 'it' + (store[o.id] ? ' sel' : ''));
    var inp = el('input'); inp.type = 'checkbox'; inp.checked = !!store[o.id]; lab.appendChild(inp);
    var bx = el('span', 'box'); bx.innerHTML = CHECK; lab.appendChild(bx);
    if (icon) lab.appendChild(icon);
    var tx = el('div'); tx.style.minWidth = '0'; tx.style.flex = '1';
    var t = el('div', 't', o.name); if (o.foss) t.appendChild(el('span', 'foss', 'FOSS')); if (tag) t.appendChild(el('span', 'tag', tag)); tx.appendChild(t);
    if (o.desc) { var d = el('div', 'd', o.desc); d.title = o.desc; tx.appendChild(d); }
    lab.appendChild(tx);
    inp.addEventListener('change', function () { if (inp.checked) store[o.id] = true; else delete store[o.id]; lab.classList.toggle('sel', inp.checked); onChange(); });
    lab._set = function (v) { inp.checked = v; lab.classList.toggle('sel', v); };
    return lab;
  }
  function groupBy(arr, key) { var m = {}, order = []; arr.forEach(function (x) { var k = x[key] || 'Altro'; if (!m[k]) { m[k] = []; order.push(k); } m[k].push(x); }); return order.sort().map(function (k) { return [k, m[k]]; }); }
  function countHtml(id, n) { $(id).innerHTML = '<b>' + n + '</b> selezionate'; }

  /* ---------- installa ---------- */
  var CAT_IT = { 'Browsers': 'Browser', 'Communications': 'Comunicazione', 'Development': 'Sviluppo', 'Document': 'Documenti', 'Games': 'Giochi', 'Microsoft Tools': 'Strumenti Microsoft', 'Multimedia Tools': 'Multimedia', 'Pro Tools': 'Strumenti professionali', 'Selfhosted Tools': 'Self-hosted', 'Utilities': 'Utilit\u00e0' };
  function catName(c) { return CAT_IT[c] || c; }
  function appCount() { countHtml('appCount', Object.keys(selApps).length); }
  /* icona del sito dell'app (come la versione classica), con l'iniziale finche' l'icona manca */
  function appIcon(a) {
    var w = el('span', 'ico'), f = el('b', '', ((a.name || '?').replace(/^\./, '').charAt(0) || '?').toUpperCase()); w.appendChild(f);
    if (a.link && /^https?:/i.test(a.link)) {
      var im = new Image(); im.alt = ''; im.loading = 'lazy'; im.decoding = 'async'; im.referrerPolicy = 'no-referrer';
      im.onload = function () { if (im.naturalWidth > 1) f.style.visibility = 'hidden'; else im.remove(); };
      im.onerror = function () { im.remove(); };
      im.src = 'https://www.google.com/s2/favicons?sz=64&domain_url=' + encodeURIComponent(a.link);
      w.appendChild(im);
    }
    return w;
  }
  function renderChips() {
    var box = $('appChips'), cats = groupBy(cat.apps, 'cat');
    var all = el('button', 'cchip on', 'Tutte'); all.type = 'button'; all.setAttribute('data-c', ''); box.appendChild(all);
    cats.forEach(function (g) { var b = el('button', 'cchip', catName(g[0]) + ' ' + g[1].length); b.type = 'button'; b.setAttribute('data-c', g[0]); box.appendChild(b); });
    box.title = 'Ctrl+clic per combinare pi\u00f9 categorie';
    box.addEventListener('click', function (e) {
      var b = e.target.closest('.cchip'); if (!b) return; var c = b.getAttribute('data-c');
      if (!c) appCats = {};
      else if (e.ctrlKey) { if (appCats[c]) delete appCats[c]; else appCats[c] = true; }
      else { var only = Object.keys(appCats).length === 1 && appCats[c]; appCats = {}; if (!only) appCats[c] = true; }
      box.querySelectorAll('.cchip').forEach(function (x) { var k = x.getAttribute('data-c'); x.classList.toggle('on', k ? !!appCats[k] : !Object.keys(appCats).length); });
      renderApps();
    });
  }
  function renderApps() {
    var q = ($('appSearch').value || '').toLowerCase(), box = $('appList'), anyCat = Object.keys(appCats).length > 0; box.textContent = '';
    var list = cat.apps.filter(function (a) { return (!anyCat || appCats[a.cat]) && (!q || (a.name + ' ' + a.desc).toLowerCase().indexOf(q) >= 0); });
    if (!list.length) { box.appendChild(el('div', 'empty', 'Nessuna applicazione trovata.')); return; }
    groupBy(list, 'cat').forEach(function (g) {
      var s = el('div', 'sec'), h = el('h3', '', catName(g[0])); h.appendChild(el('span', 'n', String(g[1].length))); s.appendChild(h);
      var it = el('div', 'items');
      g[1].sort(function (a, b) { return a.name.localeCompare(b.name); }).forEach(function (a) { it.appendChild(selItem(a, selApps, appCount, appIcon(a))); });
      s.appendChild(it); box.appendChild(s);
    });
  }
  var st; $('appSearch').addEventListener('input', function () { clearTimeout(st); st = setTimeout(renderApps, 150); });
  function setMgr(m, save) { mgr = m; document.querySelectorAll('#mgrSeg button').forEach(function (b) { b.classList.toggle('on', b.getAttribute('data-m') === m); }); if (save) api('POST', '/api/manager', { manager: m }); }
  document.querySelectorAll('#mgrSeg button').forEach(function (b) { b.addEventListener('click', function () { setMgr(b.getAttribute('data-m'), true); }); });
  $('btnAppClear').addEventListener('click', function () { selApps = {}; renderApps(); appCount(); });
  $('btnInstall').addEventListener('click', function () { run('/api/apps', { ids: Object.keys(selApps), manager: mgr, action: 'Install' }); });
  $('btnUninstall').addEventListener('click', function () {
    var n = Object.keys(selApps).length; if (!n) { toast('Seleziona almeno un\'applicazione.', true); return; }
    confirmBox('Disinstallare ' + n + ' applicazioni?', 'Le applicazioni selezionate verranno rimosse dal PC.', 'Disinstalla').then(function (ok) { if (ok) run('/api/apps', { ids: Object.keys(selApps), manager: mgr, action: 'Uninstall' }); });
  });
  function busyBtn(b, on, text) { if (on) { b._t = b.textContent; b.disabled = true; b.innerHTML = '<span class="spin"></span>' + text; } else { b.disabled = false; b.textContent = b._t; } }
  $('btnAppInstalled').addEventListener('click', function () {
    var b = this; busyBtn(b, true, 'Ricerca...');
    query('/api/installed?manager=' + mgr, true, 1200).then(function (ids) {
      var n = 0; (ids || []).forEach(function (i) { if (!selApps[i]) { selApps[i] = true; n++; } });
      renderApps(); appCount(); toast('App dell\'elenco installate su questo PC: ' + (ids || []).length + '.');
    }).catch(function (e) { toast('Ricerca non riuscita: ' + e.message, true); }).then(function () { busyBtn(b, false); });
  });

  /* ---------- aggiornamento delle applicazioni scelte ---------- */
  var updList = [], updSel = {}, updDone = {};
  function openUpdates() { $('updModal').classList.add('on'); if (!updList.length) loadUpdates(false); }
  function updCount() {
    var open = updList.filter(function (u) { return !updDone[u.id]; }), n = open.filter(function (u) { return updSel[u.id]; }).length;
    $('updCount').textContent = open.length ? n + ' di ' + open.length + ' selezionate' : '';
    $('updAll').checked = open.length > 0 && n === open.length; $('updStart').disabled = running || n === 0; $('updRefresh').disabled = running;
  }
  function renderUpdates(results) {
    var tb = $('updBody'); tb.textContent = '';
    if (!updList.length) { emptyRow(tb, 5, 'Nessun aggiornamento disponibile: tutte le applicazioni sono aggiornate.'); updCount(); return; }
    updList.forEach(function (u) {
      var tr = el('tr'), td = el('td'), cb = el('input'); cb.type = 'checkbox'; cb.checked = !!updSel[u.id]; cb.disabled = !!updDone[u.id] || running; cb.setAttribute('aria-label', u.name);
      cb.addEventListener('change', function () { if (cb.checked) updSel[u.id] = true; else delete updSel[u.id]; updCount(); });
      td.appendChild(cb); tr.appendChild(td);
      var n = el('td'); n.appendChild(el('div', '', u.name)); var sm = el('div', 'note', u.id); sm.style.margin = '0'; n.appendChild(sm); tr.appendChild(n);
      tr.appendChild(el('td', 'nw c-mu', u.version || '?')); tr.appendChild(el('td', 'nw', u.available));
      var r = results && results[u.id]; tr.appendChild(el('td', 'nw ' + (r ? (LEVEL[r.l] || '') : ''), r ? r.t : ''));
      tb.appendChild(tr);
    });
    updCount();
  }
  function loadUpdates(refresh) {
    updList = []; updSel = {}; updDone = {}; skelRow($('updBody'), 5);
    $('updStatus').innerHTML = '<span class="spin"></span>Ricerca degli aggiornamenti con ' + (mgr === 'Choco' ? 'Chocolatey' : 'WinGet') + ' in corso (pu\u00f2 richiedere un minuto)...';
    $('updStart').disabled = true; $('updRefresh').disabled = true;
    query('/api/updates?manager=' + mgr, refresh, 1500).then(function (list) {
      updList = list || []; updList.forEach(function (u) { if (u.selected) updSel[u.id] = true; });
      var t = updList.length === 0 ? 'Nessun aggiornamento disponibile.' : (updList.length === 1 ? '1 aggiornamento disponibile.' : updList.length + ' aggiornamenti disponibili.');
      if (updList.length) t += ' Scegli quali installare.';
      if (updList.some(function (u) { return !u.selected; })) t += ' Non sono preselezionate le app con versione sconosciuta e quelle che WinGet aggiorna solo su richiesta.';
      $('updStatus').textContent = t; renderUpdates();
    }).catch(function (e) { $('updStatus').textContent = 'Impossibile cercare gli aggiornamenti: ' + e.message; $('updBody').textContent = ''; updCount(); });
  }
  $('btnUpdates').addEventListener('click', openUpdates);
  $('updRefresh').addEventListener('click', function () { loadUpdates(true); });
  $('updClose').addEventListener('click', function () { $('updModal').classList.remove('on'); });
  $('updAll').addEventListener('change', function () { var v = this.checked; updList.forEach(function (u) { if (!updDone[u.id]) { if (v) updSel[u.id] = true; else delete updSel[u.id]; } }); renderUpdates(lastResults); });
  var lastResults = null;
  $('updStart').addEventListener('click', function () {
    var ids = updList.filter(function (u) { return updSel[u.id] && !updDone[u.id]; }).map(function (u) { return u.id; });
    run('/api/updates', { ids: ids, manager: mgr }, function (s) {
      Object.keys(s.results || {}).forEach(function (k) { if (s.results[k].ok) { updDone[k] = true; delete updSel[k]; } });
      $('updStatus').textContent = 'Aggiornamento terminato: vedi l\'esito di ogni applicazione.'; renderUpdates(s.results);
    });
  });

  /* ---------- ottimizza ---------- */
  var twEls = {};
  function twCount() { countHtml('twCount', Object.keys(selTw).length); }
  function renderTweaks() {
    var ess = $('twEss'), adv = $('twAdv'), pref = $('twPref'), perf = $('perfRow');
    var plain = cat.tweaks.filter(function (t) { return !t.type; });
    plain.filter(function (t) { return !t.advanced; }).forEach(function (t) { var e = selItem(t, selTw, twCount); twEls[t.id] = e; ess.appendChild(e); });
    $('nEss').textContent = String(plain.filter(function (t) { return !t.advanced; }).length);
    var wb = el('div', 'warnbox', 'Queste modifiche sono profonde: applicale solo se sai cosa fanno. Il punto di ripristino \u00e8 consigliato.'); wb.style.gridColumn = '1/-1'; adv.appendChild(wb);
    plain.filter(function (t) { return t.advanced; }).forEach(function (t) { var e = selItem(t, selTw, twCount); twEls[t.id] = e; adv.appendChild(e); });
    cat.tweaks.filter(function (t) { return t.type === 'Button'; }).forEach(function (t) {
      var b = el('button', 'btn sm', t.name); b.type = 'button'; b.title = t.desc || '';
      if (t.id === 'WPFAddUltPerf' || t.id === 'WPFRemoveUltPerf') perf.appendChild(b);
      else if (t.advanced) { adv.appendChild(b); b.style.justifySelf = 'start'; } else perf.appendChild(b);
      b.addEventListener('click', function () { run('/api/button', { id: t.id, label: t.name }); });
    });
    cat.tweaks.filter(function (t) { return t.type === 'Toggle'; }).forEach(function (t) {
      var r = el('div', 'sw'), tx = el('div'); tx.appendChild(el('div', 't', t.name)); if (t.desc) tx.appendChild(el('div', 'd', t.desc)); r.appendChild(tx);
      var b = el('button', 'tg'); b.type = 'button'; b.setAttribute('role', 'switch'); b.setAttribute('aria-label', t.name); b.disabled = true; b.id = 'tg_' + t.id; r.appendChild(b);
      b.addEventListener('click', function () {
        var on = !b.classList.contains('on');
        api('POST', '/api/toggle', { id: t.id, on: on }).then(function () { b.classList.toggle('on', on); b.setAttribute('aria-checked', on); startPoll(); }).catch(function (e) { toast(e.message, true); });
      });
      pref.appendChild(r);
    });
    (cat.combos || []).forEach(function (c) {
      var r = el('div', 'sw'), tx = el('div'); tx.appendChild(el('div', 't', c.name)); var d = el('div', 'd', c.desc || ''); tx.appendChild(d); r.appendChild(tx);
      var s = el('select'); s.id = 'cb_' + c.id; s.disabled = true; s.setAttribute('aria-label', c.name); s.style.maxWidth = '210px';
      c.items.forEach(function (i) { var o = el('option', '', i); o.value = i; o.title = (c.descs || {})[i] || ''; s.appendChild(o); });
      s.addEventListener('change', function () { var v = s.value; d.textContent = (c.descs || {})[v] || c.desc || ''; run('/api/combo', { id: c.id, state: v }); });
      r.appendChild(s); pref.appendChild(r);
    });
    var ds = $('dnsSel'); cat.dns.forEach(function (d) { var o = el('option', '', d === 'Default' ? 'Non cambiare' : (d === 'DHCP' ? 'Automatico (DHCP)' : (d === 'Fastest' ? 'Il pi\u00f9 veloce (misurato ora)' : d.replace(/_/g, ' ')))); o.value = d; ds.appendChild(o); });
    document.querySelectorAll('[data-preset]').forEach(function (b) {
      b.addEventListener('click', function () {
        var p = b.getAttribute('data-preset'), ids = p ? (cat.presets[p] || []) : [];
        selTw = {}; ids.forEach(function (i) { if (twEls[i]) selTw[i] = true; });
        Object.keys(twEls).forEach(function (i) { twEls[i]._set(!!selTw[i]); }); twCount();
      });
    });
  }
  function loadToggles() {
    api('GET', '/api/toggles').then(function (t) { toggles = t; Object.keys(t).forEach(function (k) { var b = $('tg_' + k); if (b) { b.classList.toggle('on', !!t[k]); b.setAttribute('aria-checked', !!t[k]); b.disabled = false; } }); })
      .catch(function () { document.querySelectorAll('.tg').forEach(function (b) { b.disabled = false; }); });
    api('GET', '/api/combos').then(function (c) { Object.keys(c).forEach(function (k) { var s = $('cb_' + k); if (s) { if (c[k]) s.value = c[k]; s.disabled = false; } }); })
      .catch(function () { document.querySelectorAll('[id^="cb_"]').forEach(function (s) { s.disabled = false; }); });
  }
  $('btnTwRun').addEventListener('click', function () { run('/api/tweaks', { ids: Object.keys(selTw), undo: false, dns: $('dnsSel').value }); });
  $('btnTwUndo').addEventListener('click', function () { run('/api/tweaks', { ids: Object.keys(selTw), undo: true, dns: 'Default' }); });
  $('btnTwApplied').addEventListener('click', function () {
    var b = this; busyBtn(b, true, 'Controllo...');
    query('/api/applied', true, 1000).then(function (ids) {
      var n = 0; (ids || []).forEach(function (i) { if (twEls[i]) { selTw[i] = true; twEls[i]._set(true); n++; } }); twCount();
      toast(n ? 'Ottimizzazioni gi\u00e0 applicate: ' + n + '.' : 'Nessuna ottimizzazione dell\'elenco risulta applicata.');
    }).catch(function (e) { toast('Controllo non riuscito: ' + e.message, true); }).then(function () { busyBtn(b, false); });
  });

  /* ---------- app di Windows ---------- */
  var axEls = {}, axInstalled = null;
  function axCount() { countHtml('axCount', Object.keys(selAx).length); }
  function renderAppx() {
    var box = $('axList'); box.textContent = ''; axEls = {};
    if (!cat.appx || !cat.appx.length) { box.appendChild(el('div', 'empty', 'Nessuna app nell\'elenco.')); return; }
    groupBy(cat.appx, 'cat').forEach(function (g) {
      var s = el('div', 'sec'), h = el('h3', '', g[0]); h.appendChild(el('span', 'n', String(g[1].length))); s.appendChild(h);
      var it = el('div', 'items wide');
      g[1].sort(function (a, b) { return a.name.localeCompare(b.name); }).forEach(function (a) {
        var tag = axInstalled ? (axInstalled[a.id] ? 'Installata' : 'Non installata') : null;
        var e = selItem(a, selAx, axCount, null, tag); axEls[a.id] = e; it.appendChild(e);
      });
      s.appendChild(it); box.appendChild(s);
    });
  }
  function loadAppx(refresh) {
    $('axState').innerHTML = '<span class="spin"></span>Lettura delle app installate...';
    return query('/api/appx', refresh, 1000).then(function (ids) {
      axInstalled = {}; (ids || []).forEach(function (i) { axInstalled[i] = true; });
      $('axState').textContent = 'Installate su questo PC: ' + (ids || []).length + ' di ' + cat.appx.length + '.'; renderAppx();
      return ids || [];
    }).catch(function (e) { $('axState').textContent = 'Lettura non riuscita: ' + e.message; return []; });
  }
  $('btnAxInstalled').addEventListener('click', function () { loadAppx(true).then(function (ids) { ids.forEach(function (i) { selAx[i] = true; if (axEls[i]) axEls[i]._set(true); }); axCount(); }); });
  $('btnAxClear').addEventListener('click', function () { selAx = {}; Object.keys(axEls).forEach(function (i) { axEls[i]._set(false); }); axCount(); });
  $('btnAxInstall').addEventListener('click', function () { run('/api/appx', { ids: Object.keys(selAx), action: 'Install' }); });
  $('btnAxRemove').addEventListener('click', function () {
    var ids = Object.keys(selAx); if (!ids.length) { toast('Seleziona almeno un\'app di Windows.', true); return; }
    var names = cat.appx.filter(function (a) { return selAx[a.id]; }).map(function (a) { return a.name; });
    confirmBox('Rimuovere ' + ids.length + ' app di Windows?', 'Per tutti gli utenti: ' + names.slice(0, 8).join(', ') + (names.length > 8 ? '...' : '') + '. Potrai reinstallarle con "Reinstalla selezionate".', 'Rimuovi').then(function (ok) { if (ok) run('/api/appx', { ids: ids, action: 'Remove' }); });
  });

  /* ---------- configura ---------- */
  var featEls = {};
  function renderConfig() {
    cat.features.forEach(function (f) {
      if (!f.type) { var e = selItem(f, selFeat, function () { }); featEls[f.id] = e; $('featList').appendChild(e); return; }
      var row = /riparaz|fixes/i.test(f.cat) ? 'fixRow' : (/pannelli|panels/i.test(f.cat) ? 'panelRow' : 'remoteRow');
      var b = el('button', 'btn sm', f.name); b.type = 'button'; b.title = f.desc || '';
      b.addEventListener('click', function () { run('/api/button', { id: f.id, label: f.name }); });
      $(row).appendChild(b);
    });
  }
  $('btnFeat').addEventListener('click', function () { run('/api/features', { ids: Object.keys(selFeat) }); });
  document.querySelectorAll('[data-btn]').forEach(function (b) {
    b.addEventListener('click', function () {
      var go = function () { run('/api/button', { id: b.getAttribute('data-btn'), label: b.getAttribute('data-label') }); };
      var c = b.getAttribute('data-confirm');
      if (c) confirmBox('Sei sicuro?', c).then(function (ok) { if (ok) go(); }); else go();
    });
  });

  /* ---------- stampanti ---------- */
  var prnSel = null;
  var PRN = { Normal: 'Pronta', Idle: 'Pronta', Printing: 'In stampa', Offline: 'Non in linea', Error: 'Errore', Paused: 'In pausa', PaperJam: 'Carta inceppata', PaperOut: 'Carta esaurita', PaperProblem: 'Problema con la carta', TonerLow: 'Toner in esaurimento', NoToner: 'Toner esaurito', DoorOpen: 'Sportello aperto', Busy: 'Occupata', Processing: 'In elaborazione', Warmup: 'Riscaldamento', NotAvailable: 'Non disponibile', OutputBinFull: 'Vassoio di uscita pieno', UserIntervention: 'Richiede intervento', PendingDeletion: 'In rimozione' };
  function loadPrinters(refresh) {
    var tb = $('prnBody'); skelRow(tb, 5); prnSel = null; $('btnPrnRemove').disabled = true;
    query('/api/printers', refresh, 700).then(function (list) {
      tb.textContent = ''; list = list || [];
      if (!list.length) { emptyRow(tb, 5, 'Nessuna stampante installata.'); return; }
      list.forEach(function (p) {
        var tr = el('tr', 'pick'); tr.tabIndex = 0;
        tr.appendChild(el('td', '', p.name)); tr.appendChild(el('td', '', p.driver)); tr.appendChild(el('td', 'c-mu', p.port));
        var ok = /^(Normal|Idle|Printing)$/.test(p.status); tr.appendChild(el('td', 'nw ' + (ok ? 'c-ok' : 'c-warn'), PRN[p.status] || p.status)); tr.appendChild(el('td', '', String(p.jobs)));
        var pick = function () { tb.querySelectorAll('tr').forEach(function (x) { x.classList.toggle('sel', x === tr); }); prnSel = p; $('btnPrnRemove').disabled = running; $('prnHint').textContent = 'Selezionata: ' + p.name + ' (driver ' + p.driver + ')'; };
        tr.addEventListener('click', pick); tr.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); pick(); } });
        tb.appendChild(tr);
      });
    }).catch(function (e) { tb.textContent = ''; emptyRow(tb, 5, 'Impossibile elencare le stampanti: ' + e.message); });
  }
  $('btnPrnRefresh').addEventListener('click', function () { loadPrinters(true); });
  $('btnPrnDriver').addEventListener('click', function () { run('/api/printer', { action: 'driver' }); });
  $('btnPrnRestart').addEventListener('click', function () { run('/api/printer', { action: 'restart' }); });
  $('btnPrnRemove').addEventListener('click', function () {
    if (!prnSel) { toast('Seleziona prima una stampante.', true); return; }
    confirmBox('Rimuovere il driver?', 'Il driver "' + prnSel.driver + '" viene rimosso da Windows. Se una stampante lo usa ancora, la rimozione non riesce.', 'Rimuovi').then(function (ok) { if (ok) run('/api/printer', { action: 'remove', driver: prnSel.driver }); });
  });
  $('btnPrnClear').addEventListener('click', function () {
    confirmBox('Svuotare la coda di stampa?', 'Tutti i documenti in attesa di stampa vengono cancellati e lo spooler viene riavviato.', 'Svuota').then(function (ok) { if (ok) run('/api/printer', { action: 'clear' }); });
  });

  /* ---------- wifi ---------- */
  var qrNet = null;
  function loadWifi(refresh) {
    var tb = $('wifiBody'); skelRow(tb, 5);
    query('/api/wifi', refresh, 700).then(function (list) {
      wifi = list || []; tb.textContent = '';
      if (!wifi.length) { emptyRow(tb, 5, 'Nessuna rete Wi-Fi salvata.'); return; }
      wifi.forEach(function (w) {
        var tr = el('tr'); tr.appendChild(el('td', '', w.ssid));
        var td = el('td'), pw = el('span', 'pw', w.password ? MASK : '(nessuna)'); td.appendChild(pw);
        if (w.password) {
          var eye = el('button', 'ib', 'Mostra'); eye.type = 'button';
          eye.addEventListener('click', function () { var s = eye.textContent === 'Mostra'; pw.textContent = s ? w.password : MASK; eye.textContent = s ? 'Nascondi' : 'Mostra'; });
          var cp = el('button', 'ib', 'Copia'); cp.type = 'button';
          cp.addEventListener('click', function () { copy(w.password, 'Password copiata.'); });
          td.appendChild(eye); td.appendChild(cp);
        }
        tr.appendChild(td); tr.appendChild(el('td', '', w.security)); tr.appendChild(el('td', '', w.auto));
        var qa = el('td', 'nw'), qb = el('button', 'ib', 'QR code'); qb.type = 'button'; qb.disabled = !w.canShare;
        qb.title = w.canShare ? 'Mostra il QR code per collegare un telefono' : (/Enterprise/.test(w.security) ? 'Non disponibile: le reti aziendali usano credenziali personali' : 'Non disponibile: password non salvata su questo PC');
        qb.addEventListener('click', function () { showQr(w); }); qa.appendChild(qb); tr.appendChild(qa);
        tb.appendChild(tr);
      });
    }).catch(function (e) { tb.textContent = ''; toast(e.message, true); });
  }
  function showQr(w) {
    api('POST', '/api/wifiqr', { ssid: w.ssid }).then(function (q) {
      var n = q.size, q4 = n + 8, d = '';
      for (var y = 0; y < n; y++) { var x = 0; while (x < n) { if (q.modules.charAt(y * n + x) !== '1') { x++; continue; } var s = x; while (x < n && q.modules.charAt(y * n + x) === '1') x++; d += 'M' + (s + 4) + ' ' + (y + 4) + 'h' + (x - s) + 'v1h-' + (x - s) + 'z'; } }
      var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'), bg = document.createElementNS(ns, 'rect'), p = document.createElementNS(ns, 'path');
      svg.setAttribute('viewBox', '0 0 ' + q4 + ' ' + q4); svg.setAttribute('role', 'img'); svg.setAttribute('aria-label', 'QR code della rete ' + q.ssid);
      bg.setAttribute('width', q4); bg.setAttribute('height', q4); bg.setAttribute('fill', '#fff'); p.setAttribute('d', d); p.setAttribute('fill', '#000');
      svg.appendChild(bg); svg.appendChild(p);
      var box = $('qrBox'); box.textContent = ''; box.appendChild(svg);
      $('qrSsid').textContent = q.ssid; $('qrInfo').textContent = q.open ? 'Rete aperta, senza password' : 'Sicurezza: ' + q.security;
      qrNet = q.ssid; $('qrModal').classList.add('on'); $('qrClose').focus();
    }).catch(function (e) { toast(e.message, true); });
  }
  function closeQr() { $('qrModal').classList.remove('on'); $('qrBox').textContent = ''; qrNet = null; }
  $('qrClose').addEventListener('click', closeQr);
  $('qrSave').addEventListener('click', function () { if (qrNet) run('/api/wifiqrsave', { ssid: qrNet }); });
  function copy(text, msg) {
    var done = function () { toast(msg); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback); else fallback();
    function fallback() { var t = el('textarea'); t.value = text; document.body.appendChild(t); t.select(); try { document.execCommand('copy'); done(); } catch (e) { toast('Copia non riuscita.', true); } t.remove(); }
  }
  $('btnWifiRefresh').addEventListener('click', function () { loadWifi(true); });
  $('btnWifiExport').addEventListener('click', function () { run('/api/wifiexport', {}); });
  $('btnWifiImport').addEventListener('click', function () { run('/api/wifiimport', {}, function () { loadWifi(true); }); });
  $('btnWifiCopy').addEventListener('click', function () {
    if (!wifi.length) { toast('Nessuna rete da copiare.', true); return; }
    copy('Rete\tPassword\tSicurezza\n' + wifi.map(function (w) { return w.ssid + '\t' + w.password + '\t' + w.security; }).join('\n'), 'Elenco copiato negli appunti.');
  });

  /* ---------- rapporto ---------- */
  var REP_ST = { Success: 'c-ok', Error: 'c-bad', Info: 'c-mu' };
  function loadReport(first) {
    api('GET', '/api/report').then(function (r) {
      if (first) { if (!$('repTechnician').value) $('repTechnician').value = r.technician || ''; if (!$('repHeader').value) $('repHeader').value = r.header || ''; }
      var tb = $('repBody'); tb.textContent = ''; var a = r.actions || [];
      $('repN').textContent = String(a.length);
      if (!a.length) { emptyRow(tb, 4, 'Nessuna operazione eseguita in questa sessione. Le operazioni fatte con WinRUtil compaiono qui.'); return; }
      a.forEach(function (x) { var tr = el('tr'); tr.appendChild(el('td', 'nw c-mu', x.time)); tr.appendChild(el('td', 'nw', x.area)); tr.appendChild(el('td', '', x.text)); tr.appendChild(el('td', 'nw ' + (REP_ST[x.status] || ''), x.result)); tb.appendChild(tr); });
    }).catch(function (e) { toast(e.message, true); });
  }
  $('btnRepCreate').addEventListener('click', function () {
    run('/api/report', { customer: $('repCustomer').value, reference: $('repReference').value, technician: $('repTechnician').value, header: $('repHeader').value, notes: $('repNotes').value });
  });
  $('btnRepClear').addEventListener('click', function () {
    if ($('repN').textContent === '0') return;
    confirmBox('Svuotare l\'elenco?', 'Le operazioni tolte non compariranno nel rapporto.', 'Svuota').then(function (ok) { if (ok) api('POST', '/api/report/clear', {}).then(function () { loadReport(false); }); });
  });

  /* ---------- esporta / importa le selezioni (stesso file della versione classica) ---------- */
  $('btnSelExport').addEventListener('click', function () {
    var ids = Object.keys(selApps).concat(Object.keys(selTw), Object.keys(selFeat), Object.keys(selAx));
    if (!ids.length) { toast('Non hai selezionato nulla da esportare.', true); return; }
    var a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([JSON.stringify(ids, null, 2)], { type: 'application/json' }));
    a.download = 'WinRUtil-selezioni.json'; a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); }, 5000);
    toast('Selezioni esportate nella cartella Download.');
  });
  $('btnSelImport').addEventListener('click', function () { $('selFile').value = ''; $('selFile').click(); });
  $('selFile').addEventListener('change', function () {
    var f = this.files && this.files[0]; if (!f) return;
    f.text().then(function (t) {
      var j = JSON.parse(t), ids = [];
      if (Array.isArray(j)) ids = j; else if (j && typeof j === 'object') Object.keys(j).forEach(function (k) { if (/^WPF(Install|Tweaks|Toggle|Feature|Appx)/.test(k)) [].concat(j[k]).forEach(function (v) { if (typeof v === 'string') ids.push(v); }); });
      var known = {};
      selApps = {}; selTw = {}; selFeat = {}; selAx = {};
      cat.apps.forEach(function (a) { known[a.id] = 'a'; }); Object.keys(twEls).forEach(function (i) { known[i] = 't'; }); Object.keys(featEls).forEach(function (i) { known[i] = 'f'; }); (cat.appx || []).forEach(function (a) { known[a.id] = 'x'; });
      var n = 0, skip = 0, store = { a: selApps, t: selTw, f: selFeat, x: selAx };
      ids.forEach(function (i) { i = String(i); if (known[i]) { store[known[i]][i] = true; n++; } else if (!/^WPFToggle/.test(i)) skip++; });
      renderApps(); appCount(); Object.keys(twEls).forEach(function (i) { twEls[i]._set(!!selTw[i]); }); twCount();
      Object.keys(featEls).forEach(function (i) { featEls[i]._set(!!selFeat[i]); }); renderAppx(); axCount();
      toast('Importate ' + n + ' selezioni' + (skip ? ' (' + skip + ' voci non esistono in questa versione)' : '') + '. Controllale prima di applicarle.', !n);
    }).catch(function () { toast('File non valido: scegli un file .json esportato da WinRUtil.', true); });
  });

  /* ---------- operazioni e attivita' ---------- */
  function run(path, body, onDone) {
    if (running) { toast('Attendi la fine dell\'operazione in corso.', true); return; }
    api('POST', path, body).then(function () { running = true; afterRun = onDone || null; setBusy(true); $('dock').classList.add('on'); startPoll(); })
      .catch(function (e) { toast(e.message, true); });
  }
  var FREE = { btnSysRefresh: 1, btnWifiRefresh: 1, btnWifiCopy: 1, btnPrnRefresh: 1, qrClose: 1, updClose: 1, btnSelExport: 1, btnSelImport: 1 };
  function setBusy(b) {
    document.querySelectorAll('main .btn, .tg, main select, .side .foot .btn, .modal .btn').forEach(function (x) { if (!FREE[x.id] && x.closest('#modal') === null) x.disabled = b; });
    if (!b) { $('btnPrnRemove').disabled = !prnSel; if (loaded.tg) loadToggles(); }
    updCount();
  }
  function finished(s) {
    var k = s.kind;
    if (afterRun) { try { afterRun(s); } catch (e) { } afterRun = null; }
    if (k === 'appx' && loaded.ax) loadAppx(true);
    if (k === 'printer' && loaded.prn) loadPrinters(true);
    if (loaded.rep) loadReport(false);
  }
  function startPoll() { clearTimeout(pollT); poll(); }
  function poll() {
    api('GET', '/api/status?since=' + logIndex).then(function (s) {
      var box = $('log'), atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
      (s.log || []).forEach(function (l) { var d = el('div', l.c || ''); d.appendChild(el('span', 'tm', l.t)); d.appendChild(document.createTextNode(l.m)); box.appendChild(d); });
      logIndex = s.logIndex; if (atBottom) box.scrollTop = box.scrollHeight;
      if (s.phase === 'running' || s.phase === 'done') $('dock').classList.add('on');
      $('dockTitle').textContent = s.title || 'Operazione';
      $('dockLabel').textContent = s.phase === 'running' ? (s.label || '') : (s.error ? 'Terminata con errori' : 'Completata');
      $('dockFill').style.width = (s.phase === 'running' ? Math.max(4, s.percent) : 100) + '%';
      $('dockBar').classList.toggle('indet', s.phase === 'running' && s.percent <= 0);
      $('dockDot').className = 'dot' + (s.phase === 'running' ? '' : (s.error ? ' err' : ' done'));
      if (s.kind === 'upgradesel') { lastResults = s.results; if ($('updModal').classList.contains('on')) renderUpdates(s.results); }
      var was = running; running = s.phase === 'running';
      if (was && !running) { setBusy(false); finished(s); toast(s.error ? 'Operazione terminata con errori: vedi Dettagli.' : 'Operazione completata.', !!s.error); }
      if (running && !was) setBusy(true);
      pollT = setTimeout(poll, running ? 600 : 4000);
    }).catch(function () { pollT = setTimeout(poll, 2000); });
  }
  $('btnLog').addEventListener('click', function () { var o = $('dock').classList.toggle('open'); $('btnLog').textContent = o ? 'Nascondi' : 'Dettagli'; if (o) $('log').scrollTop = $('log').scrollHeight; });
  $('btnDockClose').addEventListener('click', function () { if (!running) $('dock').classList.remove('on', 'open'); $('btnLog').textContent = 'Dettagli'; });
  $('btnClassic').addEventListener('click', function () { run('/api/classic', {}); });

  /* ---------- scorciatoie da tastiera (come la versione classica) ---------- */
  var KEYS = { s: 'sys', i: 'inst', t: 'tw', a: 'appx', c: 'cfg', u: 'upd', p: 'prn', f: 'wifi', r: 'rep' };
  window.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      if ($('modal').classList.contains('on')) { $('mNo').click(); return; }
      if ($('qrModal').classList.contains('on')) { closeQr(); return; }
      if ($('updModal').classList.contains('on')) { $('updModal').classList.remove('on'); return; }
      if (document.activeElement === $('appSearch') && $('appSearch').value) { $('appSearch').value = ''; renderApps(); }
      return;
    }
    if (e.altKey && !e.ctrlKey && KEYS[(e.key || '').toLowerCase()]) { e.preventDefault(); show(KEYS[e.key.toLowerCase()]); return; }
    if (e.ctrlKey && !e.altKey && (e.key || '').toLowerCase() === 'f') { e.preventDefault(); show('inst'); $('appSearch').focus(); $('appSearch').select(); }
  });
})();
</script>
</body>
</html>

'@
# WinRUtil - variante con interfaccia HTML.
# Server locale (solo localhost, codice di accesso casuale a ogni avvio) che mostra web/index.html in una
# finestra Edge/Chrome in modalita' app e richiama le stesse funzioni della versione classica (WPF).
# Le funzioni della versione classica girano con $PARAM_NOUI = $true: niente chiamate alla finestra WPF.

$script:RWeb = [hashtable]::Synchronized(@{
        Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Label = ''; Percent = 0; Title = ''; Kind = ''
        # Esito di ogni applicazione nell'aggiornamento delle applicazioni scelte, letto dalla pagina
        Results = [hashtable]::Synchronized(@{})
    })
$script:RWebState = @{
    Phase = 'idle'; PS = $null; RS = $null; Handle = $null; Started = $null; Read = @{ I = 0; W = 0; E = 0 }
    Queries = @{}; LastActivity = (Get-Date).AddSeconds(40); Quit = $false; Browser = $null; BrowserProc = $null; ProfileDir = ''
    Token = ''; Port = 0; Iss = $null; Catalog = $null; Error = ''; ClassicFile = ''
}

# Icone delle applicazioni: le stesse della versione classica (servizio delle icone dei siti di Google)
$script:RWebIconSources = 'https://www.google.com https://*.gstatic.com'

function Add-RWebLog {
    param([string]$Text, [string]$Level = 'info')
    if ($null -eq $Text) { return }
    foreach ($l in ($Text -split "`r?`n")) {
        $t = $l.TrimEnd()
        if (-not $t -or $t -match '^[\s\-\\|/=]+$') { continue }
        [void]$script:RWeb.Log.Add(@{ t = (Get-Date).ToString('HH:mm:ss'); m = $t; c = $Level })
    }
}

function Show-WinRUtilWebFileDialog {
    # Finestra Apri/Salva di Windows sopra la finestra di WinRUtil (gira nel runspace STA dell'operazione)
    param([ValidateSet('Open', 'Save')][string]$Mode, [string]$Title, [string]$Filter, [string]$FileName = '', [switch]$Multi)
    Add-Type -AssemblyName System.Windows.Forms
    if ($Mode -eq 'Save') { $dlg = New-Object System.Windows.Forms.SaveFileDialog } else { $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Multiselect = [bool]$Multi }
    $dlg.Title = $Title; $dlg.Filter = $Filter; $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($FileName) { $dlg.FileName = $FileName }
    $owner = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.FormBorderStyle = 'None'; $owner.Opacity = 0
    $owner.StartPosition = 'CenterScreen'; $owner.Size = New-Object System.Drawing.Size(1, 1)
    try {
        $owner.Show(); $owner.Activate()
        if ($dlg.ShowDialog($owner) -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
        if ($Mode -eq 'Open' -and $Multi) { return @($dlg.FileNames) }
        return @($dlg.FileName)
    } finally { $owner.Close(); $owner.Dispose(); $dlg.Dispose() }
}

function New-RWebSessionState {
    # Stesse funzioni e variabili della versione classica, con la barra di avanzamento collegata alla pagina
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($v in @(@('sync', $sync), @('PARAM_NOUI', $true), @('PARAM_OFFLINE', $false), @('winutildir', $winutildir), @('RWeb', $script:RWeb), @('DebugPreference', 'SilentlyContinue'))) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList $v[0], $v[1], $null))
    }
    foreach ($f in @(Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|winrutil|WPF' -and $_.Name -ne 'Set-WinUtilProgressbar' })) {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $f.Name, $f.Definition))
    }
    $progress = 'param([string]$Label, [int]$Percent) $RWeb.Label = $Label; $RWeb.Percent = [math]::Max(0, [math]::Min(100, $Percent))'
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList 'Set-WinUtilProgressbar', $progress))
    return $iss
}

function Get-RWebCatalog {
    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.applications.PSObject.Properties) {
        $a = $p.Value
        $apps.Add(@{ id = $p.Name; name = [string]$a.content; desc = [string]$a.description; cat = [string]$a.category; foss = [bool]$a.foss; link = [string]$a.link; winget = [string]$a.winget; choco = [string]$a.choco })
    }
    $tweaks = New-Object System.Collections.Generic.List[object]
    $combos = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        $t = $p.Value
        $type = [string]$t.Type
        if ($type -eq 'Combobox') {
            # Il DNS ha il suo menu; gli altri menu scrivono valori del registro (es. Multiplane Overlay)
            if ($t.registry) {
                $descs = @{}
                if ($t.ComboDescriptions) { foreach ($d in $t.ComboDescriptions.PSObject.Properties) { $descs[$d.Name] = [string]$d.Value } }
                $combos.Add(@{ id = $p.Name; name = [string]$t.Content; desc = [string]$t.Description; items = @(([string]$t.ComboItems) -split '\|' | Where-Object { $_ }); descs = $descs })
            }
            continue
        }
        $tweaks.Add(@{ id = $p.Name; name = [string]$t.Content; desc = [string]$t.Description; cat = ([string]$t.category -replace '^z__', ''); advanced = ([string]$t.category -like 'z__*'); type = $type })
    }
    $features = New-Object System.Collections.Generic.List[object]
    foreach ($p in $sync.configs.feature.PSObject.Properties) {
        $f = $p.Value
        if ($p.Name -eq 'WPFFeatureInstall') { continue }
        $features.Add(@{ id = $p.Name; name = [string]$f.Content; desc = [string]$f.Description; cat = ([string]$f.category -replace '^z__', ''); type = [string]$f.Type })
    }
    $appx = New-Object System.Collections.Generic.List[object]
    if ($sync.configs.appx) {
        foreach ($p in $sync.configs.appx.PSObject.Properties) {
            $x = $p.Value
            $appx.Add(@{ id = $p.Name; name = [string]$x.Content; desc = [string]$x.Description; cat = [string]$x.Category; pkg = [string]$x.PackageId })
        }
    }
    $presets = @{}
    foreach ($p in $sync.configs.preset.PSObject.Properties) { $presets[$p.Name] = @($p.Value) }
    # Stesse voci del menu DNS della versione classica (compreso "Fastest"), altrimenti quelle di dns.json
    $dns = @(([string]$sync.configs.tweaks.WPFchangedns.ComboItems) -split '\s+' | Where-Object { $_ })
    if ($dns.Count -eq 0) { $dns = @('Default', 'DHCP') + @($sync.configs.dns.PSObject.Properties.Name) }
    return @{ apps = $apps.ToArray(); tweaks = $tweaks.ToArray(); combos = $combos.ToArray(); features = $features.ToArray(); appx = $appx.ToArray(); presets = $presets; dns = $dns }
}

function Get-RWebButtonIds {
    $ids = @('WPFAddUltPerf', 'WPFRemoveUltPerf', 'WPFOOSUbutton', 'WPFUpdatesdefault', 'WPFUpdatessecurity', 'WPFUpdatesdisable', 'WPFInstallUpgrade')
    foreach ($p in $sync.configs.feature.PSObject.Properties) { if ($p.Value.Type -eq 'Button' -and $p.Name -ne 'WPFFeatureInstall') { $ids += $p.Name } }
    return $ids
}

$script:RWebTasks = @{
    apps = {
        param($Ids, $Manager, $Action)
        $pk = @($Ids | ForEach-Object { $sync.configs.applicationsHashtable[$_] } | Where-Object { $_ })
        if ($pk.Count -eq 0) { Write-Host 'Nessuna applicazione selezionata.'; return }
        $sorted = Get-WinUtilSelectedPackages -PackageList $pk -Preference $Manager
        $w = @($sorted[[PackageManagers]::Winget]); $c = @($sorted[[PackageManagers]::Choco])
        $failed = @()
        if ($w.Count -gt 0) { Install-WinUtilWinget; $failed += @(Install-WinUtilProgramWinget -Action $Action -Programs $w) }
        if ($c.Count -gt 0) { Install-WinUtilChoco; $failed += @(Install-WinUtilProgramChoco -Action $Action -Programs $c) }
        $failed = @($failed | Where-Object { $_ })
        if ($failed.Count -gt 0) { Write-Warning ("Non riuscite: " + ($failed -join ', ')) } else { Write-Host 'Operazione completata.' }
    }
    upgrade = {
        param($Manager)
        Set-WinUtilProgressbar -Label 'Aggiornamento di tutte le applicazioni' -Percent 10
        if ($Manager -eq 'Choco') { Install-WinUtilChoco; & choco upgrade all -y 2>&1 | ForEach-Object { Write-Host $_ } }
        else { Install-WinUtilWinget; & winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Host $_ } }
        Write-Host 'Aggiornamento completato.'
    }
    upgradesel = {
        param($Programs)
        $RWeb.Results.Clear()
        $list = @($Programs)
        foreach ($p in $list) { $RWeb.Results[[string]$p.Id] = @{ t = 'In attesa'; l = 'Muted'; ok = $false } }
        $updated = 0
        for ($i = 0; $i -lt $list.Count; $i++) {
            $p = $list[$i]
            Set-WinUtilProgressbar -Label ("Aggiornamento {0} di {1}: {2}" -f ($i + 1), $list.Count, $p.Name) -Percent (100 * $i / $list.Count)
            $RWeb.Results[[string]$p.Id] = @{ t = 'In corso...'; l = 'Running'; ok = $false }
            $r = Update-WinUtilProgram -Program $p
            if ($r.Success) { $updated++ }
            $RWeb.Results[[string]$p.Id] = @{ t = [string]$r.Text; l = [string]$r.Level; ok = [bool]$r.Success }
            Add-WinUtilSessionAction -Area 'Programmi' -Text ("Aggiornamento di {0} alla versione {1}" -f $p.Name, $p.Available) -Status $(if ($r.Success) { 'Success' } else { 'Error' })
        }
        if ($updated -lt $list.Count) { Write-Warning ("Applicazioni aggiornate: {0} su {1}. Quelle non riuscite restano selezionate, per riprovare." -f $updated, $list.Count) }
        else { Write-Host ("Applicazioni aggiornate: {0} su {1}." -f $updated, $list.Count) }
    }
    tweaks = {
        param($Ids, $Undo, $Dns)
        $ids = @($Ids)
        if (-not $Undo -and $ids -contains 'WPFTweaksRestorePoint') { $ids = @('WPFTweaksRestorePoint') + @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        if ($Undo) { $ids = @($ids | Where-Object { $_ -ne 'WPFTweaksRestorePoint' }) }
        $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $name = [string]$sync.configs.tweaks.($ids[$i]).Content
            if ($Undo) { Set-WinUtilProgressbar -Label "Annullo: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] -undo $true }
            else { Set-WinUtilProgressbar -Label "Applico: $name" -Percent (100 * $i / $n); Invoke-WinUtilTweaks $ids[$i] }
        }
        if ($Dns -and $Dns -ne 'Default') { Set-WinUtilProgressbar -Label "DNS: $Dns" -Percent 95; Set-WinUtilDNS -DNSProvider $Dns }
        Write-Host 'Ottimizzazioni completate.'
    }
    toggle = {
        param($Id, $On)
        if ($On) { Invoke-WinUtilTweaks $Id } else { Invoke-WinUtilTweaks $Id -undo $true }
        Write-Host 'Impostazione aggiornata.'
    }
    combo = {
        param($Id, $State)
        $cfg = $sync.configs.tweaks.$Id
        try {
            Set-WinUtilRegistryComboState -Registry $cfg.registry -State $State
            Write-Host "$($cfg.Content): $State"
            Add-WinUtilSessionAction -Area 'Ottimizzazione' -Text "$($cfg.Content): $State"
        } catch {
            Write-Error "$($cfg.Content): $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Ottimizzazione' -Text "$($cfg.Content): $State" -Status 'Error'
        }
    }
    features = {
        param($Ids)
        $ids = @($Ids); $n = [math]::Max(1, $ids.Count)
        for ($i = 0; $i -lt $ids.Count; $i++) {
            Set-WinUtilProgressbar -Label ([string]$sync.configs.feature.($ids[$i]).Content) -Percent (100 * $i / $n)
            Invoke-WinUtilFeatureInstall $ids[$i]
        }
        Write-Host 'Funzionalita'' installate. Riavviare il PC per completare.'
    }
    button = {
        param($Id)
        $cfg = $sync.configs.feature.$Id
        if ($cfg -and $cfg.function -and (Get-Command $cfg.function -ErrorAction SilentlyContinue)) { & $cfg.function; return }
        if ($cfg -and $cfg.InvokeScript) { foreach ($s in $cfg.InvokeScript) { if ($s) { Invoke-Expression $s } }; return }
        switch ($Id) {
            'WPFAddUltPerf' { Invoke-WPFUltimatePerformance -Do }
            'WPFRemoveUltPerf' { Invoke-WPFUltimatePerformance }
            'WPFOOSUbutton' { Invoke-WPFOOSU }
            'WPFUpdatesdefault' { Invoke-WPFUpdatesdefault }
            'WPFUpdatessecurity' { Invoke-WPFUpdatessecurity }
            'WPFUpdatesdisable' { Invoke-WPFUpdatesdisable -Confirmed }
        }
        Write-Host 'Fatto.'
    }
    appx = {
        param($Ids, $Action)
        $ids = @($Ids); $apps = $sync.configs.appxHashtable; $ok = 0
        $packages = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $key = $ids[$i]; $app = $apps[$key]
            if ($Action -eq 'Remove') {
                Set-WinUtilProgressbar -Label ("Rimozione {0} di {1}: {2}" -f ($i + 1), $ids.Count, $app.Content) -Percent (100 * $i / $ids.Count)
                if ($key -eq 'WPFAppxMicrosoft_XboxGamingOverlay') {
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0 -ErrorAction SilentlyContinue
                }
                if ($key -eq 'WPFAppxMicrosoft_WindowsNotepad') { Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue }
                $done = Remove-WinUtilAPPX -Name $app.PackageId
                $packages.Add($app.PackageId)
                if ($key -eq 'WPFAppxMSTeams') { Get-Package -Name 'Microsoft Teams*' -ErrorAction SilentlyContinue | Uninstall-Package -Force -ErrorAction SilentlyContinue | Out-Null }
                Add-WinUtilSessionAction -Area 'App di Windows' -Text ("Rimozione di {0}" -f $app.Content) -Status $(if ($done) { 'Success' } else { 'Error' })
            } else {
                Set-WinUtilProgressbar -Label ("Installazione {0} di {1}: {2}" -f ($i + 1), $ids.Count, $app.Content) -Percent (100 * $i / $ids.Count)
                $done = Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId
                Add-WinUtilSessionAction -Area 'App di Windows' -Text ("Installazione di {0}" -f $app.Content) -Status $(if ($done) { 'Success' } else { 'Error' })
            }
            if ($done) { $ok++ }
        }
        if ($Action -eq 'Remove' -and $packages.Count -gt 0) {
            Set-WinUtilProgressbar -Label 'Rimozione delle app per i nuovi profili utente' -Percent 95
            try { Remove-WinUtilProvisionedAPPX -PackageList $packages.ToArray() } catch { Write-Warning "Alcune app potrebbero comparire di nuovo nei profili utente creati in seguito. $($_.Exception.Message)" }
        }
        $verb = 'Installate'; if ($Action -eq 'Remove') { $verb = 'Rimosse' }
        if ($ok -lt $ids.Count) { Write-Warning ("{0} {1} app su {2}." -f $verb, $ok, $ids.Count) } else { Write-Host ("{0} {1} app su {2}." -f $verb, $ok, $ids.Count) }
    }
    printer = {
        param($Action, $Driver)
        switch ($Action) {
            'driver' {
                $f = @(Show-WinRUtilWebFileDialog -Mode Open -Title 'Seleziona il file del driver (.inf)' -Filter 'File driver (*.inf)|*.inf|Tutti i file (*.*)|*.*')
                if ($f.Count -eq 0) { Write-Warning 'Installazione del driver annullata.'; return }
                $text = "Installazione del driver di stampa {0}" -f [IO.Path]::GetFileName($f[0])
                Write-Host "Installazione del driver da: $($f[0])"
                $out = & pnputil.exe /add-driver "$($f[0])" /install 2>&1
                $out | ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -eq 0) { Write-Host 'Driver installato.'; Add-WinUtilSessionAction -Area 'Stampanti' -Text $text }
                else { Write-Warning "pnputil ha restituito il codice $LASTEXITCODE."; Add-WinUtilSessionAction -Area 'Stampanti' -Text $text -Status 'Error' }
            }
            'remove' {
                try {
                    Remove-PrinterDriver -Name $Driver -ErrorAction Stop
                    Write-Host "Driver '$Driver' rimosso."
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text "Rimozione del driver di stampa $Driver"
                } catch {
                    Write-Error "Driver non rimosso (forse e' ancora usato da una stampante): $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text "Rimozione del driver di stampa $Driver" -Status 'Error'
                }
            }
            'restart' {
                try {
                    Restart-Service -Name Spooler -Force -ErrorAction Stop
                    Write-Host 'Spooler di stampa riavviato.'
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Riavvio dello spooler di stampa'
                } catch {
                    Write-Error "Riavvio dello spooler non riuscito: $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Riavvio dello spooler di stampa' -Status 'Error'
                }
            }
            'clear' {
                $spool = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
                try {
                    Stop-Service -Name Spooler -Force -ErrorAction Stop
                    if (Test-Path $spool) { Get-ChildItem -Path $spool -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
                    Start-Service -Name Spooler -ErrorAction Stop
                    Write-Host 'Coda di stampa svuotata e spooler riavviato.'
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Svuotamento della coda di stampa'
                } catch {
                    Write-Error "Svuotamento della coda non riuscito: $($_.Exception.Message)"
                    Add-WinUtilSessionAction -Area 'Stampanti' -Text 'Svuotamento della coda di stampa' -Status 'Error'
                    try { Start-Service -Name Spooler -ErrorAction SilentlyContinue } catch { }
                }
            }
        }
    }
    wifiexport = {
        if (-not (Test-WinUtilWlanService)) { return }
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Esporta i profili Wi-Fi' -Filter 'Archivio ZIP (*.zip)|*.zip' -FileName ("WinRUtil-WiFi_{0}_{1}.zip" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')))
        if ($f.Count -eq 0) { Write-Warning 'Esportazione annullata.'; return }
        try {
            $n = Export-WinUtilWifiProfiles -Path $f[0]
            if (-not $n) { Write-Warning 'Nessun profilo Wi-Fi da esportare.'; return }
            Write-Host ("Esportati {0} profili in {1}" -f $n, $f[0])
            Write-Warning 'Il file contiene le password in chiaro: conservalo in un luogo sicuro.'
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Backup di {0} {1}" -f $n, $(if ($n -eq 1) { 'profilo Wi-Fi' } else { 'profili Wi-Fi' }))
        } catch {
            Write-Error "Esportazione non riuscita: $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text 'Backup dei profili Wi-Fi' -Status 'Error'
        }
    }
    wifiimport = {
        if (-not (Test-WinUtilWlanService)) { return }
        $f = @(Show-WinRUtilWebFileDialog -Mode Open -Multi -Title 'Importa profili Wi-Fi' -Filter 'Profili Wi-Fi (*.zip;*.xml)|*.zip;*.xml')
        if ($f.Count -eq 0) { Write-Warning 'Importazione annullata.'; return }
        try {
            $res = @(Import-WinUtilWifiProfiles -Path $f)
            foreach ($r in $res) { if ($r.Success) { Write-Host "Importata: $($r.Name)" } else { Write-Warning "Non importata: $($r.Name) - $($r.Message)" } }
            $okNames = @($res | Where-Object { $_.Success } | ForEach-Object { $_.Name })
            $koNames = @($res | Where-Object { -not $_.Success } | ForEach-Object { $_.Name })
            if ($res.Count -eq 0) { Write-Warning 'Nessun profilo Wi-Fi trovato nei file scelti.' }
            elseif ($koNames.Count -eq 0) { Write-Host ("Importate {0} reti." -f $okNames.Count) }
            else { Write-Warning ("Importate {0} reti su {1}." -f $okNames.Count, $res.Count) }
            if ($okNames.Count) { Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Configurazione {0}: {1}" -f $(if ($okNames.Count -eq 1) { 'della rete Wi-Fi' } else { 'delle reti Wi-Fi' }), ($okNames -join ', ')) }
            if ($koNames.Count) { Add-WinUtilSessionAction -Area 'Wi-Fi' -Text ("Configurazione {0}: {1}" -f $(if ($koNames.Count -eq 1) { 'della rete Wi-Fi' } else { 'delle reti Wi-Fi' }), ($koNames -join ', ')) -Status 'Error' }
        } catch {
            Write-Error "Importazione non riuscita: $($_.Exception.Message)"
            Add-WinUtilSessionAction -Area 'Wi-Fi' -Text 'Importazione dei profili Wi-Fi' -Status 'Error'
        }
    }
    wifiqrsave = {
        param($Ssid)
        $net = @(Get-WinRUtilWifiProfiles | Where-Object { $_.Ssid -eq $Ssid })
        if ($net.Count -eq 0 -or -not $net[0].CanShare) { Write-Error "Rete $Ssid non disponibile."; return }
        $net = $net[0]
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Salva il QR code della rete Wi-Fi' -Filter 'Immagine PNG (*.png)|*.png' -FileName ("WiFi-{0}.png" -f ($net.Ssid -replace '[\\/:*?"<>|]', '_')))
        if ($f.Count -eq 0) { Write-Warning 'Salvataggio annullato.'; return }
        Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase
        $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $net)
        $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create((ConvertTo-WinUtilWifiQRCard -QRCode $qr -Network $net)))
        $stream = [System.IO.File]::Create($f[0])
        try { $enc.Save($stream) } finally { $stream.Dispose() }
        Write-Host "QR code salvato: $($f[0])"
        if ($net.Password) { Write-Warning 'L''immagine contiene la password della rete: condividila solo con chi deve collegarsi.' }
    }
    report = {
        param($Details)
        Save-WinUtilReportSettings -Technician $Details.Technician -Header $Details.Header
        $name = $Details.Customer; if (-not $name) { $name = $env:COMPUTERNAME }
        $date = Get-Date
        $fileName = "Rapporto_{0}_{1}" -f (($name -replace '[\\/:*?"<>|]', '' -replace '\s+', '-').Trim('-.')), $date.ToString('yyyyMMdd-HHmm')
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Salva il rapporto di intervento' -Filter 'Pagina HTML (*.html)|*.html' -FileName $fileName)
        if ($f.Count -eq 0) { Write-Warning 'Creazione del rapporto annullata.'; return }
        Set-WinUtilProgressbar -Label 'Lettura dei dati del computer' -Percent 30
        $d = @{
            Customer = $Details.Customer; Technician = $Details.Technician; Reference = $Details.Reference; Header = $Details.Header; Notes = $Details.Notes
            Actions = @(if ($sync.SessionActions) { $sync.SessionActions.ToArray() }); Date = $date
        }
        $html = ConvertTo-WinUtilInterventionReportHtml -Details $d -Report (Get-WinUtilSystemReport)
        [System.IO.File]::WriteAllText($f[0], $html, [System.Text.UTF8Encoding]::new($true))
        Write-Host "Rapporto salvato: $($f[0])"
        Start-Process -FilePath $f[0]
    }
    sysexport = {
        $f = @(Show-WinRUtilWebFileDialog -Mode Save -Title 'Esporta il report di sistema' -Filter 'Report HTML (*.html)|*.html|Testo semplice (*.txt)|*.txt' -FileName ("WinRUtil-Sistema_{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')))
        if ($f.Count -eq 0) { Write-Warning 'Esportazione annullata.'; return }
        Set-WinUtilProgressbar -Label 'Lettura dei dati del computer' -Percent 30
        $r = Get-WinUtilSystemReport
        $isText = [IO.Path]::GetExtension($f[0]) -ieq '.txt'
        if ($isText) { $content = ConvertTo-WinUtilSystemReportText -Report $r } else { $content = ConvertTo-WinUtilSystemReportHtml -Report $r }
        [System.IO.File]::WriteAllText($f[0], $content, [System.Text.UTF8Encoding]::new($true))
        Write-Host "Report salvato: $($f[0])"
        if (-not $isText) { Start-Process -FilePath $f[0] }
    }
    classic = {
        # Niente download ed esecuzione sulla riga di comando di un nuovo PowerShell: gli antivirus lo bloccano.
        # Il file della versione classica si scarica qui e si avvia come file.
        param($LocalFile)
        $file = $LocalFile
        if (-not $file -or -not (Test-Path -LiteralPath $file)) {
            $file = Join-Path $winutildir 'winrutil.ps1'
            Set-WinUtilProgressbar -Label 'Download della versione classica' -Percent 30
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $tmp = "$file.download"
                Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1' -OutFile $tmp -UseBasicParsing -ErrorAction Stop
                Move-Item -LiteralPath $tmp -Destination $file -Force
            } catch {
                if (-not (Test-Path -LiteralPath $file)) { throw "Download della versione classica non riuscito: $($_.Exception.Message)" }
                Write-Warning 'Download non riuscito: avvio la copia scaricata in precedenza.'
            }
        }
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`"")
        Write-Host 'Versione classica avviata in una nuova finestra.'
    }
}

$script:RWebStrictKinds = @('printer', 'combo', 'wifiexport', 'wifiimport', 'wifiqrsave', 'report', 'sysexport', 'classic')

$script:RWebQueries = @{
    system   = '$r = Get-WinUtilSystemReport; $r.Disks = @($r.Disks | ForEach-Object { [pscustomobject]$_ }); [pscustomobject]$r'
    live     = '$l = [math]::Round([double](Get-CimInstance -ClassName Win32_Processor -Property LoadPercentage | Measure-Object -Property LoadPercentage -Average).Average); $o = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory,LastBootUpTime; $cs = Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory; $r = @{ CpuLoadPct = $l; CpuLoad = "$l%"; Uptime = (Format-WinUtilUptime $o.LastBootUpTime) }; Set-WinUtilSystemMemory -Report $r -TotalGB ([math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)) -FreeGB (([double]$o.FreePhysicalMemory * 1KB) / 1GB); [pscustomobject]$r'
    wifi     = '@(Get-WinRUtilWifiProfiles)'
    appx     = '@(Get-WinUtilInstalledAPPX)'
    printers = '@(Get-Printer -ErrorAction Stop | ForEach-Object { $j = 0; try { $j = @(Get-PrintJob -PrinterName $_.Name -ErrorAction Stop).Count } catch { }; [pscustomobject]@{ name = [string]$_.Name; driver = [string]$_.DriverName; port = [string]$_.PortName; status = [string]$_.PrinterStatus; jobs = $j } })'
    updWinget = 'if ((Test-WinUtilPackageManager -winget) -ne ''installed'') { Install-WinUtilWinget }; @(Get-WinUtilProgramUpdates -Manager Winget)'
    updChoco = 'if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw ''Chocolatey non e'''' installato: nessuna applicazione da aggiornare con Chocolatey.'' }; @(Get-WinUtilProgramUpdates -Manager Choco)'
    instWinget = '@(Invoke-WinUtilCurrentSystem -CheckBox winget)'
    instChoco = '@(Invoke-WinUtilCurrentSystem -CheckBox choco)'
    applied  = '@(Invoke-WinUtilCurrentSystem -CheckBox tweaks)'
}

function Start-RWebTask {
    param([string]$Kind, [string]$Title, [hashtable]$Params)
    $st = $script:RWebState
    if ($st.Phase -eq 'running') { return $false }
    Stop-RWebTask
    if (-not $st.Iss) { $st.Iss = New-RWebSessionState }
    $script:RWeb.Label = $Title; $script:RWeb.Percent = 0; $script:RWeb.Title = $Title; $script:RWeb.Kind = $Kind
    Add-RWebLog "== $Title" 'head'
    $rs = [runspacefactory]::CreateRunspace($Host, $st.Iss)
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript($script:RWebTasks[$Kind].ToString())
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    $st.PS = $ps; $st.RS = $rs; $st.Read = @{ I = 0; W = 0; E = 0 }; $st.Error = ''
    $st.Handle = $ps.BeginInvoke(); $st.Started = Get-Date; $st.Phase = 'running'
    return $true
}

function Read-RWebStreams {
    $st = $script:RWebState
    if (-not $st.PS) { return }
    $s = $st.PS.Streams
    while ($st.Read.I -lt $s.Information.Count) { Add-RWebLog ([string]$s.Information[$st.Read.I].MessageData) 'info'; $st.Read.I++ }
    while ($st.Read.W -lt $s.Warning.Count) { Add-RWebLog ([string]$s.Warning[$st.Read.W].Message) 'warn'; $st.Read.W++ }
    while ($st.Read.E -lt $s.Error.Count) { Add-RWebLog ([string]$s.Error[$st.Read.E].Exception.Message) 'error'; $st.Read.E++ }
}

function Update-RWebPhase {
    $st = $script:RWebState
    if ($st.Phase -ne 'running') { return }
    Read-RWebStreams
    if ($st.Handle -and $st.Handle.IsCompleted) {
        try { [void]$st.PS.EndInvoke($st.Handle) } catch { $st.Error = $_.Exception.Message; Add-RWebLog $st.Error 'error' }
        Read-RWebStreams
        # Per le operazioni di questa variante un errore scritto vale come operazione non riuscita;
        # le funzioni della versione classica possono scrivere errori secondari senza fallire
        if (-not $st.Error -and $script:RWeb.Kind -in $script:RWebStrictKinds -and $st.PS.Streams.Error.Count -gt 0) { $st.Error = [string]$st.PS.Streams.Error[0].Exception.Message }
        $script:RWeb.Percent = 100
        $st.Phase = 'done'
        Add-RWebLog 'Terminato.' 'ok'
    }
}

function Stop-RWebTask {
    $st = $script:RWebState
    if ($st.PS) {
        try { if (-not $st.Handle.IsCompleted) { $st.PS.Stop() } } catch { }
        try { $st.PS.Dispose() } catch { }
        try { $st.RS.Close(); $st.RS.Dispose() } catch { }
    }
    $st.PS = $null; $st.RS = $null; $st.Handle = $null
}

function Get-RWebQueryEntry {
    # Letture lente (sistema, Wi-Fi, stampanti...) in un runspace separato: la pagina resta reattiva
    param([string]$Name, [switch]$Refresh)
    $q = $script:RWebState.Queries
    if ($Refresh -and $q.ContainsKey($Name) -and $q[$Name].Done) { [void]$q.Remove($Name) }
    if (-not $q.ContainsKey($Name)) {
        if (-not $script:RWebState.Iss) { $script:RWebState.Iss = New-RWebSessionState }
        $rs = [runspacefactory]::CreateRunspace($script:RWebState.Iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($script:RWebQueries[$Name])
        $q[$Name] = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); Done = $false; Data = $null; Error = '' }
    }
    $e = $q[$Name]
    if (-not $e.Done -and $e.Handle.IsCompleted) {
        try { $e.Data = @($e.PS.EndInvoke($e.Handle)) } catch { $e.Data = @(); $e.Error = [string]$_.Exception.InnerException.Message; if (-not $e.Error) { $e.Error = [string]$_.Exception.Message } }
        try { $e.PS.Dispose(); $e.RS.Close(); $e.RS.Dispose() } catch { }
        $e.Done = $true
    }
    return $e
}

function Get-RWebQuery {
    param([string]$Name, [switch]$Refresh)
    $e = Get-RWebQueryEntry $Name -Refresh:$Refresh
    if (-not $e.Done) { return @{ loading = $true } }
    $data = @($e.Data)
    switch -Regex ($Name) {
        '^(system|live)$' { $out = $null; if ($data.Count) { $out = $data[$data.Count - 1] } }
        '^wifi$' { $out = @($data | ForEach-Object { @{ ssid = [string]$_.Ssid; password = [string]$_.Password; security = [string]$_.Security; auto = [string]$_.AutoConnect; hidden = [bool]$_.Hidden; canShare = [bool]$_.CanShare } }) }
        '^appx$' {
            $names = @($data | ForEach-Object { [string]$_ })
            $out = @($script:RWebState.Catalog.appx | Where-Object { $names -contains $_.pkg } | ForEach-Object { $_.id })
        }
        '^upd' { $out = @($data | ForEach-Object { @{ id = [string]$_.Id; name = [string]$_.Name; version = [string]$_.Version; available = [string]$_.Available; source = [string]$_.Source; manager = [string]$_.Manager; selected = [bool]$_.Selected } }) }
        '^(inst|applied)' { $out = @($data | ForEach-Object { [string]$_ } | Select-Object -Unique) }
        default { $out = $data }
    }
    return @{ loading = $false; data = $out; error = [string]$e.Error }
}

function Get-RWebToggles {
    $o = @{}
    foreach ($p in $sync.configs.tweaks.PSObject.Properties) {
        if ($p.Value.Type -ne 'Toggle') { continue }
        try { $o[$p.Name] = [bool](Get-WinUtilToggleStatus $p.Name) } catch { $o[$p.Name] = $false }
    }
    return $o
}

function Get-RWebCombos {
    $o = @{}
    foreach ($c in @($script:RWebState.Catalog.combos)) {
        try { $o[$c.id] = [string](Get-WinUtilRegistryComboState -Registry $sync.configs.tweaks.($c.id).registry) } catch { $o[$c.id] = '' }
    }
    return $o
}

function Get-RWebReport {
    $src = @(); if ($sync.SessionActions) { $src = $sync.SessionActions.ToArray() }
    $actions = @($src | ForEach-Object { @{ time = [string]$_.Time; area = [string]$_.Area; text = [string]$_.Text; status = [string]$_.Status; result = [string]$_.Result } })
    $s = Get-WinUtilReportSettings
    return @{ actions = $actions; technician = [string]$s.Technician; header = [string]$s.Header }
}

function Get-RWebWifiNetwork {
    # Rete dell'ultimo elenco letto (lo stesso mostrato nella pagina)
    param([string]$Ssid)
    $e = $script:RWebState.Queries['wifi']
    if (-not $e -or -not $e.Done) { return $null }
    return @($e.Data | Where-Object { $_.Ssid -eq $Ssid })[0]
}

function ConvertTo-RWebQRModules {
    param($QR)
    $sb = New-Object System.Text.StringBuilder ($QR.Size * $QR.Size)
    foreach ($m in $QR.Modules) { if ($m) { [void]$sb.Append('1') } else { [void]$sb.Append('0') } }
    return $sb.ToString()
}

function Test-RWebTokenEqual {
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $d = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $d = $d -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($d -eq 0)
}

function Send-RWebBytes {
    param($Ctx, [byte[]]$Bytes, [string]$Type, [int]$Code = 200, [hashtable]$Extra = @{})
    $res = $Ctx.Response
    $res.StatusCode = $Code; $res.ContentType = $Type
    $res.Headers['Cache-Control'] = 'no-store'; $res.Headers['X-Content-Type-Options'] = 'nosniff'
    $res.Headers['Referrer-Policy'] = 'no-referrer'; $res.Headers['X-Frame-Options'] = 'DENY'
    foreach ($k in $Extra.Keys) { $res.Headers[$k] = $Extra[$k] }
    $res.ContentLength64 = $Bytes.Length
    $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    $res.OutputStream.Close()
}

function Send-RWebJson {
    param($Ctx, $Obj, [int]$Code = 200)
    $json = ConvertTo-Json -InputObject $Obj -Depth 6 -Compress
    Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $Code
}

function Read-RWebBody {
    param($Req)
    if (-not $Req.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Req.InputStream, [Text.Encoding]::UTF8)
    try { $t = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ($t.Length -gt 50000) { return $null }
    try { return ($t | ConvertFrom-Json) } catch { return $null }
}

function Select-RWebIds {
    # Accetta solo identificativi presenti nella configurazione
    param($Ids, $Valid)
    return @(@($Ids) | ForEach-Object { [string]$_ } | Where-Object { $Valid -contains $_ } | Select-Object -Unique)
}

function Get-RWebText {
    param($Value, [int]$Max = 2000)
    $t = ([string]$Value).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Get-RWebStatus {
    param([int]$Since)
    Update-RWebPhase
    $log = $script:RWeb.Log
    $count = $log.Count
    if ($Since -lt 0 -or $Since -gt $count) { $Since = 0 }
    $items = New-Object System.Collections.Generic.List[object]
    for ($i = $Since; $i -lt $count; $i++) { $items.Add($log[$i]) }
    $st = $script:RWebState
    $el = 0; if ($st.Started) { $el = [int]((Get-Date) - $st.Started).TotalSeconds }
    $results = @{}; foreach ($k in @($script:RWeb.Results.Keys)) { $results[$k] = $script:RWeb.Results[$k] }
    return @{ phase = $st.Phase; kind = [string]$script:RWeb.Kind; title = [string]$script:RWeb.Title; label = [string]$script:RWeb.Label; percent = [int]$script:RWeb.Percent; logIndex = $count; log = $items.ToArray(); elapsed = $el; error = [string]$st.Error; results = $results }
}

function Invoke-RWebRequest {
    param($Ctx, [string]$Html)
    $st = $script:RWebState
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    if ($req.Headers['Host'] -ne "localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'host' } 403; return }
    if ($path -eq '/' -or $path -eq '/index.html') {
        $nb = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($nb); $rng.Dispose()
        $nonce = [Convert]::ToBase64String($nb)
        $csp = "default-src 'none'; script-src 'nonce-$nonce'; style-src 'unsafe-inline'; img-src data: $script:RWebIconSources; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        Send-RWebBytes $Ctx ([Text.Encoding]::UTF8.GetBytes($Html.Replace('__NONCE__', $nonce))) 'text/html; charset=utf-8' 200 @{ 'Content-Security-Policy' = $csp }
        return
    }
    if (-not $path.StartsWith('/api/')) { Send-RWebJson $Ctx @{ error = 'not found' } 404; return }
    if (-not (Test-RWebTokenEqual $req.Headers['X-Token']$st.Token)) { Send-RWebJson $Ctx @{ error = 'token' } 403; return }
    $o = $req.Headers['Origin']
    if ($req.HttpMethod -eq 'POST' -and $o -and $o -ne "http://localhost:$($st.Port)") { Send-RWebJson $Ctx @{ error = 'origin' } 403; return }
    $st.LastActivity = Get-Date
    $b = $null
    if ($req.HttpMethod -eq 'POST') { $b = Read-RWebBody $req }
    $cat = $st.Catalog
    $busy = @{ error = 'Un''altra operazione e'' in corso.' }
    $refresh = [string]$req.QueryString['refresh'] -eq '1'
    $mgrQ = 'Winget'; if ([string]$req.QueryString['manager'] -eq 'Choco') { $mgrQ = 'Choco' }
    $start = {
        param($Kind, $Title, $Params)
        if (Start-RWebTask $Kind $Title $Params) { Send-RWebJson $Ctx @{ ok = $true } } else { Send-RWebJson $Ctx $busy 409 }
    }
    switch ("$($req.HttpMethod) $path") {
        'GET /api/ping' { Send-RWebJson $Ctx @{ ok = $true } }
        'GET /api/info' {
            $pm = [string]$sync.preferences.packagemanager; if (-not $pm) { $pm = 'Winget' }
            Send-RWebJson $Ctx @{ app = 'WinRUtil'; version = [string]$sync.version; pc = [Environment]::MachineName; isAdmin = $true; manager = $pm }
        }
        'GET /api/catalog' { Send-RWebJson $Ctx $cat }
        'GET /api/toggles' { Send-RWebJson $Ctx (Get-RWebToggles) }
        'GET /api/combos' { Send-RWebJson $Ctx (Get-RWebCombos) }
        'GET /api/system' { Send-RWebJson $Ctx (Get-RWebQuery 'system' -Refresh:$refresh) }
        'GET /api/live' { Send-RWebJson $Ctx (Get-RWebQuery 'live' -Refresh:$refresh) }
        'GET /api/wifi' { Send-RWebJson $Ctx (Get-RWebQuery 'wifi' -Refresh:$refresh) }
        'GET /api/appx' { Send-RWebJson $Ctx (Get-RWebQuery 'appx' -Refresh:$refresh) }
        'GET /api/printers' { Send-RWebJson $Ctx (Get-RWebQuery 'printers' -Refresh:$refresh) }
        'GET /api/updates' { Send-RWebJson $Ctx (Get-RWebQuery "upd$mgrQ" -Refresh:$refresh) }
        'GET /api/installed' { Send-RWebJson $Ctx (Get-RWebQuery "inst$mgrQ" -Refresh:$refresh) }
        'GET /api/applied' { Send-RWebJson $Ctx (Get-RWebQuery 'applied' -Refresh:$refresh) }
        'GET /api/report' { Send-RWebJson $Ctx (Get-RWebReport) }
        'GET /api/status' {
            $since = 0; [void][int]::TryParse([string]$req.QueryString['since'], [ref]$since)
            Send-RWebJson $Ctx (Get-RWebStatus $since)
        }
        'POST /api/apps' {
            $ids = Select-RWebIds $b.ids @($cat.apps | ForEach-Object { $_.id })
            $act = 'Install'; if ([string]$b.action -eq 'Uninstall') { $act = 'Uninstall' }
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''applicazione.' } 400; return }
            $t = "Installazione di $($ids.Count) applicazioni"; if ($act -eq 'Uninstall') { $t = "Disinstallazione di $($ids.Count) applicazioni" }
            & $start 'apps' $t @{ Ids = $ids; Manager = $mgr; Action = $act }
        }
        'POST /api/upgrade' {
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            & $start 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = $mgr }
        }
        'POST /api/updates' {
            # Solo applicazioni dell'ultimo elenco degli aggiornamenti trovati
            $mgr = 'Winget'; if ([string]$b.manager -eq 'Choco') { $mgr = 'Choco' }
            $e = $st.Queries["upd$mgr"]
            if (-not $e -or -not $e.Done) { Send-RWebJson $Ctx @{ error = 'Cerca prima gli aggiornamenti.' } 400; return }
            $ids = @(@($b.ids) | ForEach-Object { [string]$_ })
            $programs = @($e.Data | Where-Object { $ids -contains [string]$_.Id })
            if ($programs.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''applicazione da aggiornare.' } 400; return }
            & $start 'upgradesel' "Aggiornamento di $($programs.Count) applicazioni" @{ Programs = $programs }
        }
        'POST /api/tweaks' {
            $ids = Select-RWebIds $b.ids @($cat.tweaks | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            $dns = [string]$b.dns; if ($cat.dns -notcontains $dns) { $dns = 'Default' }
            $undo = [bool]$b.undo
            if ($ids.Count -eq 0 -and $dns -eq 'Default') { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''ottimizzazione.' } 400; return }
            $t = "Applicazione di $($ids.Count) ottimizzazioni"; if ($undo) { $t = "Annullamento di $($ids.Count) ottimizzazioni" }
            & $start 'tweaks' $t @{ Ids = $ids; Undo = $undo; Dns = $dns }
        }
        'POST /api/toggle' {
            $id = [string]$b.id
            $t = @($cat.tweaks | Where-Object { $_.id -eq $id -and $_.type -eq 'Toggle' })
            if ($t.Count -ne 1) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            $lbl = "$($t[0].name): disattivato"; if ([bool]$b.on) { $lbl = "$($t[0].name): attivato" }
            & $start 'toggle' $lbl @{ Id = $id; On = [bool]$b.on }
        }
        'POST /api/combo' {
            $id = [string]$b.id; $state = [string]$b.state
            $c = @($cat.combos | Where-Object { $_.id -eq $id })
            if ($c.Count -ne 1 -or $c[0].items -notcontains $state) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            & $start 'combo' "$($c[0].name): $state" @{ Id = $id; State = $state }
        }
        'POST /api/features' {
            $ids = Select-RWebIds $b.ids @($cat.features | Where-Object { -not $_.type } | ForEach-Object { $_.id })
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno una funzionalita''.' } 400; return }
            & $start 'features' "Installazione di $($ids.Count) funzionalita'" @{ Ids = $ids }
        }
        'POST /api/button' {
            $id = [string]$b.id
            if ((Get-RWebButtonIds) -notcontains $id) { Send-RWebJson $Ctx @{ error = 'id' } 400; return }
            if ($id -eq 'WPFInstallUpgrade') { & $start 'upgrade' 'Aggiornamento di tutte le applicazioni' @{ Manager = 'Winget' }; return }
            $name = Get-RWebText $b.label 120; if (-not $name) { $name = $id }
            & $start 'button' $name @{ Id = $id }
        }
        'POST /api/appx' {
            $ids = Select-RWebIds $b.ids @($cat.appx | ForEach-Object { $_.id })
            if ($ids.Count -eq 0) { Send-RWebJson $Ctx @{ error = 'Seleziona almeno un''app di Windows.' } 400; return }
            if ([string]$b.action -eq 'Remove') { & $start 'appx' "Rimozione di $($ids.Count) app di Windows" @{ Ids = $ids; Action = 'Remove' } }
            else { & $start 'appx' "Installazione di $($ids.Count) app di Windows" @{ Ids = $ids; Action = 'Install' } }
        }
        'POST /api/printer' {
            $act = [string]$b.action
            $titles = @{ driver = 'Installazione di un driver di stampa'; remove = 'Rimozione del driver di stampa'; restart = 'Riavvio dello spooler di stampa'; clear = 'Svuotamento della coda di stampa' }
            if (-not $titles.ContainsKey($act)) { Send-RWebJson $Ctx @{ error = 'azione' } 400; return }
            $drv = ''
            if ($act -eq 'remove') {
                # Solo driver di una stampante dell'elenco mostrato
                $e = $st.Queries['printers']
                $drv = [string]$b.driver
                if (-not $e -or -not $e.Done -or -not @($e.Data | Where-Object { $_.driver -eq $drv }).Count) { Send-RWebJson $Ctx @{ error = 'Seleziona una stampante dell''elenco.' } 400; return }
            }
            & $start 'printer' $titles[$act] @{ Action = $act; Driver = $drv }
        }
        'POST /api/wifiqr' {
            $n = Get-RWebWifiNetwork ([string]$b.ssid)
            if (-not $n) { Send-RWebJson $Ctx @{ error = 'Rete non trovata: aggiorna l''elenco.' } 400; return }
            if (-not $n.CanShare) {
                $msg = 'QR code non disponibile: la password non risulta salvata su questo PC.'
                if ($n.Security -match 'Enterprise') { $msg = 'QR code non disponibile: le reti aziendali (802.1X) usano credenziali personali.' }
                Send-RWebJson $Ctx @{ error = $msg } 400; return
            }
            try { $qr = ConvertTo-WinUtilQRCode -Text (Get-WinUtilWifiQRText -Network $n) }
            catch { Send-RWebJson $Ctx @{ error = "Impossibile creare il QR code: $($_.Exception.Message)" } 500; return }
            Send-RWebJson $Ctx @{ ssid = [string]$n.Ssid; security = [string]$n.Security; open = (-not $n.Password); size = [int]$qr.Size; modules = (ConvertTo-RWebQRModules $qr) }
        }
        'POST /api/wifiqrsave' {
            $n = Get-RWebWifiNetwork ([string]$b.ssid)
            if (-not $n -or -not $n.CanShare) { Send-RWebJson $Ctx @{ error = 'Rete non disponibile.' } 400; return }
            & $start 'wifiqrsave' "QR code della rete $($n.Ssid)" @{ Ssid = [string]$n.Ssid }
        }
        'POST /api/wifiexport' { & $start 'wifiexport' 'Esportazione dei profili Wi-Fi' @{} }
        'POST /api/wifiimport' { & $start 'wifiimport' 'Importazione dei profili Wi-Fi' @{} }
        'POST /api/report' {
            $d = @{ Customer = (Get-RWebText $b.customer 200); Technician = (Get-RWebText $b.technician 200); Reference = (Get-RWebText $b.reference 200); Header = (Get-RWebText $b.header 1000); Notes = (Get-RWebText $b.notes 4000) }
            & $start 'report' 'Rapporto di intervento' @{ Details = $d }
        }
        'POST /api/report/clear' { if ($sync.SessionActions) { $sync.SessionActions.Clear() }; Send-RWebJson $Ctx @{ ok = $true } }
        'POST /api/sysexport' { & $start 'sysexport' 'Esportazione del report di sistema' @{} }
        'POST /api/manager' {
            $m = [string]$b.manager
            if ($m -in @('Winget', 'Choco')) { $sync.preferences.packagemanager = [PackageManagers]$m; try { Set-Preferences -save } catch { } }
            Send-RWebJson $Ctx @{ ok = $true }
        }
        'POST /api/classic' { & $start 'classic' 'Apertura della versione classica' @{ LocalFile = $st.ClassicFile } }
        'POST /api/exit' { Send-RWebJson $Ctx @{ ok = $true }; if ($st.Phase -ne 'running') { $st.Quit = $true } }
        default { Send-RWebJson $Ctx @{ error = 'not found' } 404 }
    }
}

function Find-RWebBrowser {
    $c = @()
    foreach ($b in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Microsoft\Edge\Application\msedge.exe' } }
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) { if ($b) { $c += Join-Path $b 'Google\Chrome\Application\chrome.exe' } }
    foreach ($p in $c) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Start-WinRUtilWebApp {
    param([string]$Html, [switch]$NoBrowser, [int]$IdleTimeout = 25)
    $st = $script:RWebState
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
    $st.Token = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $tl = New-Object System.Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $tl.Start(); $st.Port = ([Net.IPEndPoint]$tl.LocalEndpoint).Port; $tl.Stop()
    $st.Catalog = Get-RWebCatalog
    $prefix = "http://localhost:$($st.Port)/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try { $listener.Start() } catch { Write-Host "Impossibile avviare l'interfaccia su $prefix : $($_.Exception.Message)" -ForegroundColor Red; return }
    $url = "$prefix#$($st.Token)"
    if ($NoBrowser) { $IdleTimeout = 900; Write-Host "WinRUtil web in ascolto: $url" }
    else {
        $st.Browser = Find-RWebBrowser
        $st.ProfileDir = Join-Path ([IO.Path]::GetTempPath()) ('WinRUtilUI_' + [guid]::NewGuid().ToString('N').Substring(0, 12))
        if ($st.Browser) {
            $argList = @("--app=$url", "--user-data-dir=`"$($st.ProfileDir)`"", '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-sync', '--window-size=1320,900')
            $st.BrowserProc = Start-Process -FilePath $st.Browser -ArgumentList $argList -PassThru
        } else { Start-Process $url }
        Write-Host ''
        Write-Host '  WinRUtil e'' aperto nella sua finestra. Questa console si chiude da sola quando chiudi WinRUtil.' -ForegroundColor Green
    }
    try {
        while (-not $st.Quit) {
            $task = $listener.GetContextAsync()
            while (-not $task.AsyncWaitHandle.WaitOne(400)) {
                Update-RWebPhase
                $idle = ((Get-Date) - $st.LastActivity).TotalSeconds
                if ($st.Phase -ne 'running' -and $idle -gt $IdleTimeout) { $st.Quit = $true; break }
                if ($st.Quit) { break }
            }
            if ($st.Quit) { break }
            $ctx = $null
            try { $ctx = $task.GetAwaiter().GetResult() } catch { continue }
            try { Invoke-RWebRequest $ctx $Html } catch { try { Send-RWebJson $ctx @{ error = $_.Exception.Message } 500 } catch { } }
        }
    } finally {
        if ($st.Phase -eq 'running') {
            Write-Host '  Attendo la fine dell''operazione in corso...' -ForegroundColor Yellow
            while ($st.Handle -and -not $st.Handle.IsCompleted) { Start-Sleep -Milliseconds 500; Read-RWebStreams }
        }
        try { $listener.Stop(); $listener.Close() } catch { }
        Stop-RWebTask
        foreach ($q in @($st.Queries.Values)) { try { $q.PS.Dispose(); $q.RS.Close() } catch { } }
        if ($st.BrowserProc) { try { if (-not $st.BrowserProc.HasExited) { [void]$st.BrowserProc.CloseMainWindow() } } catch { } }
        if ($st.ProfileDir -and (Test-Path -LiteralPath $st.ProfileDir)) {
            Start-Sleep -Milliseconds 800
            try { Remove-Item -LiteralPath $st.ProfileDir -Recurse -Force -ErrorAction Stop } catch { }
        }
    }
}

# Avvio della variante con interfaccia HTML (winrutil-web.ps1)
if (-not ('PackageManagers' -as [type])) {
    Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@
}

$PARAM_NOUI = $true
$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}
$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
try { Set-Preferences } catch { }
if (-not $sync.preferences.packagemanager) { $sync.preferences.packagemanager = [PackageManagers]::Winget }

# Avviata da file (es. Compile.ps1 -RunWeb): la versione classica e' il winrutil.ps1 accanto, senza scaricarla
if ($PSCommandPath) {
    $classicFile = Join-Path (Split-Path -Parent $PSCommandPath) 'winrutil.ps1'
    if (Test-Path -LiteralPath $classicFile) { $script:RWebState.ClassicFile = $classicFile }
}

$Host.UI.RawUI.WindowTitle = "WinRUtil (Admin) - interfaccia web"
Show-WinRUtilLogo
Start-WinRUtilWebApp -Html $WinRUtilWebHtml -NoBrowser:($env:WINRUTIL_WEB_NOBROWSER -eq '1')
try { Stop-Transcript | Out-Null } catch { }
