<#
.NOTES
    WinRUtil - Windows toolkit
    Maintainer     : @rtecnocopy89
    GitHub         : https://github.com/rtecnocopy89/WinRUtil
    Copyright      : (c) 2026 rtecnocopy89 - (c) 2022 CT Tech Group LLC
    Based on       : ChrisTitusTech/winutil (MIT)
    Version        : 26.10.26
#>

param (
    [string]$Config,
    [switch]$Run,
    [switch]$Noui,
    [switch]$Offline
)

if ($Config) {
    $PARAM_CONFIG = $Config
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
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://raw.githubusercontent.com/rtecnocopy89/WinRUtil/master/winrutil.ps1))) $($argList -join ' ')"
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
$sync.version = "26.10.26"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
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
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .PARAMETER SearchString
            The string to be searched for
    #>
    param(
        [Parameter(Mandatory=$false)]
        [string]$SearchString = ""
    )
    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container
            $_.Visibility = [Windows.Visibility]::Visible

            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

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

    # Perform search
    $sync.ItemsControl.Items | ForEach-Object {
        # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
        if ($_.Children.Count -ge 2) {
            $categoryLabel = $_.Children[0]
            $wrapPanel = $_.Children[1]
            $categoryHasMatch = $false

            # Keep category label visible
            $categoryLabel.Visibility = [Windows.Visibility]::Visible

            # Search through apps in this category
            $wrapPanel.Children | ForEach-Object {
                $appEntry = $sync.configs.applicationsHashtable.$($_.Tag)
                if ($appEntry.Content -like "*$SearchString*" -or $appEntry.Description -like "*$SearchString*") {
                    # Show the App and mark that this category has a match
                    $_.Visibility = [Windows.Visibility]::Visible
                    $categoryHasMatch = $true
                }
                else {
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }

            # If category has matches, show the WrapPanel and update the category label to expanded state
            if ($categoryHasMatch) {
                $wrapPanel.Visibility = [Windows.Visibility]::Visible
                $_.Visibility = [Windows.Visibility]::Visible
                # Update category label to show expanded state (-)
                if ($categoryLabel.Content -like "+*") {
                    $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
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

    # Reset the visibility if the search string is empty or the search is cleared
    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        # Show all categories
        $tweakspanel = $sync.Form.FindName("tweakspanel")
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
    $tweakspanel = $sync.Form.FindName("tweakspanel")

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
        [PackageManagers]$Preference
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

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ($package.choco -eq "na") {
                    Write-Debug "$($package.content) has no Choco value."
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
                } else {
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                }
                break
            }
            "Winget" {
                if ($package.winget -eq "na") {
                    Write-Debug "$($package.content) has no WinGet value."
                    $null = $packagesChoco.add($package.choco)
                    Write-Host "Queueing $($package.choco) for Chocolatey..."
                } else {
                    $null = $packagesWinget.add($($package.winget))
                    Write-Host "Queueing $($package.winget) for WinGet..."
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

    try {
        if (($ToggleSwitchReg.path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
            if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                Write-Debug "HKU drive created successfully."
            } else {
                Write-Debug "Failed to create HKU drive."
            }
        }
    } catch {
        Write-Error "An error occurred regarding the HKU Drive: $_"
        return $false
    }

    if ($ToggleSwitchReg) {
        $count = 0

        foreach ($regentry in $ToggleSwitchReg) {
            try {
                if (!(Test-Path $regentry.Path)) {
                    New-Item -Path $regentry.Path -Force | Out-Null
                }
                $regstate = (Get-ItemProperty -path $regentry.Path).$($regentry.Name)
                if ($regstate -eq $regentry.Value) {
                    $count += 1
                    Write-Debug "$($regentry.Name) is true (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                } else {
                    Write-Debug "$($regentry.Name) is false (state: $regstate, value: $($regentry.Value), original: $($regentry.OriginalValue))"
                }
                if ($null -eq $regstate) {
                    switch ($regentry.DefaultState) {
                        "true" {
                            $regstate = $regentry.Value
                            $count += 1
                        }
                        "false" {
                            $regstate = $regentry.OriginalValue
                        }
                        default {
                            Write-Error "Entry for $($regentry.Name) does not exist and no DefaultState is defined."
                            $regstate = $regentry.OriginalValue
                        }
                    }
                }
            } catch {
                Write-Error "An unexpected error occurred: $_"
            }
        }

        if ($count -eq $ToggleSwitchReg.Count) {
            Write-Debug "$($ToggleSwitchReg.Name) is true (count: $count)"
            return $true
        } else {
            Write-Debug "$($ToggleSwitchReg.Name) is false (count: $count)"
            return $false
        }
    } else {
        return $false
    }
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

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $Apps.$appKey.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $Apps.$appKey.content

        # Change color to Green if FOSS
        if ($Apps.$appKey.foss -eq $true) {
            $appName.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "FOSSColor")
            $appName.FontWeight = "Bold"
        }

        # Add the name to the Checkbox
        $checkBox.Content = $appName

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $Apps.$appKey.content)

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

        # Pre-group apps by category
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
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
function Install-WinUtilChoco {

    <#

    .SYNOPSIS
        Installs Chocolatey if it is not already installed

    #>
    if ((Test-WinUtilPackageManager -choco) -eq "installed") {
        return
    }

    Write-Host "Chocolatey is not installed. Installing now..."
    Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression
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
        return (Start-Process -FilePath "choco" -ArgumentList $arguments -Wait -PassThru).ExitCode
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
            if ($installStatusCode -eq 0) {

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
                Write-Host "$Program" $(if ($uninstallStatusCode -eq 0) { "uninstalled successfully." } else { "failed to uninstall." })
                Add-ReportAction $Program "Disinstallazione di {0}" ($uninstallStatusCode -eq 0)
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

Function Install-WinUtilProgramWinget {
    <#
    .SYNOPSIS
    Runs the designated action on the provided programs using Winget

    .PARAMETER Programs
    A list of programs to process

    .PARAMETER action
    The action to perform on the programs, can be either 'Install' or 'Uninstall'

    .NOTES
    The triple quotes are required any time you need a " in a normal script block.
    The winget Return codes are documented here: https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-actionr/winget/returnCodes.md
    #>

    param(
        [Parameter(Mandatory, Position=0)]$Programs,

        [Parameter(Mandatory, Position=1)]
        [ValidateSet("Install", "Uninstall")]
        [String]$Action
    )

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

        $commonArguments = "--id $wingetId --silent"
        $arguments = if ($Action -eq "Install") {
            "install $commonArguments --accept-source-agreements --accept-package-agreements --source winget"
        } else {
            "uninstall $commonArguments --source winget"
        }

        $processParams = @{
            FilePath = "winget"
            ArgumentList = $arguments
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }

        return (Start-Process @processParams).ExitCode
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
        $status = Invoke-Winget -wingetId $Program
        if ($status -eq 0) {
            Write-Host "$($Program) installed successfully."
            return $true
        } elseif ($status -eq -1978335189) {
            Write-Host "No applicable update found for $($Program)."
            return $true
        }

        Write-Host "Failed to install $($Program)."
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
            if ($status -eq 0) {
                Write-Host "$($Program) uninstalled successfully."
                return $true
            } else {
                Write-Host "Failed to uninstall $($Program)."
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
        $appName = ($sync.configs.applicationsHashtable.Values | Where-Object { $_.winget -eq $Program } | Select-Object -First 1).content
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
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $Sync.InstalledPrograms = winget list -s winget | Select-Object -skip 3 | ConvertFrom-String -PropertyNames "Name", "Id", "Version", "Available" -Delimiter '\s{2,}'
        [Console]::OutputEncoding = $originalEncoding

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).winget -split ";")

            if ($dependencies[-1] -in $sync.InstalledPrograms.Id) {
                Write-Output $psitem.name
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

            if ($registryKeys -or $serviceKeys) {
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
                        $Service = Get-Service -Name $tweak.Name

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
    if($undo) {
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
    if($sync.configs.tweaks.$CheckBox.service) {
        Write-Debug "KeepServiceStartup is $KeepServiceStartup"
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        Write-Debug "Service $($service.Name) was changed in the past to $($service.StartType.ToString()) from it's original type of $($psitem.$($values.OriginalService)), will not change it to $($psitem.$($values.service))"
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if($changeservice) {
                Write-Debug "$($psitem.Name) and state is $($psitem.$($values.service))"
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Write-Debug "$($psitem.Name) and state is $($psitem.$($values.registry))"
            if (($psitem.Path -imatch "hku") -and !(Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                $null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)
                if (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue) {
                    Write-Debug "HKU drive created successfully."
                } else {
                    Write-Debug "Failed to create HKU drive."
                }
            }
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            Write-Debug "$($psitem) and state is $($psitem.$($values.ScriptType))"
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if(!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
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
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $Name | Remove-AppxProvisionedPackage -Online
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

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures
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
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
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
function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)
    if($DNSProvider -eq "Default") {return}
    $reportText = if ($DNSProvider -eq "DHCP") { "DNS - Imposta su automatico (DHCP)" } else { "DNS - Imposta su {0}" -f ($DNSProvider -replace "_", " ") }
    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary)", "$($sync.configs.dns.$DNSProvider.Secondary)")
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ("$($sync.configs.dns.$DNSProvider.Primary6)", "$($sync.configs.dns.$DNSProvider.Secondary6)")
            }
        }
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text $reportText
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Add-WinUtilSessionAction -Area "Ottimizzazione" -Text $reportText -Status "Error"
    }
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
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

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

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
    } catch [System.ServiceProcess.ServiceNotFoundException] {
        Write-Warning "Service $Name was not found."
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $_.Exception.Message
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
function Update-WinUtilSelections {
    <#

    .SYNOPSIS
        Updates the $sync.selected variables with a given preset.

    .PARAMETER flatJson
        The flattened json list of $sync values to select.
    #>

    param (
        $flatJson
    )

    Write-Debug "JSON to import: $($flatJson)"

    foreach ($item in $flatJson) {
        # Ensure each item is treated as a string to handle PSCustomObject from JSON deserialization
        $cbkey = [string]$item
        $group = if ($cbkey.StartsWith("WPFInstall")) { "Install" }
                    elseif ($cbkey.StartsWith("WPFTweaks")) { "Tweaks" }
                    elseif ($cbkey.StartsWith("WPFToggle")) { "Toggle" }
                    elseif ($cbkey.StartsWith("WPFFeature")) { "Feature" }
                    else { "na" }

        switch ($group) {
            "Install" {
                if (!$sync.selectedApps.Contains($cbkey)) {
                    $sync.selectedApps.Add($cbkey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            "Tweaks" {
                if (!$sync.selectedTweaks.Contains($cbkey)) {
                    $sync.selectedTweaks.Add($cbkey)
                }
            }
            "Toggle" {
                if (!$sync.selectedToggles.Contains($cbkey)) {
                    $sync.selectedToggles.Add($cbkey)
                }
            }
            "Feature" {
                if (!$sync.selectedFeatures.Contains($cbkey)) {
                    $sync.selectedFeatures.Add($cbkey)
                }
            }
            default {
                Write-Host "Unknown group for checkbox: $($cbkey)"
            }
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
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

    Write-Host "Applying tweaks..."
    Invoke-WPFtweaksbutton
    BusyWait

    Write-Host "Applying toggles..."
    $handle = Invoke-WPFRunspace -ScriptBlock {
        $Toggles = $sync.selectedToggles
        Write-Debug "Inside Number of toggles to process: $($Toggles.Count)"

        $sync.ProcessRunning = $true

        for ($i = 0; $i -lt $Tweaks.Count; $i++) {
            Invoke-WinUtilTweaks $Toggles[$i]
        }

        $sync.ProcessRunning = $false
        Write-Host "================================="
        Write-Host "--     Toggles are Finished    ---"
        Write-Host "================================="
    }
    BusyWait

    Write-Host "Applying features..."
    Invoke-WPFFeatureInstall
    BusyWait

    Write-Host "Installing applications..."
    Invoke-WPFInstall
    BusyWait

    Write-Host "Done."
}
function Invoke-WinUtilRemoveEdge {
  New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force

  $Path = Resolve-Path -Path "$Env:ProgramFiles (x86)\Microsoft\Edge\Application\*\Installer\setup.exe" | Select-Object -Last 1
  Start-Process -FilePath $Path -ArgumentList '--uninstall --system-level --force-uninstall --delete-profile' -Wait

  Write-Host "Microsoft Edge was removed" -ForegroundColor Green
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
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
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
        "WPFReportCreate" {Invoke-WPFReportCreate}
        "WPFReportClear" {Invoke-WPFReportClear}
        "WPFSystemInfoRefresh" {Invoke-WPFSystemInfoRefresh}
        "WPFSystemInfoExport" {Invoke-WPFSystemInfoExport}
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
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
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
        Add-WinUtilSessionAction -Area "Programmi" -Text "Aggiornamento di tutti i programmi (Chocolatey)" -Status "Info"
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
        Add-WinUtilSessionAction -Area "Programmi" -Text "Aggiornamento di tutti i programmi (WinGet)" -Status "Info"
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
        "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
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
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    # Create a PowerShell instance
    $script:powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    $script:powershell.AddScript($ScriptBlock)
    $script:powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        $script:powershell.AddParameter($parameter[0], $parameter[1])
    }

    $script:powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $script:handle = $script:powershell.BeginInvoke()

    # Clean up the RunspacePool threads when they are complete, and invoke the garbage collector to clean up the memory
    if ($script:handle.IsCompleted) {
        $script:powershell.EndInvoke($script:handle)
        $script:powershell.Dispose()
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
    }
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

    # Get the actual Name from the selectedAppLabel inside the Checkbox
    $appKey = $checkboxName
    $group = if ($appKey.StartsWith("WPFInstall")) { "Install" }
                elseif ($appKey.StartsWith("WPFTweaks")) { "Tweaks" }
                elseif ($appKey.StartsWith("WPFToggle")) { "Toggle" }
                elseif ($appKey.StartsWith("WPFFeature")) { "Feature" }
                else { "na" }

    switch ($group) {
        "Install" {
            if ($type -eq "Add") {
               if (!$sync.selectedApps.Contains($appKey)) {
                    $sync.selectedApps.Add($appKey)
                    # The List type needs to be specified again, because otherwise Sort-Object will convert the list to a string if there is only a single entry
                    [System.Collections.Generic.List[string]]$sync.selectedApps = $sync.SelectedApps | Sort-Object
                }
            }
            else{
                $sync.selectedApps.Remove($appKey)
            }

            $count = $sync.SelectedApps.Count
            $sync.WPFselectedAppsButton.Content = "App selezionate: $count"
            # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
            $sync.selectedAppsstackPanel.Children.Clear()
            $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }
        }
        "Tweaks" {
            if ($type -eq "Add") {
                if (!$sync.selectedTweaks.Contains($appKey)) {
                    $sync.selectedTweaks.Add($appKey)
                }
            }
            else{
                $sync.selectedTweaks.Remove($appKey)
            }
        }
        "Toggle" {
            if ($type -eq "Add") {
                if (!$sync.selectedToggles.Contains($appKey)) {
                    $sync.selectedToggles.Add($appKey)
                }
            }
            else{
                $sync.selectedToggles.Remove($appKey)
            }
        }
        "Feature" {
            if ($type -eq "Add") {
                if (!$sync.selectedFeatures.Contains($appKey)) {
                    $sync.selectedFeatures.Add($appKey)
                }
            }
            else{
                $sync.selectedFeatures.Remove($appKey)
            }
        }
        default {
            Write-Host "Unknown group for checkbox: $($appKey)"
        }
    }

    Write-Debug "-------------------------------------"
    Write-Debug "Selected Apps: $($sync.selectedApps)"
    Write-Debug "Selected Tweaks: $($sync.selectedTweaks)"
    Write-Debug "Selected Toggles: $($sync.selectedToggles)"
    Write-Debug "Selected Features: $($sync.selectedFeatures)"
    Write-Debug "--------------------------------------"
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
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

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
        }
        $display = $titleMap[[string]$sync.currentTab]
        if (-not $display) { $display = $sync.currentTab }
        $sync.WPFCurrentTabTitle.Text = $display
    }

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
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

    # Show search bar in Install and Tweaks tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1) {
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

    Set-WinUtilDNS -DNSProvider $dnsProvider

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
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
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

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference
        $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
        $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

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

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Removing Windows Update policy settings..." -ForegroundColor Green

    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green

    Write-Host "Restored BITS to Manual"
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual"
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic"
    Start-Service -Name UsoSvc
    Set-Service -Name UsoSvc -StartupType Automatic

    Write-Host "Restored WaaSMedicSvc to Manual"
    Set-Service -Name WaaSMedicSvc -StartupType Manual

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Windows Local Policies Reset to Default"
    secedit /configure /cfg "$Env:SystemRoot\inf\defltbase.inf" /db defltbase.sdb

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

    #>
    $ErrorActionPreference = 'SilentlyContinue'

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    Write-Host "Disabled BITS Service"
    Set-Service -Name BITS -StartupType Disabled

    Write-Host "Disabled wuauserv Service"
    Set-Service -Name wuauserv -StartupType Disabled

    Write-Host "Disabled UsoSvc Service"
    Stop-Service -Name UsoSvc -Force
    Set-Service -Name UsoSvc -StartupType Disabled

    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force
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
        Get-ScheduledTask -TaskPath $Task | Disable-ScheduledTask -ErrorAction SilentlyContinue
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
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>

    Write-Host "Disabling driver offering through Windows Update..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Setting cumulative updates back by 1 year and security updates by 4 days"

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    Write-Host "Disabling Windows Update automatic restart..."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0

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
    "WPFInstall1password":  {
                                "category":  "Utilities",
                                "choco":  "1password",
                                "content":  "1Password",
                                "description":  "1Password is a password manager that allows you to store and manage your passwords securely.",
                                "link":  "https://1password.com/",
                                "winget":  "AgileBits.1Password",
                                "foss":  false
                            },
    "WPFInstall7zip":  {
                           "category":  "Utilities",
                           "choco":  "7zip",
                           "content":  "7-Zip",
                           "description":  "7-Zip is a free and open-source file archiver utility. It supports several compression formats and provides a high compression ratio, making it a popular choice for file compression.",
                           "link":  "https://www.7-zip.org/",
                           "winget":  "7zip.7zip",
                           "foss":  true
                       },
    "WPFInstalladobe":  {
                            "category":  "Multimedia Tools",
                            "choco":  "adobereader",
                            "content":  "Adobe Acrobat Reader",
                            "description":  "Adobe Acrobat Reader is a free PDF viewer with essential features for viewing, printing, and annotating PDF documents.",
                            "link":  "https://www.adobe.com/acrobat/pdf-reader.html",
                            "winget":  "Adobe.Acrobat.Reader.64-bit",
                            "foss":  false
                        },
    "WPFInstalladvancedip":  {
                                 "category":  "Pro Tools",
                                 "choco":  "advanced-ip-scanner",
                                 "content":  "Advanced IP Scanner",
                                 "description":  "Advanced IP Scanner is a fast and easy-to-use network scanner. It is designed to analyze LAN networks and provides information about connected devices.",
                                 "link":  "https://www.advanced-ip-scanner.com/",
                                 "winget":  "Famatech.AdvancedIPScanner",
                                 "foss":  false
                             },
    "WPFInstallaimp":  {
                           "category":  "Multimedia Tools",
                           "choco":  "aimp",
                           "content":  "AIMP (Music Player)",
                           "description":  "AIMP is a feature-rich music player with support for various audio formats, playlists, and customizable user interface.",
                           "link":  "https://www.aimp.ru/",
                           "winget":  "AIMP.AIMP",
                           "foss":  false
                       },
    "WPFInstallangryipscanner":  {
                                     "category":  "Pro Tools",
                                     "choco":  "angryip",
                                     "content":  "Angry IP Scanner",
                                     "description":  "Angry IP Scanner is an open-source and cross-platform network scanner. It is used to scan IP addresses and ports, providing information about network connectivity.",
                                     "link":  "https://angryip.org/",
                                     "winget":  "angryziber.AngryIPScanner",
                                     "foss":  true
                                 },
    "WPFInstallanydesk":  {
                              "category":  "Utilities",
                              "choco":  "anydesk",
                              "content":  "AnyDesk",
                              "description":  "AnyDesk is a remote desktop software that enables users to access and control computers remotely. It is known for its fast connection and low latency.",
                              "link":  "https://anydesk.com/",
                              "winget":  "AnyDesk.AnyDesk",
                              "foss":  false
                          },
    "WPFInstallaudacity":  {
                               "category":  "Multimedia Tools",
                               "choco":  "audacity",
                               "content":  "Audacity",
                               "description":  "Audacity is a free and open-source audio editing software known for its powerful recording and editing capabilities.",
                               "link":  "https://www.audacityteam.org/",
                               "winget":  "Audacity.Audacity",
                               "foss":  true
                           },
    "WPFInstallautoruns":  {
                               "category":  "Microsoft Tools",
                               "choco":  "autoruns",
                               "content":  "Autoruns",
                               "description":  "This utility shows you what programs are configured to run during system bootup or login.",
                               "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
                               "winget":  "Microsoft.Sysinternals.Autoruns",
                               "foss":  false
                           },
    "WPFInstallrdcman":  {
                             "category":  "Microsoft Tools",
                             "choco":  "rdcman",
                             "content":  "RDCMan",
                             "description":  "RDCMan manages multiple remote desktop connections. It is useful for managing server labs where you need regular access to each machine such as automated checkin systems and data centers.",
                             "link":  "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
                             "winget":  "Microsoft.Sysinternals.RDCMan",
                             "foss":  false
                         },
    "WPFInstallautohotkey":  {
                                 "category":  "Utilities",
                                 "choco":  "autohotkey",
                                 "content":  "AutoHotkey",
                                 "description":  "AutoHotkey is a scripting language for Windows that allows users to create custom automation scripts and macros. It is often used for automating repetitive tasks and customizing keyboard shortcuts.",
                                 "link":  "https://www.autohotkey.com/",
                                 "winget":  "AutoHotkey.AutoHotkey",
                                 "foss":  true
                             },
    "WPFInstallbitwarden":  {
                                "category":  "Utilities",
                                "choco":  "bitwarden",
                                "content":  "Bitwarden",
                                "description":  "Bitwarden is an open-source password management solution. It allows users to store and manage their passwords in a secure and encrypted vault, accessible across multiple devices.",
                                "link":  "https://bitwarden.com/",
                                "winget":  "Bitwarden.Bitwarden",
                                "foss":  true
                            },
    "WPFInstallblender":  {
                              "category":  "Multimedia Tools",
                              "choco":  "blender",
                              "content":  "Blender (3D Graphics)",
                              "description":  "Blender is a powerful open-source 3D creation suite, offering modeling, sculpting, animation, and rendering tools.",
                              "link":  "https://www.blender.org/",
                              "winget":  "BlenderFoundation.Blender",
                              "foss":  true
                          },
    "WPFInstallbrave":  {
                            "category":  "Browsers",
                            "choco":  "brave",
                            "content":  "Brave",
                            "description":  "Brave is a privacy-focused web browser that blocks ads and trackers, offering a faster and safer browsing experience.",
                            "link":  "https://www.brave.com",
                            "winget":  "Brave.Brave",
                            "foss":  true
                        },
    "WPFInstallbulkcrapuninstaller":  {
                                          "category":  "Utilities",
                                          "choco":  "bulk-crap-uninstaller",
                                          "content":  "Bulk Crap Uninstaller",
                                          "description":  "Bulk Crap Uninstaller is a free and open-source uninstaller utility for Windows. It helps users remove unwanted programs and clean up their system by uninstalling multiple applications at once.",
                                          "link":  "https://www.bcuninstaller.com/",
                                          "winget":  "Klocman.BulkCrapUninstaller",
                                          "foss":  true
                                      },
    "WPFInstallblurautoclicker":  {
                                      "category":  "Utilities",
                                      "choco":  "na",
                                      "content":  "BlurAutoClicker",
                                      "description":  "An Auto-clicker with a few advanced features and generally better performance than popular alternatives.",
                                      "link":  "https://blur009.vercel.app/projects/blur-autoclicker/",
                                      "winget":  "Blur009.BlurAutoClicker",
                                      "foss":  true
                                  },
    "WPFInstallcalibre":  {
                              "category":  "Multimedia Tools",
                              "choco":  "calibre",
                              "content":  "Calibre",
                              "description":  "Calibre is a powerful and easy-to-use e-book manager, viewer, and converter.",
                              "link":  "https://calibre-ebook.com/",
                              "winget":  "calibre.calibre",
                              "foss":  true
                          },
    "WPFInstallcemu":  {
                           "category":  "Games",
                           "choco":  "cemu",
                           "content":  "Cemu",
                           "description":  "Cemu is a highly experimental software to emulate Wii U applications on PC.",
                           "link":  "https://cemu.info/",
                           "winget":  "Cemu.Cemu",
                           "foss":  true
                       },
    "WPFInstallchatterino":  {
                                 "category":  "Communications",
                                 "choco":  "chatterino",
                                 "content":  "Chatterino",
                                 "description":  "Chatterino is a chat client for Twitch chat that offers a clean and customizable interface for a better streaming experience.",
                                 "link":  "https://www.chatterino.com/",
                                 "winget":  "ChatterinoTeam.Chatterino",
                                 "foss":  true
                             },
    "WPFInstallchrome":  {
                             "category":  "Browsers",
                             "choco":  "googlechrome",
                             "content":  "Chrome",
                             "description":  "Google Chrome is a widely used web browser known for its speed, simplicity, and seamless integration with Google services.",
                             "link":  "https://www.google.com/chrome/",
                             "winget":  "Google.Chrome",
                             "foss":  false
                         },
    "WPFInstallchromium":  {
                               "category":  "Browsers",
                               "choco":  "chromium",
                               "content":  "Chromium",
                               "description":  "Chromium is the open-source project that serves as the foundation for various web browsers, including Chrome.",
                               "link":  "https://github.com/Hibbiki/chromium-win64",
                               "winget":  "Hibbiki.Chromium",
                               "foss":  true
                           },
    "WPFInstallcmake":  {
                            "category":  "Development",
                            "choco":  "cmake",
                            "content":  "CMake",
                            "description":  "CMake is an open-source, cross-platform family of tools designed to build, test and package software.",
                            "link":  "https://cmake.org/",
                            "winget":  "Kitware.CMake",
                            "foss":  true
                        },
    "WPFInstallcpuz":  {
                           "category":  "Pro Tools",
                           "choco":  "cpu-z",
                           "content":  "CPU-Z",
                           "description":  "CPU-Z is a system monitoring and diagnostic tool for Windows. It provides detailed information about the computer\u0027s hardware components, including the CPU, memory, and motherboard.",
                           "link":  "https://www.cpuid.com/softwares/cpu-z.html",
                           "winget":  "CPUID.CPU-Z",
                           "foss":  false
                       },
    "WPFInstallcrystaldiskinfo":  {
                                      "category":  "Utilities",
                                      "choco":  "crystaldiskinfo",
                                      "content":  "Crystal Disk Info",
                                      "description":  "Crystal Disk Info is a disk health monitoring tool that provides information about the status and performance of hard drives. It helps users anticipate potential issues and monitor drive health.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskinfo/",
                                      "winget":  "CrystalDewWorld.CrystalDiskInfo",
                                      "foss":  true
                                  },
    "WPFInstallcrystaldiskmark":  {
                                      "category":  "Utilities",
                                      "choco":  "crystaldiskmark",
                                      "content":  "Crystal Disk Mark",
                                      "description":  "Crystal Disk Mark is a disk benchmarking tool that measures the read and write speeds of storage devices. It helps users assess the performance of their hard drives and SSDs.",
                                      "link":  "https://crystalmark.info/en/software/crystaldiskmark/",
                                      "winget":  "CrystalDewWorld.CrystalDiskMark",
                                      "foss":  true
                                  },
    "WPFInstallcursor":  {
                             "category":  "Development",
                             "choco":  "cursoride",
                             "content":  "Cursor",
                             "description":  "AI-powered code editor (VS Code-based) with agentic coding features and integrated AI assistance for development workflows.",
                             "link":  "https://cursor.com/",
                             "winget":  "Anysphere.Cursor",
                             "foss":  false
                         },
    "WPFInstallddu":  {
                          "category":  "Pro Tools",
                          "choco":  "ddu",
                          "content":  "Display Driver Uninstaller",
                          "description":  "Display Driver Uninstaller (DDU) is a tool for completely uninstalling graphics drivers from NVIDIA, AMD, and Intel. It is useful for troubleshooting graphics driver-related issues.",
                          "link":  "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
                          "winget":  "Wagnardsoft.DisplayDriverUninstaller",
                          "foss":  true
                      },
    "WPFInstalldiscord":  {
                              "category":  "Communications",
                              "choco":  "discord",
                              "content":  "Discord",
                              "description":  "Discord is a popular communication platform with voice, video, and text chat, designed for gamers but used by a wide range of communities.",
                              "link":  "https://discord.com/",
                              "winget":  "Discord.Discord",
                              "foss":  false
                          },
    "WPFInstalldismtools":  {
                                "category":  "Microsoft Tools",
                                "choco":  "dismtools",
                                "content":  "DISMTools",
                                "description":  "DISMTools is a fast, customizable GUI for the DISM utility, supporting Windows images from Windows 7 onward. It handles installations on any drive, offers project support, and lets users tweak settings like color modes, language, and DISM versions; powered by both native DISM and a managed DISM API.",
                                "link":  "https://github.com/CodingWonders/DISMTools",
                                "winget":  "CodingWondersSoftware.DISMTools.Stable",
                                "foss":  true
                            },
    "WPFInstallntlite":  {
                             "category":  "Microsoft Tools",
                             "choco":  "ntlite-free",
                             "content":  "NTLite",
                             "description":  "Integrate updates, drivers, automate Windows and application setup, speedup Windows deployment process and have it all set for the next time.",
                             "link":  "https://ntlite.com",
                             "winget":  "Nlitesoft.NTLite",
                             "foss":  false
                         },
    "WPFInstalldorion":  {
                             "category":  "Communications",
                             "choco":  "dorion",
                             "content":  "Dorion",
                             "description":  "Tiny alternative Discord client with a smaller footprint, snappier startup, themes, plugins and more!",
                             "link":  "https://github.com/SpikeHD/Dorion",
                             "winget":  "SpikeHD.Dorion",
                             "foss":  true
                         },
    "WPFInstalldotnet6":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-6.0-runtime",
                              "content":  ".NET Desktop Runtime 6",
                              "description":  ".NET Desktop Runtime 6 is a runtime environment required for running applications developed with .NET 6.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/6.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.6",
                              "foss":  true
                          },
    "WPFInstalldotnet8":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-8.0-runtime",
                              "content":  ".NET Desktop Runtime 8",
                              "description":  ".NET Desktop Runtime 8 is a runtime environment required for running applications developed with .NET 8.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/8.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.8",
                              "foss":  true
                          },
    "WPFInstalldotnet9":  {
                              "category":  "Microsoft Tools",
                              "choco":  "dotnet-9.0-runtime",
                              "content":  ".NET Desktop Runtime 9",
                              "description":  ".NET Desktop Runtime 9 is a runtime environment required for running applications developed with .NET 9.",
                              "link":  "https://dotnet.microsoft.com/download/dotnet/9.0",
                              "winget":  "Microsoft.DotNet.DesktopRuntime.9",
                              "foss":  true
                          },
    "WPFInstalldotnet10":  {
                               "category":  "Microsoft Tools",
                               "choco":  "dotnet-10.0-runtime",
                               "content":  ".NET Desktop Runtime 10",
                               "description":  ".NET Desktop Runtime 10 is a runtime environment required for running applications developed with .NET 10.",
                               "link":  "https://dotnet.microsoft.com/download/dotnet/10.0",
                               "winget":  "Microsoft.DotNet.DesktopRuntime.10",
                               "foss":  true
                           },
    "WPFInstalleaapp":  {
                            "category":  "Games",
                            "choco":  "ea-app",
                            "content":  "EA App",
                            "description":  "EA App is a platform for accessing and playing Electronic Arts games.",
                            "link":  "https://www.ea.com/ea-app",
                            "winget":  "ElectronicArts.EADesktop",
                            "foss":  false
                        },
    "WPFInstalleartrumpet":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "eartrumpet",
                                 "content":  "EarTrumpet (Audio)",
                                 "description":  "EarTrumpet is an audio control app for Windows, providing a simple and intuitive interface for managing sound settings.",
                                 "link":  "https://eartrumpet.app/",
                                 "winget":  "File-New-Project.EarTrumpet",
                                 "foss":  true
                             },
    "WPFInstalledge":  {
                           "category":  "Browsers",
                           "choco":  "microsoft-edge",
                           "content":  "Edge",
                           "description":  "Microsoft Edge is a modern web browser built on Chromium, offering performance, security, and integration with Microsoft services.",
                           "link":  "https://www.microsoft.com/edge",
                           "winget":  "Microsoft.Edge",
                           "foss":  false
                       },
    "WPFInstallenteauth":  {
                               "category":  "Utilities",
                               "choco":  "ente-auth",
                               "content":  "Ente Auth",
                               "description":  "Ente Auth is a free, cross-platform, end-to-end encrypted authenticator app.",
                               "link":  "https://ente.io/auth/",
                               "winget":  "ente-io.auth-desktop",
                               "foss":  true
                           },
    "WPFInstallepicgames":  {
                                "category":  "Games",
                                "choco":  "epicgameslauncher",
                                "content":  "Epic Games Launcher",
                                "description":  "Epic Games Launcher is the client for accessing and playing games from the Epic Games Store.",
                                "link":  "https://www.epicgames.com/store/en-US/",
                                "winget":  "EpicGames.EpicGamesLauncher",
                                "foss":  false
                            },
    "WPFInstallfiles":  {
                            "category":  "Utilities",
                            "choco":  "files",
                            "content":  "Files",
                            "description":  "Alternative file explorer.",
                            "link":  "https://github.com/files-community/Files",
                            "winget":  "FilesCommunity.Files",
                            "foss":  true
                        },
    "WPFInstallfirefox":  {
                              "category":  "Browsers",
                              "choco":  "firefox",
                              "content":  "Firefox",
                              "description":  "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions.",
                              "link":  "https://www.mozilla.org/en-US/firefox/new/",
                              "winget":  "Mozilla.Firefox",
                              "foss":  true
                          },
    "WPFInstallfirefoxesr":  {
                                 "category":  "Browsers",
                                 "choco":  "FirefoxESR",
                                 "content":  "Firefox ESR",
                                 "description":  "Mozilla Firefox is an open-source web browser known for its customization options, privacy features, and extensions. Firefox ESR (Extended Support Release) receives major updates every 42 weeks with minor updates such as crash fixes, security fixes and policy updates as needed, but at least every four weeks.",
                                 "link":  "https://www.mozilla.org/en-US/firefox/enterprise/",
                                 "winget":  "Mozilla.Firefox.ESR",
                                 "foss":  true
                             },
    "WPFInstallfloorp":  {
                             "category":  "Browsers",
                             "choco":  "floorp",
                             "content":  "Floorp",
                             "description":  "Floorp is an open-source web browser project that aims to provide a simple and fast browsing experience.",
                             "link":  "https://floorp.app/",
                             "winget":  "Ablaze.Floorp",
                             "foss":  true
                         },
    "WPFInstallflux":  {
                           "category":  "Utilities",
                           "choco":  "flux",
                           "content":  "F.lux",
                           "description":  "f.lux adjusts the color temperature of your screen to reduce eye strain during nighttime use.",
                           "link":  "https://justgetflux.com/",
                           "winget":  "flux.flux",
                           "foss":  false
                       },
    "WPFInstallgeforcenow":  {
                                 "category":  "Games",
                                 "choco":  "nvidia-geforce-now",
                                 "content":  "GeForce NOW",
                                 "description":  "GeForce NOW is a cloud gaming service that allows you to play high-quality PC games on your device.",
                                 "link":  "https://www.nvidia.com/en-us/geforce-now/",
                                 "winget":  "Nvidia.GeForceNow",
                                 "foss":  false
                             },
    "WPFInstallgimp":  {
                           "category":  "Multimedia Tools",
                           "choco":  "gimp",
                           "content":  "GIMP (Image Editor)",
                           "description":  "GIMP is a versatile open-source raster graphics editor used for tasks such as photo retouching, image editing, and image composition.",
                           "link":  "https://www.gimp.org/",
                           "winget":  "GIMP.GIMP.3",
                           "foss":  true
                       },
    "WPFInstallgit":  {
                          "category":  "Development",
                          "choco":  "git",
                          "content":  "Git",
                          "description":  "Git is a distributed version control system widely used for tracking changes in source code during software development.",
                          "link":  "https://git-scm.com/",
                          "winget":  "Git.Git",
                          "foss":  true
                      },
    "WPFInstallgithubdesktop":  {
                                    "category":  "Development",
                                    "choco":  "git;github-desktop",
                                    "content":  "GitHub Desktop",
                                    "description":  "GitHub Desktop is a visual Git client that simplifies collaboration on GitHub repositories with an easy-to-use interface.",
                                    "link":  "https://desktop.github.com/",
                                    "winget":  "GitHub.GitHubDesktop",
                                    "foss":  true
                                },
    "WPFInstallgog":  {
                          "category":  "Games",
                          "choco":  "goggalaxy",
                          "content":  "GOG Galaxy",
                          "description":  "GOG Galaxy is a gaming client that offers DRM-free games, additional content, and more.",
                          "link":  "https://www.gog.com/galaxy",
                          "winget":  "GOG.Galaxy",
                          "foss":  false
                      },
    "WPFInstallgolang":  {
                             "category":  "Development",
                             "choco":  "golang",
                             "content":  "Go",
                             "description":  "Go (or Golang) is a statically typed, compiled programming language designed for simplicity, reliability, and efficiency.",
                             "link":  "https://go.dev/",
                             "winget":  "GoLang.Go",
                             "foss":  true
                         },
    "WPFInstallgoogledrive":  {
                                  "category":  "Utilities",
                                  "choco":  "googledrive",
                                  "content":  "Google Drive",
                                  "description":  "File syncing across devices all tied to your Google account.",
                                  "link":  "https://www.google.com/drive/",
                                  "winget":  "Google.GoogleDrive",
                                  "foss":  false
                              },
    "WPFInstallgpuz":  {
                           "category":  "Pro Tools",
                           "choco":  "gpu-z",
                           "content":  "GPU-Z",
                           "description":  "GPU-Z provides detailed information about your graphics card and GPU.",
                           "link":  "https://www.techpowerup.com/gpuz/",
                           "winget":  "TechPowerUp.GPU-Z",
                           "foss":  false
                       },
    "WPFInstallhelium":  {
                             "category":  "Browsers",
                             "choco":  "helium",
                             "content":  "Helium",
                             "description":  "Private, fast, and honest web browser.",
                             "link":  "https://github.com/imputnet/helium/",
                             "winget":  "ImputNet.Helium",
                             "foss":  true
                         },
    "WPFInstallhugo":  {
                           "category":  "Utilities",
                           "choco":  "hugo-extended",
                           "content":  "Hugo",
                           "description":  "The world\u0027s fastest framework for building websites.",
                           "link":  "https://github.com/gohugoio/hugo/",
                           "winget":  "Hugo.Hugo.Extended",
                           "foss":  true
                       },
    "WPFInstallhandbrake":  {
                                "category":  "Multimedia Tools",
                                "choco":  "handbrake",
                                "content":  "HandBrake",
                                "description":  "HandBrake is an open-source video transcoder, allowing you to convert video from nearly any format to a selection of widely supported codecs.",
                                "link":  "https://handbrake.fr/",
                                "winget":  "HandBrake.HandBrake",
                                "foss":  true
                            },
    "WPFInstallheroiclauncher":  {
                                     "category":  "Games",
                                     "choco":  "na",
                                     "content":  "Heroic Games Launcher",
                                     "description":  "Heroic Games Launcher is an open-source alternative game launcher for Epic Games Store.",
                                     "link":  "https://heroicgameslauncher.com/",
                                     "winget":  "HeroicGamesLauncher.HeroicGamesLauncher",
                                     "foss":  true
                                 },
    "WPFInstallhwinfo":  {
                             "category":  "Pro Tools",
                             "choco":  "hwinfo",
                             "content":  "HWiNFO",
                             "description":  "HWiNFO provides comprehensive hardware information and diagnostics for Windows.",
                             "link":  "https://www.hwinfo.com/",
                             "winget":  "REALiX.HWiNFO",
                             "foss":  false
                         },
    "WPFInstallhwmonitor":  {
                                "category":  "Pro Tools",
                                "choco":  "hwmonitor",
                                "content":  "HWMonitor",
                                "description":  "HWMonitor is a hardware monitoring program that reads PC systems main health sensors.",
                                "link":  "https://www.cpuid.com/softwares/hwmonitor.html",
                                "winget":  "CPUID.HWMonitor",
                                "foss":  false
                            },
    "WPFInstallimageglass":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "imageglass",
                                 "content":  "ImageGlass (Image Viewer)",
                                 "description":  "ImageGlass is a versatile image viewer with support for various image formats and a focus on simplicity and speed.",
                                 "link":  "https://imageglass.org/",
                                 "winget":  "DuongDieuPhap.ImageGlass",
                                 "foss":  true
                             },
    "WPFInstallirfanview":  {
                                "category":  "Multimedia Tools",
                                "choco":  "irfanview",
                                "content":  "IrfanView",
                                "description":  "IrfanView is a lightweight, fast, and free image viewer and editor. Supports multiple formats, batch processing, and powerful plugins.",
                                "link":  "https://irfanview.com/",
                                "winget":  "IrfanSkiljan.IrfanView"
                            },
    "WPFInstallitch":  {
                           "category":  "Games",
                           "choco":  "itch",
                           "content":  "Itch.io",
                           "description":  "Itch.io is a digital distribution platform for indie games and creative projects.",
                           "link":  "https://itch.io/",
                           "winget":  "ItchIo.Itch",
                           "foss":  true
                       },
    "WPFInstallitunes":  {
                             "category":  "Multimedia Tools",
                             "choco":  "itunes",
                             "content":  "iTunes",
                             "description":  "iTunes is a media player, media library, and online radio broadcaster application developed by Apple Inc.",
                             "link":  "https://www.apple.com/itunes/",
                             "winget":  "Apple.iTunes",
                             "foss":  false
                         },
    "WPFInstalljava8":  {
                            "category":  "Development",
                            "choco":  "corretto8jdk",
                            "content":  "Amazon Corretto 8 (LTS)",
                            "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                            "link":  "https://aws.amazon.com/corretto",
                            "winget":  "Amazon.Corretto.8.JDK",
                            "foss":  true
                        },
    "WPFInstalljava21":  {
                             "category":  "Development",
                             "choco":  "corretto21jdk",
                             "content":  "Amazon Corretto 21 (LTS)",
                             "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.21.JDK",
                             "foss":  true
                         },
    "WPFInstalljava25":  {
                             "category":  "Development",
                             "choco":  "corretto25jdk",
                             "content":  "Amazon Corretto 25 (LTS)",
                             "description":  "Amazon Corretto is a no-cost, multiplatform, production-ready distribution of the Open Java Development Kit (OpenJDK).",
                             "link":  "https://aws.amazon.com/corretto",
                             "winget":  "Amazon.Corretto.25.JDK",
                             "foss":  true
                         },
    "WPFInstalljellyfinmediaplayer":  {
                                          "category":  "Selfhosted Tools",
                                          "choco":  "jellyfin-media-player",
                                          "content":  "Jellyfin Media Player",
                                          "description":  "Jellyfin Media Player is a client application for the Jellyfin media server, providing access to your media library.",
                                          "link":  "https://github.com/jellyfin/jellyfin-media-player",
                                          "winget":  "Jellyfin.JellyfinMediaPlayer",
                                          "foss":  true
                                      },
    "WPFInstalljellyfinserver":  {
                                     "category":  "Selfhosted Tools",
                                     "choco":  "jellyfin",
                                     "content":  "Jellyfin Server",
                                     "description":  "Jellyfin Server is an open-source media server software, allowing you to organize and stream your media library.",
                                     "link":  "https://jellyfin.org/",
                                     "winget":  "Jellyfin.Server",
                                     "foss":  true
                                 },
    "WPFInstalljetbrains":  {
                                "category":  "Development",
                                "choco":  "jetbrainstoolbox",
                                "content":  "Jetbrains Toolbox",
                                "description":  "Jetbrains Toolbox is a platform for easy installation and management of JetBrains developer tools.",
                                "link":  "https://www.jetbrains.com/toolbox/",
                                "winget":  "JetBrains.Toolbox",
                                "foss":  false
                            },
    "WPFInstalljpegview":  {
                               "category":  "Utilities",
                               "choco":  "jpegview",
                               "content":  "JPEG View",
                               "description":  "JPEGView is a lean, fast and highly configurable viewer/editor for JPEG, BMP, PNG, WEBP, TGA, GIF, JXL, HEIC, HEIF, AVIF and TIFF images with a minimal GUI.",
                               "link":  "https://github.com/sylikc/jpegview",
                               "winget":  "sylikc.JPEGView",
                               "foss":  true
                           },
    "WPFInstallklite":  {
                            "category":  "Multimedia Tools",
                            "choco":  "k-litecodecpack-standard",
                            "content":  "K-Lite Codec Standard",
                            "description":  "K-Lite Codec Pack Standard is a collection of audio and video codecs and related tools, providing essential components for media playback.",
                            "link":  "https://www.codecguide.com/",
                            "winget":  "CodecGuide.K-LiteCodecPack.Standard",
                            "foss":  false
                        },
    "WPFInstallkodi":  {
                           "category":  "Selfhosted Tools",
                           "choco":  "kodi",
                           "content":  "Kodi Media Center",
                           "description":  "Kodi is an open-source media center application that allows you to play and view most videos, music, podcasts, and other digital media files.",
                           "link":  "https://kodi.tv/",
                           "winget":  "XBMCFoundation.Kodi",
                           "foss":  true
                       },
    "WPFInstalllazygit":  {
                              "category":  "Development",
                              "choco":  "lazygit",
                              "content":  "Lazygit",
                              "description":  "Simple terminal UI for git commands.",
                              "link":  "https://github.com/jesseduffield/lazygit/",
                              "winget":  "JesseDuffield.lazygit",
                              "foss":  true
                          },
    "WPFInstalllibreoffice":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "libreoffice-fresh",
                                  "content":  "LibreOffice",
                                  "description":  "LibreOffice is a powerful and free office suite, compatible with other major office suites.",
                                  "link":  "https://www.libreoffice.org/",
                                  "winget":  "TheDocumentFoundation.LibreOffice",
                                  "foss":  true
                              },
    "WPFInstalllibrewolf":  {
                                "category":  "Browsers",
                                "choco":  "librewolf",
                                "content":  "LibreWolf",
                                "description":  "LibreWolf is a privacy-focused web browser based on Firefox, with additional privacy and security enhancements.",
                                "link":  "https://librewolf-community.gitlab.io/",
                                "winget":  "LibreWolf.LibreWolf",
                                "foss":  true
                            },
    "WPFInstalllocalsend":  {
                                "category":  "Selfhosted Tools",
                                "choco":  "localsend.install",
                                "content":  "LocalSend",
                                "description":  "An open-source cross-platform alternative to AirDrop.",
                                "link":  "https://localsend.org/",
                                "winget":  "LocalSend.LocalSend",
                                "foss":  true
                            },
    "WPFInstallmpc-qt":  {
                             "category":  "Multimedia Tools",
                             "choco":  "mediainfo",
                             "content":  "mpc-qt",
                             "description":  "MPC-HC (Media Player Classic Home Cinema) is considered by many to be the quintessential media player for the Windows desktop. MPC-QT (Media Player Classic Qute Theater) aims to reproduce most of the interface and functionality of MPC-HC while using libmpv to play video instead of DirectShow.",
                             "link":  "https://github.com/mpc-qt/mpc-qt",
                             "winget":  "mpc-qt.mpc-qt",
                             "foss":  true
                         },
    "WPFInstallmatrix":  {
                             "category":  "Communications",
                             "choco":  "element-desktop",
                             "content":  "Element",
                             "description":  "Element is a client for Matrix; an open network for secure, decentralized communication.",
                             "link":  "https://element.io/",
                             "winget":  "Element.Element",
                             "foss":  true
                         },
    "WPFInstallmodrinth":  {
                               "category":  "Games",
                               "choco":  "na",
                               "content":  "Modrinth App",
                               "description":  "Modrinth App is a desktop application for managing Minecraft mods and modpacks.",
                               "link":  "https://modrinth.com/app",
                               "winget":  "Modrinth.ModrinthApp",
                               "foss":  true
                           },
    "WPFInstallmoonlight":  {
                                "category":  "Selfhosted Tools",
                                "choco":  "moonlight-qt",
                                "content":  "Moonlight/GameStream Client",
                                "description":  "Moonlight/GameStream Client allows you to stream PC games to other devices over your local network.",
                                "link":  "https://moonlight-stream.org/",
                                "winget":  "MoonlightGameStreamingProject.Moonlight",
                                "foss":  true
                            },
    "WPFInstallmpchc":  {
                            "category":  "Multimedia Tools",
                            "choco":  "mpc-hc-clsid2",
                            "content":  "Media Player Classic - Home Cinema",
                            "description":  "Media Player Classic - Home Cinema (MPC-HC) is a free and open-source video and audio player for Windows. MPC-HC is based on the original Guliverkli project and contains many additional features and bug fixes.",
                            "link":  "https://github.com/clsid2/mpc-hc/",
                            "winget":  "clsid2.mpc-hc",
                            "foss":  true
                        },
    "WPFInstallmsedgeredirect":  {
                                     "category":  "Utilities",
                                     "choco":  "msedgeredirect",
                                     "content":  "MSEdgeRedirect",
                                     "description":  "A Tool to Redirect News, Search, Widgets, Weather, and More to your default browser.",
                                     "link":  "https://github.com/rcmaehl/MSEdgeRedirect",
                                     "winget":  "rcmaehl.MSEdgeRedirect",
                                     "foss":  true
                                 },
    "WPFInstallmsiafterburner":  {
                                     "category":  "Utilities",
                                     "choco":  "msiafterburner",
                                     "content":  "MSI Afterburner",
                                     "description":  "MSI Afterburner is a graphics card overclocking utility with advanced features.",
                                     "link":  "https://www.msi.com/Landing/afterburner",
                                     "winget":  "Guru3D.Afterburner",
                                     "foss":  false
                                 },
    "WPFInstallmullvadvpn":  {
                                 "category":  "Pro Tools",
                                 "choco":  "mullvad-app",
                                 "content":  "Mullvad VPN",
                                 "description":  "This is the VPN client software for the Mullvad VPN service.",
                                 "link":  "https://github.com/mullvad/mullvadvpn-app",
                                 "winget":  "MullvadVPN.MullvadVPN",
                                 "foss":  true
                             },
    "WPFInstallmullvadbrowser":  {
                                     "category":  "Browsers",
                                     "choco":  "na",
                                     "content":  "Mullvad Browser",
                                     "description":  "Mullvad Browser is a privacy-focused web browser, developed in partnership with the Tor Project.",
                                     "link":  "https://mullvad.net/browser",
                                     "winget":  "MullvadVPN.MullvadBrowser",
                                     "foss":  true
                                 },
    "WPFInstallnanazip":  {
                              "category":  "Utilities",
                              "choco":  "nanazip",
                              "content":  "NanaZip",
                              "description":  "NanaZip is a fast and efficient file compression and decompression tool.",
                              "link":  "https://github.com/M2Team/NanaZip",
                              "winget":  "M2Team.NanaZip",
                              "foss":  true
                          },
    "WPFInstallnetbird":  {
                              "category":  "Selfhosted Tools",
                              "choco":  "netbird",
                              "content":  "NetBird",
                              "description":  "NetBird is a open-source alternative comparable to TailScale that can be connected to a self-hosted server.",
                              "link":  "https://netbird.io/",
                              "winget":  "Netbird.Netbird",
                              "foss":  true
                          },
    "WPFInstallnaps2":  {
                            "category":  "Multimedia Tools",
                            "choco":  "naps2",
                            "content":  "NAPS2 (Document Scanner)",
                            "description":  "NAPS2 is a document scanning application that simplifies the process of creating electronic documents.",
                            "link":  "https://www.naps2.com/",
                            "winget":  "Cyanfish.NAPS2",
                            "foss":  true
                        },
    "WPFInstallneovim":  {
                             "category":  "Development",
                             "choco":  "neovim",
                             "content":  "Neovim",
                             "description":  "Neovim is a highly extensible text editor and an improvement over the original Vim editor.",
                             "link":  "https://neovim.io/",
                             "winget":  "Neovim.Neovim",
                             "foss":  true
                         },
    "WPFInstallnextclouddesktop":  {
                                       "category":  "Selfhosted Tools",
                                       "choco":  "nextcloud-client",
                                       "content":  "Nextcloud Desktop",
                                       "description":  "Nextcloud Desktop is the official desktop client for the Nextcloud file synchronization and sharing platform.",
                                       "link":  "https://nextcloud.com/install/#install-clients",
                                       "winget":  "Nextcloud.NextcloudDesktop",
                                       "foss":  true
                                   },
    "WPFInstallnmap":  {
                           "category":  "Pro Tools",
                           "choco":  "nmap",
                           "content":  "Nmap",
                           "description":  "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
                           "link":  "https://nmap.org/",
                           "winget":  "Insecure.Nmap",
                           "foss":  true
                       },
    "WPFInstallnodejs":  {
                             "category":  "Development",
                             "choco":  "nodejs",
                             "content":  "NodeJS",
                             "description":  "NodeJS is a JavaScript runtime built on Chrome\u0027s V8 JavaScript engine for building server-side and networking applications.",
                             "link":  "https://nodejs.org/",
                             "winget":  "OpenJS.NodeJS",
                             "foss":  true
                         },
    "WPFInstallnodejslts":  {
                                "category":  "Development",
                                "choco":  "nodejs-lts",
                                "content":  "NodeJS LTS",
                                "description":  "NodeJS LTS provides Long-Term Support releases for stable and reliable server-side JavaScript development.",
                                "link":  "https://nodejs.org/",
                                "winget":  "OpenJS.NodeJS.LTS",
                                "foss":  true
                            },
    "WPFInstallnotepadplus":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "notepadplusplus",
                                  "content":  "Notepad++",
                                  "description":  "Notepad++ is a free, open-source code editor and Notepad replacement with support for multiple languages.",
                                  "link":  "https://notepad-plus-plus.org/",
                                  "winget":  "Notepad++.Notepad++",
                                  "foss":  true
                              },
    "WPFInstallnuget":  {
                            "category":  "Microsoft Tools",
                            "choco":  "nuget.commandline",
                            "content":  "NuGet",
                            "description":  "NuGet is a package manager for the .NET framework, enabling developers to manage and share libraries in their .NET applications.",
                            "link":  "https://www.nuget.org/",
                            "winget":  "Microsoft.NuGet",
                            "foss":  true
                        },
    "WPFInstallnvclean":  {
                              "category":  "Utilities",
                              "choco":  "na",
                              "content":  "NVCleanstall",
                              "description":  "NVCleanstall is a tool designed to customize NVIDIA driver installations, allowing advanced users to control more aspects of the installation process.",
                              "link":  "https://www.techpowerup.com/nvcleanstall/",
                              "winget":  "TechPowerUp.NVCleanstall",
                              "foss":  false
                          },
    "WPFInstallobs":  {
                          "category":  "Multimedia Tools",
                          "choco":  "obs-studio",
                          "content":  "OBS Studio",
                          "description":  "OBS Studio is a free and open-source software for video recording and live streaming. It supports real-time video/audio capturing and mixing, making it popular among content creators.",
                          "link":  "https://obsproject.com/",
                          "winget":  "OBSProject.OBSStudio",
                          "foss":  true
                      },
    "WPFInstallobsidian":  {
                               "category":  "Multimedia Tools",
                               "choco":  "obsidian",
                               "content":  "Obsidian",
                               "description":  "Obsidian is a powerful note-taking and knowledge management application.",
                               "link":  "https://obsidian.md/",
                               "winget":  "Obsidian.Obsidian",
                               "foss":  false
                           },
    "WPFInstallonedrive":  {
                               "category":  "Microsoft Tools",
                               "choco":  "onedrive",
                               "content":  "OneDrive",
                               "description":  "OneDrive is a cloud storage service provided by Microsoft, allowing users to store and share files securely across devices.",
                               "link":  "https://onedrive.live.com/",
                               "winget":  "Microsoft.OneDrive",
                               "foss":  false
                           },
    "WPFInstallonlyoffice":  {
                                 "category":  "Multimedia Tools",
                                 "choco":  "onlyoffice",
                                 "content":  "ONLYOffice Desktop",
                                 "description":  "ONLYOffice Desktop is a comprehensive office suite for document editing and collaboration.",
                                 "link":  "https://www.onlyoffice.com/desktop.aspx",
                                 "winget":  "ONLYOFFICE.DesktopEditors",
                                 "foss":  true
                             },
    "WPFInstallOPAutoClicker":  {
                                    "category":  "Utilities",
                                    "choco":  "autoclicker",
                                    "content":  "OPAutoClicker",
                                    "description":  "A full-fledged autoclicker with two modes of autoclicking, at your dynamic cursor location or at a prespecified location.",
                                    "link":  "https://www.opautoclicker.com",
                                    "winget":  "OPAutoClicker.OPAutoClicker",
                                    "foss":  false
                                },
    "WPFInstallopenrgb":  {
                              "category":  "Utilities",
                              "choco":  "openrgb",
                              "content":  "OpenRGB",
                              "description":  "OpenRGB is an open-source RGB lighting control software designed to manage and control RGB lighting for various components and peripherals.",
                              "link":  "https://openrgb.org/",
                              "winget":  "OpenRGB.OpenRGB",
                              "foss":  true
                          },
    "WPFInstallOpenVPN":  {
                              "category":  "Pro Tools",
                              "choco":  "openvpn-connect",
                              "content":  "OpenVPN Connect",
                              "description":  "OpenVPN Connect is an open-source VPN client that allows you to connect securely to a VPN server. It provides a secure and encrypted connection for protecting your online privacy.",
                              "link":  "https://openvpn.net/",
                              "winget":  "OpenVPNTechnologies.OpenVPNConnect",
                              "foss":  true
                          },
    "WPFInstallOVirtualBox":  {
                                  "category":  "Utilities",
                                  "choco":  "virtualbox",
                                  "content":  "Oracle VirtualBox",
                                  "description":  "Oracle VirtualBox is a powerful and free open-source virtualization tool for x86 and AMD64/Intel64 architectures.",
                                  "link":  "https://www.virtualbox.org/",
                                  "winget":  "Oracle.VirtualBox",
                                  "foss":  true
                              },
    "WPFInstallpolicyplus":  {
                                 "category":  "Utilities",
                                 "choco":  "na",
                                 "content":  "Policy Plus",
                                 "description":  "Local Group Policy Editor plus more, for all Windows editions.",
                                 "link":  "https://github.com/Fleex255/PolicyPlus",
                                 "winget":  "Fleex255.PolicyPlus",
                                 "foss":  true
                             },
    "WPFInstallprocessexplorer":  {
                                      "category":  "Microsoft Tools",
                                      "choco":  "na",
                                      "content":  "Process Explorer",
                                      "description":  "Process Explorer is a task manager and system monitor.",
                                      "link":  "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
                                      "winget":  "Microsoft.Sysinternals.ProcessExplorer",
                                      "foss":  false
                                  },
    "WPFInstallPaintdotnet":  {
                                  "category":  "Multimedia Tools",
                                  "choco":  "paint.net",
                                  "content":  "Paint.NET",
                                  "description":  "Paint.NET is a free image and photo editing software for Windows. It features an intuitive user interface and supports a wide range of powerful editing tools.",
                                  "link":  "https://www.getpaint.net/",
                                  "winget":  "dotPDN.PaintDotNet",
                                  "foss":  false
                              },
    "WPFInstallparsec":  {
                             "category":  "Utilities",
                             "choco":  "parsec",
                             "content":  "Parsec",
                             "description":  "Parsec is a low-latency, high-quality remote desktop sharing application for collaborating and gaming across devices.",
                             "link":  "https://parsec.app/",
                             "winget":  "Parsec.Parsec",
                             "foss":  false
                         },
    "WPFInstallpeazip":  {
                             "category":  "Utilities",
                             "choco":  "peazip",
                             "content":  "PeaZip",
                             "description":  "PeaZip is a free, open-source file archiver utility that supports multiple archive formats and provides encryption features.",
                             "link":  "https://peazip.github.io/",
                             "winget":  "Giorgiotani.Peazip",
                             "foss":  true
                         },
    "WPFInstallplex":  {
                           "category":  "Selfhosted Tools",
                           "choco":  "plexmediaserver",
                           "content":  "Plex Media Server",
                           "description":  "Plex Media Server is a media server software that allows you to organize and stream your media library. It supports various media formats and offers a wide range of features.",
                           "link":  "https://www.plex.tv/your-media/",
                           "winget":  "Plex.PlexMediaServer",
                           "foss":  false
                       },
    "WPFInstallplexdesktop":  {
                                  "category":  "Selfhosted Tools",
                                  "choco":  "plex",
                                  "content":  "Plex Desktop",
                                  "description":  "Plex Desktop for Windows is the front end for Plex Media Server.",
                                  "link":  "https://www.plex.tv",
                                  "winget":  "Plex.Plex",
                                  "foss":  false
                              },
    "WPFInstallposh":  {
                           "category":  "Development",
                           "choco":  "oh-my-posh",
                           "content":  "Oh My Posh (Prompt)",
                           "description":  "Oh My Posh is a cross-platform prompt theme engine for any shell.",
                           "link":  "https://ohmyposh.dev/",
                           "winget":  "JanDeDobbeleer.OhMyPosh",
                           "foss":  true
                       },
    "WPFInstallpowershell":  {
                                 "category":  "Microsoft Tools",
                                 "choco":  "powershell-core",
                                 "content":  "PowerShell",
                                 "description":  "PowerShell is a task automation framework and scripting language designed for system administrators, offering powerful command-line capabilities.",
                                 "link":  "https://github.com/PowerShell/PowerShell",
                                 "winget":  "Microsoft.PowerShell",
                                 "foss":  true
                             },
    "WPFInstallpowertoys":  {
                                "category":  "Microsoft Tools",
                                "choco":  "powertoys",
                                "content":  "PowerToys",
                                "description":  "PowerToys is a set of utilities for power users to enhance productivity, featuring tools like FancyZones, PowerRename, and more.",
                                "link":  "https://github.com/microsoft/PowerToys",
                                "winget":  "Microsoft.PowerToys",
                                "foss":  true
                            },
    "WPFInstallprismlauncher":  {
                                    "category":  "Games",
                                    "choco":  "prismlauncher",
                                    "content":  "Prism Launcher",
                                    "description":  "Prism Launcher is an open-source Minecraft launcher with the ability to manage multiple instances, accounts and mods.",
                                    "link":  "https://prismlauncher.org/",
                                    "winget":  "PrismLauncher.PrismLauncher",
                                    "foss":  true
                                },
    "WPFInstallprocesslasso":  {
                                   "category":  "Utilities",
                                   "choco":  "plasso",
                                   "content":  "Process Lasso",
                                   "description":  "Process Lasso is a system optimization and automation tool that improves system responsiveness and stability by adjusting process priorities and CPU affinities.",
                                   "link":  "https://bitsum.com/",
                                   "winget":  "BitSum.ProcessLasso",
                                   "foss":  false
                               },
    "WPFInstallprotonauth":  {
                                 "category":  "Utilities",
                                 "choco":  "protonauth",
                                 "content":  "Proton Authenticator",
                                 "description":  "2FA app from Proton to securely sync and backup 2FA codes.",
                                 "link":  "https://proton.me/authenticator",
                                 "winget":  "Proton.ProtonAuthenticator",
                                 "foss":  true
                             },
    "WPFInstallprotonmail":  {
                                 "category":  "Communications",
                                 "choco":  "protonmail",
                                 "content":  "Proton Mail",
                                 "description":  "Proton Mail is an end-to-end encrypted email service by Proton, protecting your privacy with zero-access encryption.",
                                 "link":  "https://proton.me/mail",
                                 "winget":  "Proton.ProtonMail",
                                 "foss":  true
                             },
    "WPFInstallprotondrive":  {
                                  "category":  "Utilities",
                                  "choco":  "protondrive",
                                  "content":  "Proton Drive",
                                  "description":  "Proton Drive is an end-to-end encrypted Swiss vault for your files that protects your data.",
                                  "link":  "https://proton.me/drive",
                                  "winget":  "Proton.ProtonDrive",
                                  "foss":  true
                              },
    "WPFInstallprotonpass":  {
                                 "category":  "Utilities",
                                 "choco":  "protonpass",
                                 "content":  "Proton Pass",
                                 "description":  "Proton Pass is a cloud-based password manager with end-to-end encryption and unique email aliases.",
                                 "link":  "https://proton.me/pass",
                                 "winget":  "Proton.ProtonPass",
                                 "foss":  true
                             },
    "WPFInstallprotonvpn":  {
                                "category":  "Pro Tools",
                                "choco":  "protonvpn",
                                "content":  "Proton VPN",
                                "description":  "Proton VPN is a no-logs VPN service that protects your privacy online with features like Secure Core and Tor over VPN.",
                                "link":  "https://protonvpn.com/",
                                "winget":  "Proton.ProtonVPN",
                                "foss":  true
                            },
    "WPFInstallprocessmonitor":  {
                                     "category":  "Microsoft Tools",
                                     "choco":  "procexp",
                                     "content":  "SysInternals Process Monitor",
                                     "description":  "SysInternals Process Monitor is an advanced monitoring tool that shows real-time file system, registry, and process/thread activity.",
                                     "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
                                     "winget":  "Microsoft.Sysinternals.ProcessMonitor",
                                     "foss":  false
                                 },
    "WPFInstallputty":  {
                            "category":  "Pro Tools",
                            "choco":  "putty",
                            "content":  "PuTTY",
                            "description":  "PuTTY is a free and open-source terminal emulator, serial console, and network file transfer application. It supports various network protocols such as SSH, Telnet, and SCP.",
                            "link":  "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
                            "winget":  "PuTTY.PuTTY",
                            "foss":  true
                        },
    "WPFInstallpython3":  {
                              "category":  "Development",
                              "choco":  "python",
                              "content":  "Python3",
                              "description":  "Python is a versatile programming language used for web development, data analysis, artificial intelligence, and more.",
                              "link":  "https://www.python.org/",
                              "winget":  "Python.Python.3.14",
                              "foss":  true
                          },
    "WPFInstallqbittorrent":  {
                                  "category":  "Utilities",
                                  "choco":  "qbittorrent",
                                  "content":  "qBittorrent",
                                  "description":  "qBittorrent is a free and open-source BitTorrent client that aims to provide a feature-rich and lightweight alternative to other torrent clients.",
                                  "link":  "https://www.qbittorrent.org/",
                                  "winget":  "qBittorrent.qBittorrent",
                                  "foss":  true
                              },
    "WPFInstallqtox":  {
                           "category":  "Communications",
                           "choco":  "qtox",
                           "content":  "QTox",
                           "description":  "QTox is a free and open-source messaging app that prioritizes user privacy and security in its design.",
                           "link":  "https://qtox.github.io/",
                           "winget":  "Tox.qTox",
                           "foss":  true
                       },
    "WPFInstallrevo":  {
                           "category":  "Utilities",
                           "choco":  "revo-uninstaller",
                           "content":  "Revo Uninstaller",
                           "description":  "Revo Uninstaller is an advanced uninstaller tool that helps you remove unwanted software and clean up your system.",
                           "link":  "https://www.revouninstaller.com/",
                           "winget":  "RevoUninstaller.RevoUninstaller",
                           "foss":  false
                       },
    "WPFInstallWiseProgramUninstaller":  {
                                             "category":  "Utilities",
                                             "choco":  "na",
                                             "content":  "Wise Program Uninstaller (WiseCleaner)",
                                             "description":  "Wise Program Uninstaller is the perfect solution for uninstalling Windows programs, allowing you to uninstall applications quickly and completely using its simple and user-friendly interface.",
                                             "link":  "https://www.wisecleaner.com/wise-program-uninstaller.html",
                                             "winget":  "WiseCleaner.WiseProgramUninstaller",
                                             "foss":  false
                                         },
    "WPFInstallrufus":  {
                            "category":  "Utilities",
                            "choco":  "rufus",
                            "content":  "Rufus Imager",
                            "description":  "Rufus is a utility that helps format and create bootable USB drives, such as USB keys or pen drives.",
                            "link":  "https://rufus.ie/",
                            "winget":  "Rufus.Rufus",
                            "foss":  true
                        },
    "WPFInstallrustdesk":  {
                               "category":  "Pro Tools",
                               "choco":  "rustdesk.portable",
                               "content":  "RustDesk",
                               "description":  "RustDesk is a free and open-source remote desktop application. It provides a secure way to connect to remote machines and access desktop environments.",
                               "link":  "https://rustdesk.com/",
                               "winget":  "RustDesk.RustDesk",
                               "foss":  true
                           },
    "WPFInstallrustlang":  {
                               "category":  "Development",
                               "choco":  "rust",
                               "content":  "Rust",
                               "description":  "Rust is a programming language designed for safety and performance, particularly focused on systems programming.",
                               "link":  "https://www.rust-lang.org/",
                               "winget":  "Rustlang.Rust.MSVC",
                               "foss":  true
                           },
    "WPFInstallsdio":  {
                           "category":  "Utilities",
                           "choco":  "sdio",
                           "content":  "Snappy Driver Installer Origin",
                           "description":  "Snappy Driver Installer Origin is a free and open-source driver updater with a vast driver database for Windows.",
                           "link":  "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
                           "winget":  "GlennDelahoy.SnappyDriverInstallerOrigin",
                           "foss":  true
                       },
    "WPFInstallsharex":  {
                             "category":  "Multimedia Tools",
                             "choco":  "sharex",
                             "content":  "ShareX (Screenshots)",
                             "description":  "ShareX is a free and open-source screen capture and file sharing tool. It supports various capture methods and offers advanced features for editing and sharing screenshots.",
                             "link":  "https://getsharex.com/",
                             "winget":  "ShareX.ShareX",
                             "foss":  true
                         },
    "WPFInstallnilesoftShell":  {
                                    "category":  "Utilities",
                                    "choco":  "nilesoft-shell",
                                    "content":  "Nilesoft Shell",
                                    "description":  "Shell is an expanded context menu tool that adds extra functionality and customization options to the Windows context menu.",
                                    "link":  "https://nilesoft.org/",
                                    "winget":  "Nilesoft.Shell",
                                    "foss":  false
                                },
    "WPFInstallsysteminformer":  {
                                     "category":  "Development",
                                     "choco":  "systeminformer",
                                     "content":  "System Informer",
                                     "description":  "A free, powerful, multi-purpose tool that helps you monitor system resources, debug software and detect malware.",
                                     "link":  "https://systeminformer.com/",
                                     "winget":  "WinsiderSS.SystemInformer",
                                     "foss":  true
                                 },
    "WPFInstallsignal":  {
                             "category":  "Communications",
                             "choco":  "signal",
                             "content":  "Signal",
                             "description":  "Signal is a privacy-focused messaging app that offers end-to-end encryption for secure and private communication.",
                             "link":  "https://signal.org/",
                             "winget":  "OpenWhisperSystems.Signal",
                             "foss":  true
                         },
    "WPFInstallsignalrgb":  {
                                "category":  "Utilities",
                                "choco":  "na",
                                "content":  "SignalRGB",
                                "description":  "SignalRGB lets you control and sync your favorite RGB devices with one free application.",
                                "link":  "https://www.signalrgb.com/",
                                "winget":  "WhirlwindFX.SignalRgb",
                                "foss":  false
                            },
    "WPFInstallsimplewall":  {
                                 "category":  "Pro Tools",
                                 "choco":  "simplewall",
                                 "content":  "Simplewall",
                                 "description":  "Simplewall is a free and open-source firewall application for Windows. It allows users to control and manage the inbound and outbound network traffic of applications.",
                                 "link":  "https://github.com/henrypp/simplewall",
                                 "winget":  "Henry++.simplewall",
                                 "foss":  true
                             },
    "WPFInstallslack":  {
                            "category":  "Communications",
                            "choco":  "slack",
                            "content":  "Slack",
                            "description":  "Slack is a collaboration hub that connects teams and facilitates communication through channels, messaging, and file sharing.",
                            "link":  "https://slack.com/",
                            "winget":  "SlackTechnologies.Slack",
                            "foss":  false
                        },
    "WPFInstallsteam":  {
                            "category":  "Games",
                            "choco":  "steam-client",
                            "content":  "Steam",
                            "description":  "Steam is a digital distribution platform for purchasing and playing video games, offering multiplayer gaming, video streaming, and more.",
                            "link":  "https://store.steampowered.com/about/",
                            "winget":  "Valve.Steam",
                            "foss":  false
                        },
    "WPFInstallsublimetext":  {
                                  "category":  "Development",
                                  "choco":  "sublimetext4",
                                  "content":  "Sublime Text",
                                  "description":  "Sublime Text is a sophisticated text editor for code, markup, and prose.",
                                  "link":  "https://www.sublimetext.com/",
                                  "winget":  "SublimeHQ.SublimeText.4",
                                  "foss":  false
                              },
    "WPFInstallsunshine":  {
                               "category":  "Selfhosted Tools",
                               "choco":  "sunshine",
                               "content":  "Sunshine/GameStream Server",
                               "description":  "Sunshine is a GameStream server that allows you to remotely play PC games on Android devices, offering low-latency streaming.",
                               "link":  "https://github.com/LizardByte/Sunshine",
                               "winget":  "LizardByte.Sunshine",
                               "foss":  true
                           },
    "WPFInstalltcpview":  {
                              "category":  "Microsoft Tools",
                              "choco":  "tcpview",
                              "content":  "SysInternals TCPView",
                              "description":  "SysInternals TCPView is a network monitoring tool that displays a detailed list of all TCP and UDP endpoints on your system.",
                              "link":  "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
                              "winget":  "Microsoft.Sysinternals.TCPView",
                              "foss":  false
                          },
    "WPFInstallteams":  {
                            "category":  "Communications",
                            "choco":  "microsoft-teams",
                            "content":  "Teams",
                            "description":  "Microsoft Teams is a collaboration platform that integrates with Office 365 and offers chat, video conferencing, file sharing, and more.",
                            "link":  "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
                            "winget":  "Microsoft.Teams",
                            "foss":  false
                        },
    "WPFInstallteamviewer":  {
                                 "category":  "Utilities",
                                 "choco":  "teamviewer9",
                                 "content":  "TeamViewer",
                                 "description":  "TeamViewer is a popular remote access and support software that allows you to connect to and control remote devices.",
                                 "link":  "https://www.teamviewer.com/",
                                 "winget":  "TeamViewer.TeamViewer",
                                 "foss":  false
                             },
    "WPFInstallteamspeak3":  {
                                 "category":  "Communications",
                                 "choco":  "teamspeak",
                                 "content":  "TeamSpeak 3",
                                 "description":  "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your team mates cross-platform with military-grade security, lag-free performance \u0026 unparalleled reliability and uptime.",
                                 "link":  "https://www.teamspeak.com/",
                                 "winget":  "TeamSpeakSystems.TeamSpeakClient",
                                 "foss":  false
                             },
    "WPFInstalltelegram":  {
                               "category":  "Communications",
                               "choco":  "telegram",
                               "content":  "Telegram",
                               "description":  "Telegram is a cloud-based instant messaging app known for its security features, speed, and simplicity.",
                               "link":  "https://telegram.org/",
                               "winget":  "Telegram.TelegramDesktop",
                               "foss":  true
                           },
    "WPFInstallterminal":  {
                               "category":  "Microsoft Tools",
                               "choco":  "microsoft-windows-terminal",
                               "content":  "Windows Terminal",
                               "description":  "Windows Terminal is a modern, fast, and efficient terminal application for command-line users, supporting multiple tabs, panes, and more.",
                               "link":  "https://aka.ms/terminal",
                               "winget":  "Microsoft.WindowsTerminal",
                               "foss":  true
                           },
    "WPFInstallthunderbird":  {
                                  "category":  "Communications",
                                  "choco":  "thunderbird",
                                  "content":  "Thunderbird",
                                  "description":  "Mozilla Thunderbird is a free and open-source email client, news client, and chat client with advanced features.",
                                  "link":  "https://www.thunderbird.net/",
                                  "winget":  "Mozilla.Thunderbird",
                                  "foss":  true
                              },
    "WPFInstallbetterbird":  {
                                 "category":  "Communications",
                                 "choco":  "betterbird",
                                 "content":  "Betterbird",
                                 "description":  "Betterbird is a fork of Mozilla Thunderbird with additional features and bugfixes.",
                                 "link":  "https://www.betterbird.eu/",
                                 "winget":  "Betterbird.Betterbird",
                                 "foss":  true
                             },
    "WPFInstalltor":  {
                          "category":  "Browsers",
                          "choco":  "tor-browser",
                          "content":  "Tor Browser",
                          "description":  "Tor Browser is designed for anonymous web browsing, utilizing the Tor network to protect user privacy and security.",
                          "link":  "https://www.torproject.org/",
                          "winget":  "TorProject.TorBrowser",
                          "foss":  true
                      },
    "WPFInstalltotalcommander":  {
                                     "category":  "Utilities",
                                     "choco":  "TotalCommander",
                                     "content":  "Total Commander",
                                     "description":  "Total Commander is a file manager for Windows that provides a powerful and intuitive interface for file management.",
                                     "link":  "https://www.ghisler.com/",
                                     "winget":  "Ghisler.TotalCommander",
                                     "foss":  false
                                 },
    "WPFInstalltreesize":  {
                               "category":  "Utilities",
                               "choco":  "treesizefree",
                               "content":  "TreeSize Free",
                               "description":  "TreeSize Free is a disk space manager that helps you analyze and visualize the space usage on your drives.",
                               "link":  "https://www.jam-software.com/treesize_free/",
                               "winget":  "JAMSoftware.TreeSize.Free",
                               "foss":  false
                           },
    "WPFInstallttaskbar":  {
                               "category":  "Utilities",
                               "choco":  "translucenttb",
                               "content":  "TranslucentTB",
                               "description":  "TranslucentTB is a tool that allows you to customize the transparency of the Windows Taskbar.",
                               "link":  "https://github.com/TranslucentTB/TranslucentTB",
                               "winget":  "CharlesMilette.TranslucentTB",
                               "foss":  true
                           },
    "WPFInstallubisoft":  {
                              "category":  "Games",
                              "choco":  "ubisoft-connect",
                              "content":  "Ubisoft Connect",
                              "description":  "Ubisoft Connect is Ubisoft\u0027s digital distribution and online gaming service, providing access to Ubisoft\u0027s games and services.",
                              "link":  "https://ubisoftconnect.com/",
                              "winget":  "Ubisoft.Connect",
                              "foss":  false
                          },
    "WPFInstallungoogled":  {
                                "category":  "Browsers",
                                "choco":  "ungoogled-chromium",
                                "content":  "Ungoogled",
                                "description":  "Ungoogled Chromium is a version of Chromium without Google\u0027s integration for enhanced privacy and control.",
                                "link":  "https://github.com/Eloston/ungoogled-chromium",
                                "winget":  "eloston.ungoogled-chromium",
                                "foss":  true
                            },
    "WPFInstallunity":  {
                            "category":  "Development",
                            "choco":  "unityhub",
                            "content":  "Unity Game Engine",
                            "description":  "Unity is a powerful game development platform for creating 2D, 3D, augmented reality, and virtual reality games.",
                            "link":  "https://unity.com/",
                            "winget":  "Unity.UnityHub",
                            "foss":  false
                        },
    "WPFInstallvc2015_32":  {
                                "category":  "Microsoft Tools",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 32-bit",
                                "description":  "Visual C++ 2015-2022 32-bit redistributable package installs runtime components of Visual C++ libraries required to run 32-bit applications.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x86",
                                "foss":  false
                            },
    "WPFInstallvc2015_64":  {
                                "category":  "Microsoft Tools",
                                "choco":  "na",
                                "content":  "Visual C++ 2015-2022 64-bit",
                                "description":  "Visual C++ 2015-2022 64-bit redistributable package installs runtime components of Visual C++ libraries required to run 64-bit applications.",
                                "link":  "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
                                "winget":  "Microsoft.VCRedist.2015+.x64",
                                "foss":  false
                            },
    "WPFInstallventoy":  {
                             "category":  "Pro Tools",
                             "choco":  "ventoy",
                             "content":  "Ventoy",
                             "description":  "Ventoy is an open-source tool for creating bootable USB drives. It supports multiple ISO files on a single USB drive, making it a versatile solution for installing operating systems.",
                             "link":  "https://www.ventoy.net/",
                             "winget":  "Ventoy.Ventoy",
                             "foss":  true
                         },
    "WPFInstallvesktop":  {
                              "category":  "Communications",
                              "choco":  "na",
                              "content":  "Vesktop",
                              "description":  "A cross platform electron-based desktop app aiming to give you a snappier Discord experience with Vencord pre-installed.",
                              "link":  "https://github.com/Vencord/Vesktop",
                              "winget":  "Vencord.Vesktop",
                              "foss":  true
                          },
    "WPFInstallviber":  {
                            "category":  "Communications",
                            "choco":  "viber",
                            "content":  "Viber",
                            "description":  "Viber is a free messaging and calling app with features like group chats, video calls, and more.",
                            "link":  "https://www.viber.com/",
                            "winget":  "Rakuten.Viber",
                            "foss":  false
                        },
    "WPFInstallvisualstudio2022":  {
                                       "category":  "Development",
                                       "choco":  "visualstudio2022community",
                                       "content":  "Visual Studio 2022",
                                       "description":  "Visual Studio 2022 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.2022.Community",
                                       "foss":  false
                                   },
    "WPFInstallvisualstudio2026":  {
                                       "category":  "Development",
                                       "choco":  "visualstudio2026community",
                                       "content":  "Visual Studio 2026",
                                       "description":  "Visual Studio 2026 is an integrated development environment (IDE) for building, debugging, and deploying applications.",
                                       "link":  "https://visualstudio.microsoft.com/",
                                       "winget":  "Microsoft.VisualStudio.Community",
                                       "foss":  false
                                   },
    "WPFInstallvivaldi":  {
                              "category":  "Browsers",
                              "choco":  "vivaldi",
                              "content":  "Vivaldi",
                              "description":  "Vivaldi is a highly customizable web browser with a focus on user personalization and productivity features.",
                              "link":  "https://vivaldi.com/",
                              "winget":  "Vivaldi.Vivaldi",
                              "foss":  false
                          },
    "WPFInstallvlc":  {
                          "category":  "Multimedia Tools",
                          "choco":  "vlc",
                          "content":  "VLC (Video Player)",
                          "description":  "VLC Media Player is a free and open-source multimedia player that supports a wide range of audio and video formats. It is known for its versatility and cross-platform compatibility.",
                          "link":  "https://www.videolan.org/vlc/",
                          "winget":  "VideoLAN.VLC",
                          "foss":  true
                      },
    "WPFInstallvrdesktopstreamer":  {
                                        "category":  "Games",
                                        "choco":  "na",
                                        "content":  "Virtual Desktop Streamer",
                                        "description":  "Virtual Desktop Streamer is a tool that allows you to stream your desktop screen to VR devices.",
                                        "link":  "https://www.vrdesktop.net/",
                                        "winget":  "VirtualDesktop.Streamer",
                                        "foss":  false
                                    },
    "WPFInstallvscode":  {
                             "category":  "Development",
                             "choco":  "vscode",
                             "content":  "VS Code",
                             "description":  "Visual Studio Code is a free, open-source code editor with support for multiple programming languages.",
                             "link":  "https://code.visualstudio.com/",
                             "winget":  "Microsoft.VisualStudioCode",
                             "foss":  true
                         },
    "WPFInstallvscodium":  {
                               "category":  "Development",
                               "choco":  "vscodium",
                               "content":  "VS Codium",
                               "description":  "VSCodium is a community-driven, freely-licensed binary distribution of Microsoft\u0027s VS Code.",
                               "link":  "https://vscodium.com/",
                               "winget":  "VSCodium.VSCodium",
                               "foss":  true
                           },
    "WPFInstallwaterfox":  {
                               "category":  "Browsers",
                               "choco":  "waterfox",
                               "content":  "Waterfox",
                               "description":  "Waterfox is a fast, privacy-focused web browser based on Firefox, designed to preserve user choice and privacy.",
                               "link":  "https://www.waterfox.net/",
                               "winget":  "Waterfox.Waterfox",
                               "foss":  true
                           },
    "WPFInstallwingetui":  {
                               "category":  "Utilities",
                               "choco":  "wingetui",
                               "content":  "UniGetUI",
                               "description":  "UniGetUI is a GUI for WinGet, Chocolatey, and other Windows CLI package managers.",
                               "link":  "https://devolutions.net/unigetui/",
                               "winget":  "Devolutions.UniGetUI",
                               "foss":  true
                           },
    "WPFInstallwinrar":  {
                             "category":  "Utilities",
                             "choco":  "winrar",
                             "content":  "WinRAR",
                             "description":  "WinRAR is a powerful archive manager that allows you to create, manage, and extract compressed files.",
                             "link":  "https://www.win-rar.com/",
                             "winget":  "RARLab.WinRAR",
                             "foss":  false
                         },
    "WPFInstallwinscp":  {
                             "category":  "Pro Tools",
                             "choco":  "winscp",
                             "content":  "WinSCP",
                             "description":  "WinSCP is a popular open-source SFTP, FTP, and SCP client for Windows. It allows secure file transfers between a local and a remote computer.",
                             "link":  "https://winscp.net/",
                             "winget":  "WinSCP.WinSCP",
                             "foss":  true
                         },
    "WPFInstallwireguard":  {
                                "category":  "Pro Tools",
                                "choco":  "wireguard",
                                "content":  "WireGuard",
                                "description":  "WireGuard is a fast and modern VPN (Virtual Private Network) protocol. It aims to be simpler and more efficient than other VPN protocols, providing secure and reliable connections.",
                                "link":  "https://www.wireguard.com/",
                                "winget":  "WireGuard.WireGuard",
                                "foss":  true
                            },
    "WPFInstallwireshark":  {
                                "category":  "Pro Tools",
                                "choco":  "wireshark",
                                "content":  "Wireshark",
                                "description":  "Wireshark is a widely-used open-source network protocol analyzer. It allows users to capture and analyze network traffic in real-time, providing detailed insights into network activities.",
                                "link":  "https://www.wireshark.org/",
                                "winget":  "WiresharkFoundation.Wireshark",
                                "foss":  true
                            },
    "WPFInstallwiztree":  {
                              "category":  "Utilities",
                              "choco":  "wiztree",
                              "content":  "WizTree",
                              "description":  "WizTree is a fast disk space analyzer that helps you quickly find the files and folders consuming the most space on your hard drive.",
                              "link":  "https://wiztreefree.com/",
                              "winget":  "AntibodySoftware.WizTree",
                              "foss":  false
                          },
    "WPFInstallxeheditor":  {
                                "category":  "Utilities",
                                "choco":  "HxD",
                                "content":  "HxD Hex Editor",
                                "description":  "HxD is a free hex editor that allows you to edit, view, search, and analyze binary files.",
                                "link":  "https://mh-nexus.de/en/hxd/",
                                "winget":  "MHNexus.HxD",
                                "foss":  false
                            },
    "WPFInstallyarn":  {
                           "category":  "Development",
                           "choco":  "yarn",
                           "content":  "Yarn",
                           "description":  "Yarn is a fast, reliable, and secure dependency management tool for JavaScript projects.",
                           "link":  "https://yarnpkg.com/",
                           "winget":  "Yarn.Yarn",
                           "foss":  true
                       },
    "WPFInstallzoom":  {
                           "category":  "Communications",
                           "choco":  "zoom",
                           "content":  "Zoom",
                           "description":  "Zoom is a popular video conferencing and web conferencing service for online meetings, webinars, and collaborative projects.",
                           "link":  "https://zoom.us/",
                           "winget":  "Zoom.Zoom",
                           "foss":  false
                       },
    "WPFInstalluv":  {
                         "category":  "Development",
                         "choco":  "uv",
                         "content":  "uv",
                         "description":  "uv is a fast Python package and project manager written in Rust.",
                         "link":  "https://docs.astral.sh/uv/getting-started/installation/",
                         "winget":  "astral-sh.uv",
                         "foss":  true
                     },
    "WPFInstalltightvnc":  {
                               "category":  "Utilities",
                               "choco":  "TightVNC",
                               "content":  "TightVNC",
                               "description":  "TightVNC is a free and open-source remote desktop software that lets you access and control a computer over the network. With its intuitive interface, you can interact with the remote screen as if you were sitting in front of it. You can open files, launch applications, and perform other actions on the remote desktop almost as if you were physically there.",
                               "link":  "https://www.tightvnc.com/",
                               "winget":  "GlavSoft.TightVNC",
                               "foss":  true
                           },
    "WPFInstallglazewm":  {
                              "category":  "Utilities",
                              "choco":  "glazewm",
                              "content":  "GlazeWM",
                              "description":  "GlazeWM is a tiling window manager for Windows inspired by i3 and Polybar.",
                              "link":  "https://github.com/glzr-io/glazewm",
                              "winget":  "glzr-io.glazewm",
                              "foss":  true
                          },
    "WPFInstallOverwolf":  {
                               "category":  "Games",
                               "choco":  "overwolf",
                               "content":  "Overwolf",
                               "description":  "Popular platform for game overlays and companion apps (mod managers, trackers, etc.), widely used by gamers.",
                               "link":  "https://www.overwolf.com/app/overwolf-curseforge",
                               "winget":  "Overwolf.CurseForge",
                               "foss":  false
                           },
    "WPFInstallOFGB":  {
                           "category":  "Utilities",
                           "choco":  "ofgb",
                           "content":  "OFGB (Oh Frick Go Back)",
                           "description":  "GUI Tool to remove ads from various places around Windows 11",
                           "link":  "https://github.com/xM4ddy/OFGB",
                           "winget":  "xM4ddy.OFGB",
                           "foss":  true
                       },
    "WPFInstallZenBrowser":  {
                                 "category":  "Browsers",
                                 "choco":  "zen-browser",
                                 "content":  "Zen Browser",
                                 "description":  "The modern, privacy-focused, performance-driven browser built on Firefox.",
                                 "link":  "https://zen-browser.app/",
                                 "winget":  "Zen-Team.Zen-Browser",
                                 "foss":  true
                             },
    "WPFInstallZed":  {
                          "category":  "Development",
                          "choco":  "zed",
                          "content":  "Zed",
                          "description":  "Zed is a modern, high-performance code editor designed from the ground up for speed and collaboration.",
                          "link":  "https://zed.dev/",
                          "winget":  "ZedIndustries.Zed",
                          "foss":  true
                      },
    "WPFInstallRuby":  {
                           "category":  "Development",
                           "choco":  "ruby",
                           "winget":  "RubyInstallerTeam.Ruby.4.0",
                           "description":  "A Ruby language execution environment with a MSYS2 installation.",
                           "content":  "Ruby",
                           "link":  "https://rubyinstaller.org/",
                           "foss":  true
                       },
    "WPFInstallLua":  {
                          "category":  "Development",
                          "choco":  "lua",
                          "winget":  "rjpcomputing.luaforwindows",
                          "description":  "A \u0027batteries included environment\u0027 for the Lua scripting language on Windows.",
                          "content":  "Lua",
                          "link":  "https://github.com/rjpcomputing/luaforwindows",
                          "foss":  true
                      }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
    "WPFInstall":  {
                       "Content":  "Installa/Aggiorna applicazioni",
                       "Category":  "____Azioni",
                       "Type":  "Button",
                       "Order":  "1",
                       "Description":  "Installa o aggiorna le applicazioni selezionate"
                   },
    "WPFUninstall":  {
                         "Content":  "Disinstalla applicazioni",
                         "Category":  "____Azioni",
                         "Type":  "Button",
                         "Order":  "2",
                         "Description":  "Disinstalla le applicazioni selezionate"
                     },
    "WPFInstallUpgrade":  {
                              "Content":  "Aggiorna tutte le applicazioni",
                              "Category":  "____Azioni",
                              "Type":  "Button",
                              "Order":  "3",
                              "Description":  "Aggiorna tutte le applicazioni all\u0027ultima versione"
                          },
    "WingetRadioButton":  {
                              "Content":  "WinGet",
                              "Category":  "__Gestore pacchetti",
                              "Type":  "RadioButton",
                              "GroupName":  "PackageManagerGroup",
                              "Checked":  true,
                              "Order":  "1",
                              "Description":  "Usa WinGet per la gestione dei pacchetti"
                          },
    "ChocoRadioButton":  {
                             "Content":  "Chocolatey",
                             "Category":  "__Gestore pacchetti",
                             "Type":  "RadioButton",
                             "GroupName":  "PackageManagerGroup",
                             "Checked":  false,
                             "Order":  "2",
                             "Description":  "Usa Chocolatey per la gestione dei pacchetti"
                         },
    "WPFCollapseAllCategories":  {
                                     "Content":  "Comprimi tutte le categorie",
                                     "Category":  "__Selezione",
                                     "Type":  "Button",
                                     "Order":  "1",
                                     "Description":  "Comprimi tutte le categorie di applicazioni"
                                 },
    "WPFExpandAllCategories":  {
                                   "Content":  "Espandi tutte le categorie",
                                   "Category":  "__Selezione",
                                   "Type":  "Button",
                                   "Order":  "2",
                                   "Description":  "Espandi tutte le categorie di applicazioni"
                               },
    "WPFClearInstallSelection":  {
                                     "Content":  "Azzera selezione",
                                     "Category":  "__Selezione",
                                     "Type":  "Button",
                                     "Order":  "3",
                                     "Description":  "Azzera la selezione delle applicazioni"
                                 },
    "WPFGetInstalled":  {
                            "Content":  "Mostra app installate",
                            "Category":  "__Selezione",
                            "Type":  "Button",
                            "Order":  "4",
                            "Description":  "Mostra le applicazioni installate"
                        },
    "WPFselectedAppsButton":  {
                                  "Content":  "App selezionate: 0",
                                  "Category":  "__Selezione",
                                  "Type":  "Button",
                                  "Order":  "5",
                                  "Description":  "Mostra le applicazioni selezionate"
                              },
    "WPFToggleFOSSHighlight":  {
                                   "Content":  "Evidenzia FOSS",
                                   "Category":  "__Selezione",
                                   "Type":  "Toggle",
                                   "Checked":  true,
                                   "Order":  "6",
                                   "Description":  "Attiva/disattiva l\u0027evidenziazione verde per le applicazioni FOSS"
                               }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
    "Google":  {
                   "Primary":  "8.8.8.8",
                   "Secondary":  "8.8.4.4",
                   "Primary6":  "2001:4860:4860::8888",
                   "Secondary6":  "2001:4860:4860::8844"
               },
    "Cloudflare":  {
                       "Primary":  "1.1.1.1",
                       "Secondary":  "1.0.0.1",
                       "Primary6":  "2606:4700:4700::1111",
                       "Secondary6":  "2606:4700:4700::1001"
                   },
    "Cloudflare_Malware":  {
                               "Primary":  "1.1.1.2",
                               "Secondary":  "1.0.0.2",
                               "Primary6":  "2606:4700:4700::1112",
                               "Secondary6":  "2606:4700:4700::1002"
                           },
    "Cloudflare_Malware_Adult":  {
                                     "Primary":  "1.1.1.3",
                                     "Secondary":  "1.0.0.3",
                                     "Primary6":  "2606:4700:4700::1113",
                                     "Secondary6":  "2606:4700:4700::1003"
                                 },
    "Open_DNS":  {
                     "Primary":  "208.67.222.222",
                     "Secondary":  "208.67.220.220",
                     "Primary6":  "2620:119:35::35",
                     "Secondary6":  "2620:119:53::53"
                 },
    "Quad9":  {
                  "Primary":  "9.9.9.9",
                  "Secondary":  "149.112.112.112",
                  "Primary6":  "2620:fe::fe",
                  "Secondary6":  "2620:fe::9"
              },
    "AdGuard_Ads_Trackers":  {
                                 "Primary":  "94.140.14.14",
                                 "Secondary":  "94.140.15.15",
                                 "Primary6":  "2a10:50c0::ad1:ff",
                                 "Secondary6":  "2a10:50c0::ad2:ff"
                             },
    "AdGuard_Ads_Trackers_Malware_Adult":  {
                                               "Primary":  "94.140.14.15",
                                               "Secondary":  "94.140.15.16",
                                               "Primary6":  "2a10:50c0::bad1:ff",
                                               "Secondary6":  "2a10:50c0::bad2:ff"
                                           }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
    "WPFFeaturesdotnet":  {
                              "Content":  ".NET Framework (versioni 2, 3, 4) - Attiva",
                              "Description":  ".NET e .NET Framework sono una piattaforma di sviluppo, fatta di strumenti, linguaggi e librerie, che serve a molte applicazioni.",
                              "category":  "Funzionalit\u00e0 di Windows",
                              "panel":  "1",
                              "feature":  [
                                              "NetFx4-AdvSrvs",
                                              "NetFx3"
                                          ],
                              "InvokeScript":  [

                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFixesNTPPool":  {
                            "Content":  "Server NTP - Usa pool.ntp.org",
                            "Description":  "Sostituisce il server NTP predefinito di Windows (time.windows.com) con pool.ntp.org, per una sincronizzazione dell\u0027ora pi\u00f9 precisa e affidabile.",
                            "category":  "Riparazioni",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNTPPool",
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFFeatureshyperv":  {
                              "Content":  "Hyper-V - Attiva",
                              "Description":  "Hyper-V \u00e8 la piattaforma di virtualizzazione di Microsoft per creare e gestire macchine virtuali.",
                              "category":  "Funzionalit\u00e0 di Windows",
                              "panel":  "1",
                              "feature":  [
                                              "Microsoft-Hyper-V-All"
                                          ],
                              "InvokeScript":  [
                                                   "bcdedit /set hypervisorschedulertype classic"
                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFeatureslegacymedia":  {
                                   "Content":  "Componenti multimediali legacy (WMP, DirectPlay) - Attiva",
                                   "Description":  "Attiva i componenti richiesti dai programmi delle versioni precedenti di Windows.",
                                   "category":  "Funzionalit\u00e0 di Windows",
                                   "panel":  "1",
                                   "feature":  [
                                                   "WindowsMediaPlayer",
                                                   "MediaPlayback",
                                                   "DirectPlay",
                                                   "LegacyComponents"
                                               ],
                                   "InvokeScript":  [

                                                    ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFFeaturewsl":  {
                          "Content":  "Sottosistema Windows per Linux (WSL) - Attiva",
                          "Description":  "Il Sottosistema Windows per Linux permette di eseguire programmi Linux direttamente in Windows, senza macchina virtuale n\u00e9 doppio avvio.",
                          "category":  "Funzionalit\u00e0 di Windows",
                          "panel":  "1",
                          "feature":  [
                                          "VirtualMachinePlatform",
                                          "Microsoft-Windows-Subsystem-Linux"
                                      ],
                          "InvokeScript":  [

                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFFeaturenfs":  {
                          "Content":  "Network File System (NFS) - Attiva",
                          "Description":  "Network File System (NFS) \u00e8 un sistema per accedere ai file condivisi in rete.",
                          "category":  "Funzionalit\u00e0 di Windows",
                          "panel":  "1",
                          "feature":  [
                                          "ServicesForNFS-ClientOnly",
                                          "ClientForNFS-Infrastructure",
                                          "NFS-Administration"
                                      ],
                          "InvokeScript":  [
                                               "nfsadmin client stop",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousUID\u0027 -Type DWord -Value 0",
                                               "Set-ItemProperty -Path \u0027HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default\u0027 -Name \u0027AnonymousGID\u0027 -Type DWord -Value 0",
                                               "nfsadmin client start",
                                               "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFFeatureRegBackup":  {
                                "Content":  "Backup del registro (ogni giorno alle 00:30) - Attiva",
                                "Description":  "Attiva il backup giornaliero del registro, disattivato da Microsoft a partire da Windows 10 1803.",
                                "category":  "Funzionalit\u00e0 di Windows",
                                "panel":  "1",
                                "feature":  [

                                            ],
                                "InvokeScript":  [
                                                     "\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027EnablePeriodicBackup\u0027 -Type DWord -Value 1 -Force\r\n      New-ItemProperty -Path \u0027HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager\u0027 -Name \u0027BackupCount\u0027 -Type DWord -Value 2 -Force\r\n      $action = New-ScheduledTaskAction -Execute \u0027schtasks\u0027 -Argument \u0027/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"\u0027\r\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\r\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName \u0027AutoRegBackup\u0027 -Description \u0027Create System Registry Backups\u0027 -User \u0027System\u0027\r\n      "
                                                 ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFFeatureEnableLegacyRecovery":  {
                                           "Content":  "Ripristino classico con F8 all\u0027avvio - Attiva",
                                           "Description":  "Attiva la schermata Opzioni di avvio avanzate, che permette di avviare Windows nelle modalit\u00e0 di risoluzione dei problemi.",
                                           "category":  "Funzionalit\u00e0 di Windows",
                                           "panel":  "1",
                                           "feature":  [

                                                       ],
                                           "InvokeScript":  [
                                                                "bcdedit /set bootmenupolicy legacy"
                                                            ],
                                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                       },
    "WPFFeatureDisableLegacyRecovery":  {
                                            "Content":  "Ripristino classico con F8 all\u0027avvio - Disattiva",
                                            "Description":  "Disattiva la schermata Opzioni di avvio avanzate, che permette di avviare Windows nelle modalit\u00e0 di risoluzione dei problemi.",
                                            "category":  "Funzionalit\u00e0 di Windows",
                                            "panel":  "1",
                                            "feature":  [

                                                        ],
                                            "InvokeScript":  [
                                                                 "bcdedit /set bootmenupolicy standard"
                                                             ],
                                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                        },
    "WPFFeaturesSandbox":  {
                               "Content":  "Sandbox di Windows - Attiva",
                               "Description":  "Sandbox di Windows \u00e8 una macchina virtuale leggera che offre un desktop temporaneo per eseguire applicazioni in modo isolato e sicuro.",
                               "category":  "Funzionalit\u00e0 di Windows",
                               "panel":  "1",
                               "feature":  [
                                               "Containers-DisposableClientVM"
                                           ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFFeatureInstall":  {
                              "Content":  "Attiva le funzionalit\u00e0 selezionate",
                              "category":  "Funzionalit\u00e0 di Windows",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFFeatureInstall",
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFPanelAutologin":  {
                              "Content":  "Accesso automatico (AutoLogon) - Esegui",
                              "category":  "Riparazioni",
                              "panel":  "1",
                              "Type":  "Button",
                              "ButtonWidth":  "300",
                              "function":  "Invoke-WPFPanelAutologin",
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFFixesUpdate":  {
                           "Content":  "Windows Update - Reimposta",
                           "category":  "Riparazioni",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesUpdate",
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFFixesNetwork":  {
                            "Content":  "Rete - Reimposta",
                            "category":  "Riparazioni",
                            "panel":  "1",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "function":  "Invoke-WPFFixesNetwork",
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelDISM":  {
                         "Content":  "Controllo e riparazione del sistema - Esegui",
                         "category":  "Riparazioni",
                         "panel":  "1",
                         "Type":  "Button",
                         "ButtonWidth":  "300",
                         "function":  "Invoke-WPFSystemRepair",
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFFixesWinget":  {
                           "Content":  "WinGet - Reinstalla",
                           "category":  "Riparazioni",
                           "panel":  "1",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "function":  "Invoke-WPFFixesWinget",
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelControl":  {
                            "Content":  "Pannello di controllo",
                            "category":  "Pannelli classici di Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "control"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelComputer":  {
                             "Content":  "Gestione computer",
                             "category":  "Pannelli classici di Windows",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "compmgmt.msc"
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFPanelNetwork":  {
                            "Content":  "Connessioni di rete",
                            "category":  "Pannelli classici di Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "ncpa.cpl"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelPower":  {
                          "Content":  "Opzioni risparmio energia",
                          "category":  "Pannelli classici di Windows",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "powercfg.cpl"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFPanelPrinter":  {
                            "Content":  "Dispositivi e stampanti",
                            "category":  "Pannelli classici di Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "Start-Process \u0027shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}\u0027"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelRegion":  {
                           "Content":  "Area geografica",
                           "category":  "Pannelli classici di Windows",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "intl.cpl"
                                            ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelRestore":  {
                            "Content":  "Ripristino configurazione di sistema",
                            "category":  "Pannelli classici di Windows",
                            "panel":  "2",
                            "Type":  "Button",
                            "ButtonWidth":  "300",
                            "InvokeScript":  [
                                                 "rstrui.exe"
                                             ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFPanelSound":  {
                          "Content":  "Audio",
                          "category":  "Pannelli classici di Windows",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "InvokeScript":  [
                                               "mmsys.cpl"
                                           ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFPanelSystem":  {
                           "Content":  "Propriet\u00e0 del sistema",
                           "category":  "Pannelli classici di Windows",
                           "panel":  "2",
                           "Type":  "Button",
                           "ButtonWidth":  "300",
                           "InvokeScript":  [
                                                "sysdm.cpl"
                                            ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFPanelTimedate":  {
                             "Content":  "Data e ora",
                             "category":  "Pannelli classici di Windows",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "InvokeScript":  [
                                                  "timedate.cpl"
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFWinUtilSSHServer":  {
                                "Content":  "Server OpenSSH - Attiva",
                                "category":  "z__Accesso remoto",
                                "panel":  "2",
                                "Type":  "Button",
                                "ButtonWidth":  "300",
                                "function":  "Invoke-WPFSSHServer",
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
    "Standard":  [
                     "WPFTweaksActivity",
                     "WPFTweaksConsumerFeatures",
                     "WPFTweaksDisableExplorerAutoDiscovery",
                     "WPFTweaksWPBT",
                     "WPFTweaksDVR",
                     "WPFTweaksDeBloat",
                     "WPFTweaksLocation",
                     "WPFTweaksServices",
                     "WPFTweaksTelemetry",
                     "WPFTweaksDiskCleanup",
                     "WPFTweaksDeleteTempFiles",
                     "WPFTweaksEndTaskOnTaskbar",
                     "WPFTweaksRestorePoint",
                     "WPFTweaksPowershell7Tele"
                 ],
    "Minimal":  [
                    "WPFTweaksConsumerFeatures",
                    "WPFTweaksDeBloat",
                    "WPFTweaksWPBT",
                    "WPFTweaksServices",
                    "WPFTweaksTelemetry"
                ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
    "shared":  {
                   "AppEntryWidth":  "200",
                   "AppEntryFontSize":  "11",
                   "AppEntryMargin":  "1,0,1,0",
                   "AppEntryBorderThickness":  "0",
                   "CustomDialogFontSize":  "12",
                   "CustomDialogFontSizeHeader":  "14",
                   "CustomDialogLogoSize":  "25",
                   "CustomDialogWidth":  "400",
                   "CustomDialogHeight":  "200",
                   "FontSize":  "12",
                   "FontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "HeaderFontSize":  "16",
                   "HeaderFontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "CheckBoxBulletDecoratorSize":  "14",
                   "CheckBoxMargin":  "15,0,0,2",
                   "TabContentMargin":  "5",
                   "TabButtonFontSize":  "14",
                   "TabButtonWidth":  "110",
                   "TabButtonHeight":  "26",
                   "TabRowHeightInPixels":  "50",
                   "ToolTipWidth":  "300",
                   "IconFontSize":  "14",
                   "IconButtonSize":  "35",
                   "SettingsIconFontSize":  "18",
                   "CloseIconFontSize":  "18",
                   "ButtonFontSize":  "12",
                   "ButtonFontFamily":  "Inter, Segoe UI Variable, Segoe UI",
                   "ButtonWidth":  "200",
                   "ButtonHeight":  "25",
                   "ConfigTabButtonFontSize":  "14",
                   "ConfigUpdateButtonFontSize":  "14",
                   "SearchBarWidth":  "200",
                   "SearchBarHeight":  "26",
                   "SearchBarTextBoxFontSize":  "12",
                   "SearchBarClearButtonFontSize":  "14",
                   "ButtonBorderThickness":  "1",
                   "ButtonMargin":  "1",
                   "ButtonCornerRadius":  "8"
               },
    "Light":  {
                  "AppInstallUnselectedColor":  "#F1F4F8",
                  "AppInstallHighlightedColor":  "#E2E8F0",
                  "AppInstallSelectedColor":  "#DCFCE7",
                  "AppInstallOverlayBackgroundColor":  "#E6FFFFFF",
                  "ComboBoxForegroundColor":  "#0F172A",
                  "ComboBoxBackgroundColor":  "#FFFFFF",
                  "LabelboxForegroundColor":  "#047857",
                  "MainForegroundColor":  "#0F172A",
                  "MainBackgroundColor":  "#FFFFFF",
                  "LabelBackgroundColor":  "#00FFFFFF",
                  "LinkForegroundColor":  "#047857",
                  "LinkHoverForegroundColor":  "#0F172A",
                  "ScrollBarBackgroundColor":  "#C3CBD5",
                  "ScrollBarHoverColor":  "#059669",
                  "ScrollBarDraggingColor":  "#047857",
                  "ProgressBarForegroundColor":  "#059669",
                  "ProgressBarBackgroundColor":  "#E2E8F0",
                  "ProgressBarTextColor":  "#0F172A",
                  "ButtonInstallBackgroundColor":  "#F1F4F8",
                  "ButtonTweaksBackgroundColor":  "#F1F4F8",
                  "ButtonConfigBackgroundColor":  "#F1F4F8",
                  "ButtonUpdatesBackgroundColor":  "#F1F4F8",
                  "ButtonInstallForegroundColor":  "#0F172A",
                  "ButtonTweaksForegroundColor":  "#0F172A",
                  "ButtonConfigForegroundColor":  "#0F172A",
                  "ButtonUpdatesForegroundColor":  "#0F172A",
                  "ButtonBackgroundColor":  "#F1F4F8",
                  "ButtonBackgroundPressedColor":  "#CBD5E1",
                  "ButtonBackgroundMouseoverColor":  "#E2E8F0",
                  "ButtonBackgroundSelectedColor":  "#D1FAE5",
                  "ButtonBackgroundDisabledColor":  "#F1F4F8",
                  "ButtonForegroundColor":  "#0F172A",
                  "ButtonForegroundDisabledColor":  "#A0A8B4",
                  "ToggleButtonOnColor":  "#059669",
                  "ToggleButtonOffColor":  "#7C8798",
                  "ToolTipBackgroundColor":  "#FFFFFF",
                  "BorderColor":  "#D6DCE4",
                  "BorderOpacity":  "0.2",
                  "WindowBackgroundStartColor":  "#F8FAFC",
                  "WindowBackgroundEndColor":  "#EEF2F6",
                  "SidebarBackgroundColor":  "#0A0F172A",
                  "GroupBorderBackgroundColor":  "#FFFFFF",
                  "AccentColor":  "#047857",
                  "AccentGlowColor":  "#047857",
                  "AccentGlowOpacity":  "0.18",
                  "MutedForegroundColor":  "#556275",
                  "CheckboxMouseOverColor":  "#047857",
                  "FOSSHighlightColor":  "#15803D",
                  "DataGridAlternatingRowColor":  "#F5F7FA",
                  "SuccessColor":  "#047857",
                  "WarningColor":  "#B45309",
                  "DangerColor":  "#DC2626"
              },
    "Dark":  {
                 "AppInstallUnselectedColor":  "#14FFFFFF",
                 "AppInstallHighlightedColor":  "#26FFFFFF",
                 "AppInstallSelectedColor":  "#403DF5A0",
                 "AppInstallOverlayBackgroundColor":  "#CC07090F",
                 "ComboBoxForegroundColor":  "#F8FAFC",
                 "ComboBoxBackgroundColor":  "#FF121724",
                 "LabelboxForegroundColor":  "#3DF5A0",
                 "MainForegroundColor":  "#F8FAFC",
                 "MainBackgroundColor":  "#E60B0E16",
                 "LabelBackgroundColor":  "#00FFFFFF",
                 "LinkForegroundColor":  "#3DF5A0",
                 "LinkHoverForegroundColor":  "#F8FAFC",
                 "ScrollBarBackgroundColor":  "#1AFFFFFF",
                 "ScrollBarHoverColor":  "#3DF5A0",
                 "ScrollBarDraggingColor":  "#2BD389",
                 "ProgressBarForegroundColor":  "#3DF5A0",
                 "ProgressBarBackgroundColor":  "#1AFFFFFF",
                 "ProgressBarTextColor":  "#F8FAFC",
                 "ButtonInstallBackgroundColor":  "#59161B26",
                 "ButtonTweaksBackgroundColor":  "#59161B26",
                 "ButtonConfigBackgroundColor":  "#59161B26",
                 "ButtonUpdatesBackgroundColor":  "#59161B26",
                 "ButtonInstallForegroundColor":  "#F8FAFC",
                 "ButtonTweaksForegroundColor":  "#F8FAFC",
                 "ButtonConfigForegroundColor":  "#F8FAFC",
                 "ButtonUpdatesForegroundColor":  "#F8FAFC",
                 "ButtonBackgroundColor":  "#1AFFFFFF",
                 "ButtonBackgroundPressedColor":  "#3DF5A0",
                 "ButtonBackgroundMouseoverColor":  "#26FFFFFF",
                 "ButtonBackgroundSelectedColor":  "#403DF5A0",
                 "ButtonBackgroundDisabledColor":  "#403DF5A0",
                 "ButtonForegroundColor":  "#F8FAFC",
                 "ButtonForegroundDisabledColor":  "#696969",
                 "ToggleButtonOnColor":  "#3DF5A0",
                 "ToggleButtonOffColor":  "#4A5568",
                 "ToolTipBackgroundColor":  "#FF121724",
                 "BorderColor":  "#3DF5A0",
                 "BorderOpacity":  "0.10",
                 "WindowBackgroundStartColor":  "#0B0E16",
                 "WindowBackgroundEndColor":  "#07090F",
                 "SidebarBackgroundColor":  "#26000000",
                 "GroupBorderBackgroundColor":  "#59161B26",
                 "AccentColor":  "#3DF5A0",
                 "AccentGlowColor":  "#3DF5A0",
                 "AccentGlowOpacity":  "0.45",
                 "MutedForegroundColor":  "#8A93A6",
                 "CheckboxMouseOverColor":  "#3DF5A0",
                 "FOSSHighlightColor":  "#4CAF50",
                 "DataGridAlternatingRowColor":  "#14FFFFFF",
                 "SuccessColor":  "#3DF5A0",
                 "WarningColor":  "#F5A623",
                 "DangerColor":  "#EF4444"
             }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
    "WPFTweaksActivity":  {
                              "Content":  "Cronologia attivit\u00e0 - Disattiva",
                              "Description":  "Cancella la cronologia dei documenti recenti, degli appunti e dei comandi eseguiti.",
                              "category":  "Ottimizzazioni essenziali",
                              "panel":  "1",
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "EnableActivityFeed",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "PublishUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                   "Name":  "UploadUserActivities",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "\u003cRemoveEntry\u003e"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksHiber":  {
                           "Content":  "Ibernazione - Disattiva",
                           "Description":  "L\u0027ibernazione \u00e8 pensata per i portatili: salva il contenuto della memoria prima di spegnere il PC. Di norma non \u00e8 necessaria.",
                           "category":  "Ottimizzazioni essenziali",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
                                                "Name":  "HibernateEnabled",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            },
                                            {
                                                "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
                                                "Name":  "ShowHibernateOption",
                                                "Value":  "0",
                                                "Type":  "DWord",
                                                "OriginalValue":  "1"
                                            }
                                        ],
                           "InvokeScript":  [
                                                "powercfg.exe /hibernate off"
                                            ],
                           "UndoScript":  [
                                              "powercfg.exe /hibernate on"
                                          ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFTweaksWidget":  {
                            "Content":  "Widget - Rimuovi",
                            "Description":  "Rimuove i widget in basso a sinistra sulla barra delle applicazioni.",
                            "category":  "Ottimizzazioni essenziali",
                            "panel":  "1",
                            "InvokeScript":  [
                                                 "\r\n      # Sometimes if you dont stop the Widgets process the removal may fail\r\n\r\n      Get-Process *Widget* | Stop-Process\r\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      Write-Host \"Removed widgets\"\r\n      "
                                             ],
                            "UndoScript":  [
                                               "\r\n      Write-Host \"Restoring widgets AppxPackages\"\r\n\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\Microsoft.WidgetsPlatformRuntime*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n      Add-AppxPackage -Register \"C:\\Program Files\\WindowsApps\\MicrosoftWindows.Client.WebExperience*\\AppxManifest.xml\" -DisableDevelopmentMode\r\n\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                           ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFTweaksRevertStartMenu":  {
                                     "Content":  "Menu Start precedente - Attiva",
                                     "Description":  "Ripristina il layout del menu Start in uso prima del nuovo menu introdotto gradualmente con la 25H2.",
                                     "category":  "Ottimizzazioni essenziali",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/disable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027Old start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                      ],
                                     "UndoScript":  [
                                                        "\r\n      Invoke-WebRequest https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip -OutFile ViVeTool.zip\r\n\r\n      Expand-Archive ViVeTool.zip\r\n      Remove-Item ViVeTool.zip\r\n\r\n      Start-Process \u0027ViVeTool\\ViVeTool.exe\u0027 -ArgumentList \u0027/enable /id:47205210\u0027 -Wait -NoNewWindow\r\n\r\n      Remove-Item ViVeTool -Recurse\r\n\r\n      Write-Host \u0027New start menu reverted. Please restart your computer to take effect.\u0027\r\n      "
                                                    ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksDisableStoreSearch":  {
                                        "Content":  "Risultati consigliati del Microsoft Store nella ricerca - Disattiva",
                                        "Description":  "Non mostra le app consigliate del Microsoft Store quando si cercano app dal menu Start.",
                                        "category":  "Ottimizzazioni essenziali",
                                        "panel":  "1",
                                        "InvokeScript":  [
                                                             "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
                                                         ],
                                        "UndoScript":  [
                                                           "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
                                                       ],
                                        "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                    },
    "WPFTweaksLocation":  {
                              "Content":  "Rilevamento della posizione - Disattiva",
                              "Description":  "Disattiva il rilevamento della posizione.",
                              "category":  "Ottimizzazioni essenziali",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "lfsvc",
                                                  "StartupType":  "Disable",
                                                  "OriginalType":  "Manual"
                                              }
                                          ],
                              "registry":  [
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
                                                   "Name":  "Value",
                                                   "Value":  "Deny",
                                                   "Type":  "String",
                                                   "OriginalValue":  "Allow"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
                                                   "Name":  "SensorPermissionState",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               },
                                               {
                                                   "Path":  "HKLM:\\SYSTEM\\Maps",
                                                   "Name":  "AutoUpdateEnabled",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksServices":  {
                              "Content":  "Servizi - Imposta su Manuale",
                              "Description":  "Imposta l\u0027avvio manuale per diversi servizi di sistema che non devono restare sempre attivi. \u00c8 un\u0027operazione sicura: se un servizio serve, si avvia da solo quando viene richiesto.",
                              "category":  "Ottimizzazioni essenziali",
                              "panel":  "1",
                              "service":  [
                                              {
                                                  "Name":  "CscService",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "DiagTrack",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "MapsBroker",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "RemoteAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              },
                                              {
                                                  "Name":  "RemoteRegistry",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              },
                                              {
                                                  "Name":  "StorSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "SharedAccess",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Automatic"
                                              },
                                              {
                                                  "Name":  "TermService",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "TroubleshootingSvc",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "seclogon",
                                                  "StartupType":  "Manual",
                                                  "OriginalType":  "Manual"
                                              },
                                              {
                                                  "Name":  "ssh-agent",
                                                  "StartupType":  "Disabled",
                                                  "OriginalType":  "Disabled"
                                              }
                                          ],
                              "InvokeScript":  [
                                                   "\r\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\r\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\r\n      "
                                               ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFTweaksBraveDebloat":  {
                                  "Content":  "Browser Brave - Alleggerisci",
                                  "Description":  "Disattiva varie funzioni non necessarie come Brave Rewards, Leo AI, Crypto Wallet e VPN.",
                                  "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                  "panel":  "1",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveRewardsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveWalletDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveVPNDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveAIChatEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveStatsPingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveNewsDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveTalkDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "TorDisabled",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "BraveP3AEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "UrlKeyedAnonymizedDataCollectionEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "SafeBrowsingExtendedReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
                                                       "Name":  "MetricsReportingEnabled",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFTweaksDisableWarningForUnsignedRdp":  {
                                                  "Content":  "Avvisi per i file RDP non firmati - Disattiva",
                                                  "Description":  "Disattiva gli avvisi mostrati all\u0027apertura di file RDP non firmati, introdotti con gli ultimi aggiornamenti di Windows 10 e 11.",
                                                  "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                                  "panel":  "1",
                                                  "registry":  [
                                                                   {
                                                                       "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
                                                                       "Name":  "RedirectionWarningDialogVersion",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   },
                                                                   {
                                                                       "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
                                                                       "Name":  "RdpLaunchConsentAccepted",
                                                                       "Value":  "1",
                                                                       "Type":  "DWord",
                                                                       "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                                   }
                                                               ],
                                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                              },
    "WPFTweaksEdgeDebloat":  {
                                 "Content":  "Microsoft Edge - Alleggerisci",
                                 "Description":  "Disattiva diverse opzioni di telemetria, le finestre a comparsa e altre funzioni superflue di Edge.",
                                 "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
                                                      "Name":  "CreateDesktopShortcutDefault",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "PersonalizationReportingEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
                                                      "Name":  "1",
                                                      "Value":  "ofefcgjbeghpigppfmkologfjadafddi",
                                                      "Type":  "String",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowRecommendationsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "HideFirstRunExperience",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "UserFeedbackAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ConfigureDoNotTrack",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "AlternateErrorPagesEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeCollectionsEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeShoppingAssistantEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "MicrosoftEdgeInsiderPromotionEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "ShowMicrosoftRewards",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WebWidgetAllowed",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DiagnosticData",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "EdgeAssetDeliveryServiceEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "WalletDonationEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  },
                                                  {
                                                      "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
                                                      "Name":  "DefaultBrowserSettingsCampaignEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                  }
                                              ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksConsumerFeatures":  {
                                      "Content":  "Funzionalit\u00e0 consumer - Disattiva",
                                      "Description":  "Windows non installer\u00e0 pi\u00f9 da solo giochi, app di terze parti o collegamenti ad app del Microsoft Store per l\u0027utente connesso. Alcune app predefinite non saranno disponibili (ad es. Collegamento al telefono).",
                                      "category":  "Ottimizzazioni essenziali",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
                                                           "Name":  "DisableWindowsConsumerFeatures",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFTweaksTelemetry":  {
                               "Content":  "Telemetria - Disattiva",
                               "Description":  "Disattiva la telemetria di Microsoft.",
                               "category":  "Ottimizzazioni essenziali",
                               "panel":  "1",
                               "registry":  [
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
                                                    "Name":  "TailoredExperiencesWithDiagnosticDataEnabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
                                                    "Name":  "HasAccepted",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Input\\TIPC",
                                                    "Name":  "Enabled",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitInkCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization",
                                                    "Name":  "RestrictImplicitTextCollection",
                                                    "Value":  "1",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
                                                    "Name":  "HarvestContacts",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
                                                    "Name":  "AcceptedPrivacyPolicy",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
                                                    "Name":  "AllowTelemetry",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                    "Name":  "Start_TrackProgs",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "PublishUserActivities",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                },
                                                {
                                                    "Path":  "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
                                                    "Name":  "NumberOfSIUFInPeriod",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                }
                                            ],
                               "InvokeScript":  [
                                                    "\r\n      # Disable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 2\r\n\r\n      # Disable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Disabled\r\n\r\n      # Disable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Disabled\r\n\r\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\r\n      "
                                                ],
                               "UndoScript":  [
                                                  "\r\n      # Enable Defender Auto Sample Submission\r\n      Set-MpPreference -SubmitSamplesConsent 1\r\n\r\n      # Enable (Connected User Experiences and Telemetry) Service\r\n      Set-Service -Name diagtrack -StartupType Automatic\r\n\r\n      # Enable (Windows Error Reporting Manager) Service\r\n      Set-Service -Name wermgr -StartupType Automatic\r\n      "
                                              ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFTweaksRemoveEdge":  {
                                "Content":  "Microsoft Edge - Rimuovi",
                                "Description":  "Sblocca le restrizioni del programma di disinstallazione di Microsoft Edge e lo usa per rimuovere Edge.",
                                "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "Invoke-WinUtilRemoveEdge"
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      Write-Host \u0027Installing Microsoft Edge...\u0027\r\n      winget install Microsoft.Edge --source winget\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksUTC":  {
                         "Content":  "Data e ora - Imposta l\u0027orologio su UTC",
                         "Description":  "Indispensabile sui PC con doppio avvio: allinea l\u0027orario con i sistemi Linux.",
                         "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                         "panel":  "1",
                         "registry":  [
                                          {
                                              "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
                                              "Name":  "RealTimeIsUniversal",
                                              "Value":  "1",
                                              "Type":  "QWord",
                                              "OriginalValue":  "0"
                                          }
                                      ],
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFTweaksRemoveOneDrive":  {
                                    "Content":  "Microsoft OneDrive - Rimuovi",
                                    "Description":  "Impedisce la cancellazione dei file utente di OneDrive, lo rimuove con il suo programma di disinstallazione e poi ripristina i permessi originali.",
                                    "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      # Deny permission to remove OneDrive folder\r\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\r\n\r\n      Write-Host \"Uninstalling OneDrive...\"\r\n      Start-Process \u0027C:\\Windows\\System32\\OneDriveSetup.exe\u0027 -ArgumentList \u0027/uninstall\u0027 -Wait\r\n\r\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\r\n      Write-Host \"Removing leftover OneDrive Files...\"\r\n      Stop-Process -Name FileCoAuth,Explorer\r\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\r\n      Remove-Item \"C:\\ProgramData\\Microsoft OneDrive\" -Recurse -Force\r\n\r\n      # Grant back permission to access OneDrive folder\r\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\r\n\r\n      # Disable OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Disabled\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Write-Host \"Installing OneDrive\"\r\n      winget install Microsoft.Onedrive --source winget\r\n\r\n      # Enabled OneSyncSvc\r\n      Set-Service -Name OneSyncSvc -StartupType Automatic\r\n      "
                                                   ],
                                    "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                },
    "WPFTweaksRemoveHome":  {
                                "Content":  "Home di Esplora file - Disattiva",
                                "Description":  "Rimuove Home da Esplora file e imposta Questo PC come cartella predefinita.",
                                "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                "panel":  "1",
                                "InvokeScript":  [
                                                     "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 1\r\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}\"\r\n      Set-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" -Name LaunchTo -Value 0\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksRemoveGallery":  {
                                   "Content":  "Raccolta di Esplora file - Disattiva",
                                   "Description":  "Rimuove Raccolta da Esplora file e imposta Questo PC come cartella predefinita.",
                                   "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      Remove-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Desktop\\NameSpace\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}\"\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksDisplay":  {
                             "Content":  "Effetti visivi - Imposta per le prestazioni migliori",
                             "Description":  "Imposta le opzioni di sistema per privilegiare le prestazioni. Si pu\u00f2 fare anche a mano da sysdm.cpl.",
                             "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "DragFullWindows",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop",
                                                  "Name":  "MenuShowDelay",
                                                  "Value":  "200",
                                                  "Type":  "String",
                                                  "OriginalValue":  "400"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
                                                  "Name":  "MinAnimate",
                                                  "Value":  "0",
                                                  "Type":  "String",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "KeyboardDelay",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewAlphaSelect",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ListviewShadow",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarAnimations",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
                                                  "Name":  "VisualFXSetting",
                                                  "Value":  "3",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\DWM",
                                                  "Name":  "EnableAeroPeek",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "TaskbarMn",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "ShowTaskViewButton",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                  "Name":  "SearchboxTaskbarMode",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
                                              ],
                             "UndoScript":  [
                                                "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
                                            ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksXboxRemoval":  {
                                 "Content":  "Componenti Xbox e gaming - Rimuovi",
                                 "Description":  "Rimuove i servizi Xbox, l\u0027app Xbox, la Game Bar e i relativi componenti di autenticazione.",
                                 "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\GameDVR",
                                                      "Name":  "AppCaptureEnabled",
                                                      "Value":  "0",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "1"
                                                  }
                                              ],
                                 "appx":  [
                                              "Microsoft.XboxIdentityProvider",
                                              "Microsoft.XboxSpeechToTextOverlay",
                                              "Microsoft.GamingApp",
                                              "Microsoft.Xbox.TCUI",
                                              "Microsoft.XboxGamingOverlay"
                                          ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDeBloat":  {
                             "Content":  "App preinstallate superflue - Rimuovi",
                             "Description":  "Rimuove molte app preinstallate di Windows che la maggior parte degli utenti non usa.",
                             "category":  "Ottimizzazioni essenziali",
                             "panel":  "1",
                             "appx":  [
                                          "Microsoft.WindowsFeedbackHub",
                                          "Microsoft.BingNews",
                                          "Microsoft.BingSearch",
                                          "Microsoft.BingWeather",
                                          "Clipchamp.Clipchamp",
                                          "Microsoft.Todos",
                                          "Microsoft.PowerAutomateDesktop",
                                          "Microsoft.MicrosoftSolitaireCollection",
                                          "Microsoft.WindowsSoundRecorder",
                                          "Microsoft.MicrosoftStickyNotes",
                                          "Microsoft.Windows.DevHome",
                                          "Microsoft.Paint",
                                          "Microsoft.OutlookForWindows",
                                          "Microsoft.WindowsAlarms",
                                          "Microsoft.StartExperiencesApp",
                                          "Microsoft.GetHelp",
                                          "Microsoft.ZuneMusic",
                                          "MicrosoftCorporationII.QuickAssist",
                                          "MSTeams"
                                      ],
                             "InvokeScript":  [
                                                  "\r\n      $TeamsPath = \"$Env:LocalAppData\\Microsoft\\Teams\\Update.exe\"\r\n\r\n      if (Test-Path $TeamsPath) {\r\n        Write-Host \"Uninstalling Teams\"\r\n        Start-Process $TeamsPath -ArgumentList -uninstall -wait\r\n\r\n        Write-Host \"Deleting Teams directory\"\r\n        Remove-Item $TeamsPath -Recurse -Force\r\n      }\r\n      "
                                              ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksRestorePoint":  {
                                  "Content":  "Punto di ripristino - Crea",
                                  "Description":  "Crea un punto di ripristino prima di applicare le modifiche, per poter tornare indietro se necessario.",
                                  "category":  "Ottimizzazioni essenziali",
                                  "panel":  "1",
                                  "Checked":  "False",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
                                                       "Name":  "SystemRestorePointCreationFrequency",
                                                       "Value":  "0",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "1440"
                                                   }
                                               ],
                                  "InvokeScript":  [
                                                       "\r\n      if (-not (Get-ComputerRestorePoint)) {\r\n          Enable-ComputerRestore -Drive $Env:SystemDrive\r\n      }\r\n\r\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\r\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\r\n      "
                                                   ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFTweaksEndTaskOnTaskbar":  {
                                      "Content":  "Termina attivit\u00e0 con il tasto destro - Attiva",
                                      "Description":  "Aggiunge l\u0027opzione per terminare un programma facendo clic destro sulla sua icona nella barra delle applicazioni.",
                                      "category":  "Ottimizzazioni essenziali",
                                      "panel":  "1",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
                                                           "Name":  "TaskbarEndTask",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFTweaksPowershell7Tele":  {
                                     "Content":  "Telemetria di PowerShell 7 - Disattiva",
                                     "Description":  "Crea la variabile di ambiente \u0027POWERSHELL_TELEMETRY_OPTOUT\u0027 con valore \u00271\u0027, cos\u00ec PowerShell 7 non invia dati di telemetria.",
                                     "category":  "Ottimizzazioni essenziali",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u00271\u0027, \u0027Machine\u0027)"
                                                      ],
                                     "UndoScript":  [
                                                        "[Environment]::SetEnvironmentVariable(\u0027POWERSHELL_TELEMETRY_OPTOUT\u0027, \u0027\u0027, \u0027Machine\u0027)"
                                                    ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksStorage":  {
                             "Content":  "Sensore memoria - Disattiva",
                             "Description":  "Sensore memoria elimina automaticamente i file temporanei.",
                             "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                             "panel":  "1",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
                                                  "Name":  "01",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksRemoveCopilot":  {
                                   "Content":  "Microsoft Copilot - Disattiva",
                                   "Description":  "Rimuove i pacchetti AppX di Copilot e i relativi pacchetti di intelligenza artificiale.",
                                   "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      Get-AppxPackage -AllUsers *Copilot* | Remove-AppxPackage -AllUsers\r\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\r\n\r\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\r\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\r\n\r\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\r\n      Remove-AppxPackage $Appx\r\n\r\n      Write-Host \"Copilot Removed\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      Write-Host \"Installing Copilot...\"\r\n      winget install --name Copilot --source msstore --accept-package-agreements --accept-source-agreements --silent\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksWPBT":  {
                          "Content":  "Windows Platform Binary Table (WPBT) - Disattiva",
                          "Description":  "Se attiva, la WPBT permette al produttore del PC di eseguire programmi all\u0027avvio, come software antifurto o driver, e di installare software senza il consenso dell\u0027utente. \u00c8 un potenziale rischio per la sicurezza.",
                          "category":  "Ottimizzazioni essenziali",
                          "panel":  "1",
                          "registry":  [
                                           {
                                               "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
                                               "Name":  "DisableWpbtExecution",
                                               "Value":  "1",
                                               "Type":  "DWord",
                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                           }
                                       ],
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFTweaksRazerBlock":  {
                                "Content":  "Installazione automatica del software Razer - Disattiva",
                                "Description":  "Blocca TUTTE le installazioni di software Razer. Le periferiche funzionano anche senza.",
                                "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
                                                     "Name":  "SearchOrderConfig",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1"
                                                 },
                                                 {
                                                     "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
                                                     "Name":  "DisableCoInstallers",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "InvokeScript":  [
                                                     "\r\n      $RazerPath = \"C:\\Windows\\Installer\\Razer\"\r\n\r\n      if (Test-Path $RazerPath) {\r\n        Remove-Item $RazerPath\\* -Recurse -Force\r\n      } else {\r\n        New-Item -Path $RazerPath -ItemType Directory\r\n      }\r\n\r\n      icacls $RazerPath /deny \"Everyone:(W)\"\r\n      "
                                                 ],
                                "UndoScript":  [
                                                   "\r\n      icacls \"C:\\Windows\\Installer\\Razer\" /remove:d Everyone\r\n      "
                                               ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFTweaksDisableNotifications":  {
                                          "Content":  "Notifiche e calendario nell\u0027area di notifica - Disattiva",
                                          "Description":  "Disattiva tutte le notifiche, COMPRESO il calendario.",
                                          "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                          "panel":  "1",
                                          "registry":  [
                                                           {
                                                               "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
                                                               "Name":  "DisableNotificationCenter",
                                                               "Value":  "1",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "\u003cRemoveEntry\u003e"
                                                           },
                                                           {
                                                               "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
                                                               "Name":  "ToastEnabled",
                                                               "Value":  "0",
                                                               "Type":  "DWord",
                                                               "OriginalValue":  "1"
                                                           }
                                                       ],
                                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                      },
    "WPFTweaksBlockAdobeNet":  {
                                   "Content":  "Blocco degli indirizzi Adobe - Attiva",
                                   "Description":  "Riduce le interruzioni bloccando in modo selettivo le connessioni ai server di attivazione e telemetria di Adobe. Crediti: Ruddernation-Designs",
                                   "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                   "panel":  "1",
                                   "InvokeScript":  [
                                                        "\r\n      $hostsUrl = \"https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\"\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Move-Item $hosts \"$hosts.bak\"\r\n      Invoke-WebRequest $hostsUrl -OutFile $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Added Adobe url block list from host file\"\r\n      "
                                                    ],
                                   "UndoScript":  [
                                                      "\r\n      $hosts = \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\"\r\n\r\n      Remove-Item $hosts\r\n      Move-Item \"$hosts.bak\" $hosts\r\n      ipconfig /flushdns\r\n\r\n      Write-Host \"Removed Adobe url block list from host file\"\r\n      "
                                                  ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksRightClickMenu":  {
                                    "Content":  "Menu classico del tasto destro - Attiva",
                                    "Description":  "Ripristina il menu contestuale classico di Esplora file al posto di quello semplificato di Windows 11.",
                                    "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                    "panel":  "1",
                                    "InvokeScript":  [
                                                         "\r\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name \"InprocServer32\" -force -value \"\"\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                     ],
                                    "UndoScript":  [
                                                       "\r\n      Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse -Confirm:$false -Force\r\n      # Restarting Explorer in the Undo Script might not be necessary, as the Registry change without restarting Explorer does work, but just to make sure.\r\n      Write-Host Restarting explorer.exe ...\r\n      Stop-Process -Name \"explorer\" -Force\r\n      "
                                                   ],
                                    "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                },
    "WPFTweaksDiskCleanup":  {
                                 "Content":  "Pulizia disco - Esegui",
                                 "Description":  "Esegue Pulizia disco sull\u0027unit\u00e0 C: e rimuove i vecchi aggiornamenti di Windows.",
                                 "category":  "Ottimizzazioni essenziali",
                                 "panel":  "1",
                                 "InvokeScript":  [
                                                      "\r\n      cleanmgr.exe /d C: /VERYLOWDISK\r\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\r\n      "
                                                  ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDeleteTempFiles":  {
                                     "Content":  "File temporanei - Elimina",
                                     "Description":  "Svuota le cartelle dei file temporanei (TEMP).",
                                     "category":  "Ottimizzazioni essenziali",
                                     "panel":  "1",
                                     "InvokeScript":  [
                                                          "\r\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\r\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\r\n      "
                                                      ],
                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                 },
    "WPFTweaksIPv46":  {
                           "Content":  "IPv6 - Preferisci IPv4",
                           "Description":  "Dare la precedenza a IPv4 pu\u00f2 ridurre la latenza e migliorare la sicurezza nelle reti private in cui IPv6 non \u00e8 configurato.",
                           "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                           "panel":  "1",
                           "registry":  [
                                            {
                                                "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                "Name":  "DisabledComponents",
                                                "Value":  "32",
                                                "Type":  "DWord",
                                                "OriginalValue":  "0"
                                            }
                                        ],
                           "link":  "https://github.com/rtecnocopy89/WinRUtil"
                       },
    "WPFTweaksTeredo":  {
                            "Content":  "Teredo - Disattiva",
                            "Description":  "Il tunneling Teredo \u00e8 una funzione di IPv6 che pu\u00f2 aumentare la latenza; disattivarlo pu\u00f2 per\u00f2 causare problemi con alcuni giochi.",
                            "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                            "panel":  "1",
                            "registry":  [
                                             {
                                                 "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                 "Name":  "DisabledComponents",
                                                 "Value":  "1",
                                                 "Type":  "DWord",
                                                 "OriginalValue":  "0"
                                             }
                                         ],
                            "InvokeScript":  [
                                                 "netsh interface teredo set state disabled"
                                             ],
                            "UndoScript":  [
                                               "netsh interface teredo set state default"
                                           ],
                            "link":  "https://github.com/rtecnocopy89/WinRUtil"
                        },
    "WPFTweaksDisableIPv6":  {
                                 "Content":  "IPv6 - Disattiva",
                                 "Description":  "Disattiva IPv6.",
                                 "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                 "panel":  "1",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
                                                      "Name":  "DisabledComponents",
                                                      "Value":  "255",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                  ],
                                 "UndoScript":  [
                                                    "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
                                                ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFTweaksDisableBGapps":  {
                                   "Content":  "App in background - Disattiva",
                                   "Description":  "Impedisce a tutte le app del Microsoft Store di funzionare in background, cosa che da Windows 11 andrebbe fatta app per app.",
                                   "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                   "panel":  "1",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
                                                        "Name":  "GlobalUserDisabled",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0"
                                                    }
                                                ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFTweaksDisableFSO":  {
                                "Content":  "Ottimizzazioni a schermo intero - Disattiva",
                                "Description":  "Disattiva le ottimizzazioni a schermo intero (FSO) in tutte le applicazioni. NOTA: disattiva anche la gestione del colore nello schermo intero esclusivo.",
                                "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                                "panel":  "1",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\System\\GameConfigStore",
                                                     "Name":  "GameDVR_DXGIHonorFSEWindowsCompatible",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleDisableCrossDeviceResume":  {
                                              "Content":  "Ripresa tra dispositivi",
                                              "Description":  "Controlla la funzione Riprendi di Windows 11 24H2 e successive, che permette di riprendere un\u0027attivit\u00e0 dal telefono al PC e viceversa.",
                                              "category":  "Preferenze",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\CrossDeviceResume\\Configuration",
                                                                   "Name":  "IsResumeAllowed",
                                                                   "Value":  "1",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "0",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                          },
    "WPFToggleDetailedBSoD":  {
                                  "Content":  "Schermata blu dettagliata",
                                  "Description":  "Se attiva, la schermata blu (BSoD) mostra informazioni pi\u00f9 dettagliate.",
                                  "category":  "Preferenze",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisplayParameters",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   },
                                                   {
                                                       "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
                                                       "Name":  "DisableEmoticon",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFToggleBatteryPercentage":  {
                                       "Content":  "Percentuale della batteria nell\u0027area di notifica",
                                       "Description":  "Se attiva, mostra la percentuale della batteria accanto alla sua icona nell\u0027area di notifica.",
                                       "category":  "Preferenze",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                            "Name":  "IsBatteryPercentageEnabled",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                            "DefaultState":  "false"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleDarkMode":  {
                              "Content":  "Tema scuro di Windows",
                              "Description":  "Attiva o disattiva la modalit\u00e0 scura.",
                              "category":  "Preferenze",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "AppsUseLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               },
                                               {
                                                   "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                                   "Name":  "SystemUsesLightTheme",
                                                   "Value":  "0",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "1",
                                                   "DefaultState":  "false"
                                               }
                                           ],
                              "InvokeScript":  [
                                                   "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                               ],
                              "UndoScript":  [
                                                 "\r\n      Invoke-WinUtilExplorerUpdate\r\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\r\n        Invoke-WinutilThemeChange -theme \"Auto\"\r\n      }\r\n      "
                                             ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFToggleShowExt":  {
                             "Content":  "Estensioni dei file in Esplora file",
                             "Description":  "Se attivo, le estensioni dei file (ad es. .txt, .jpg) sono visibili.",
                             "category":  "Preferenze",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                  "Name":  "HideFileExt",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "1",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "InvokeScript":  [
                                                  "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                              ],
                             "UndoScript":  [
                                                "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                            ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleHiddenFiles":  {
                                 "Content":  "File nascosti in Esplora file",
                                 "Description":  "Se attivo, i file nascosti vengono mostrati.",
                                 "category":  "Preferenze",
                                 "panel":  "2",
                                 "Type":  "Toggle",
                                 "registry":  [
                                                  {
                                                      "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                      "Name":  "Hidden",
                                                      "Value":  "1",
                                                      "Type":  "DWord",
                                                      "OriginalValue":  "0",
                                                      "DefaultState":  "false"
                                                  }
                                              ],
                                 "InvokeScript":  [
                                                      "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                  ],
                                 "UndoScript":  [
                                                    "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                ],
                                 "link":  "https://github.com/rtecnocopy89/WinRUtil"
                             },
    "WPFToggleVerboseLogon":  {
                                  "Content":  "Messaggi dettagliati all\u0027accesso",
                                  "Description":  "Mostra messaggi dettagliati durante l\u0027accesso, utili per la diagnosi dei problemi.",
                                  "category":  "Preferenze",
                                  "panel":  "2",
                                  "Type":  "Toggle",
                                  "registry":  [
                                                   {
                                                       "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
                                                       "Name":  "VerboseStatus",
                                                       "Value":  "1",
                                                       "Type":  "DWord",
                                                       "OriginalValue":  "0",
                                                       "DefaultState":  "false"
                                                   }
                                               ],
                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                              },
    "WPFToggleNewOutlook":  {
                                "Content":  "Nuova versione di Microsoft Outlook",
                                "Description":  "Se disattivo, rimuove l\u0027interruttore per il nuovo Outlook, blocca la migrazione al nuovo Outlook e mantiene l\u0027Outlook classico.",
                                "category":  "Preferenze",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "UseNewOutlook",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "HideNewOutlookToggle",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "true"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
                                                     "Name":  "DoNewOutlookAutoMigration",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "false"
                                                 },
                                                 {
                                                     "Path":  "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
                                                     "Name":  "NewOutlookMigrationUserSetting",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleScrollbars":  {
                                "Content":  "Barre di scorrimento sempre visibili",
                                "Description":  "Se attivo, le barre di scorrimento sono sempre visibili. Se disattivo, Windows le nasconde quando non servono.",
                                "category":  "Preferenze",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility",
                                                     "Name":  "DynamicScrollbars",
                                                     "Value":  "0",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "1",
                                                     "DefaultState":  "false",
                                                     "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleMultiplaneOverlay":  {
                                       "Content":  "Multiplane Overlay",
                                       "Description":  "Attiva o disattiva il Multiplane Overlay, che a volte causa problemi con alcune schede video.",
                                       "category":  "Preferenze",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
                                                            "Name":  "OverlayTestMode",
                                                            "Value":  "0",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "5",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleMouseAcceleration":  {
                                       "Content":  "Accelerazione del mouse",
                                       "Description":  "Se attiva, il movimento del puntatore dipende dalla velocit\u00e0 con cui si sposta il mouse.",
                                       "category":  "Preferenze",
                                       "panel":  "2",
                                       "Type":  "Toggle",
                                       "registry":  [
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseSpeed",
                                                            "Value":  "1",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold1",
                                                            "Value":  "6",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        },
                                                        {
                                                            "Path":  "HKCU:\\Control Panel\\Mouse",
                                                            "Name":  "MouseThreshold2",
                                                            "Value":  "10",
                                                            "Type":  "DWord",
                                                            "OriginalValue":  "0",
                                                            "DefaultState":  "true"
                                                        }
                                                    ],
                                       "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                   },
    "WPFToggleNumLock":  {
                             "Content":  "Bloc Num all\u0027avvio",
                             "Description":  "Imposta lo stato del tasto Bloc Num all\u0027avvio del computer.",
                             "category":  "Preferenze",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKU:\\.Default\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              },
                                              {
                                                  "Path":  "HKCU:\\Control Panel\\Keyboard",
                                                  "Name":  "InitialKeyboardIndicators",
                                                  "Value":  "2",
                                                  "Type":  "String",
                                                  "OriginalValue":  "0",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleStandbyFix":  {
                                "Content":  "Rete durante la sospensione S0",
                                "Description":  "Attiva o disattiva la connessione di rete durante la sospensione S0 (Modern Standby).",
                                "category":  "Preferenze",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
                                                     "Name":  "ACSettingIndex",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleS3Sleep":  {
                             "Content":  "Sospensione S3",
                             "Description":  "Passa dalla sospensione moderna (Modern Standby) alla sospensione S3 e viceversa.",
                             "category":  "Preferenze",
                             "panel":  "2",
                             "Type":  "Toggle",
                             "registry":  [
                                              {
                                                  "Path":  "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
                                                  "Name":  "PlatformAoAcOverride",
                                                  "Value":  "0",
                                                  "Type":  "DWord",
                                                  "OriginalValue":  "\u003cRemoveEntry\u003e",
                                                  "DefaultState":  "false"
                                              }
                                          ],
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFToggleHideSettingsHome":  {
                                      "Content":  "Pagina Home delle Impostazioni",
                                      "Description":  "Attiva o disattiva la pagina Home nell\u0027app Impostazioni di Windows.",
                                      "category":  "Preferenze",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
                                                           "Name":  "SettingsPageVisibility",
                                                           "Value":  "show:home",
                                                           "Type":  "String",
                                                           "OriginalValue":  "hide:home",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFToggleBingSearch":  {
                                "Content":  "Ricerca Bing nel menu Start",
                                "Description":  "Se attiva, la ricerca nel menu Start include anche i risultati web di Bing.",
                                "category":  "Preferenze",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                     "Name":  "BingSearchEnabled",
                                                     "Value":  "1",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "0",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleLoginBlur":  {
                               "Content":  "Sfocatura della schermata di accesso",
                               "Description":  "Se disattiva, rimuove l\u0027effetto sfocato (acrilico) dallo sfondo della schermata di accesso di Windows 10/11.",
                               "category":  "Preferenze",
                               "panel":  "2",
                               "Type":  "Toggle",
                               "registry":  [
                                                {
                                                    "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
                                                    "Name":  "DisableAcrylicBackgroundOnLogon",
                                                    "Value":  "0",
                                                    "Type":  "DWord",
                                                    "OriginalValue":  "1",
                                                    "DefaultState":  "true"
                                                }
                                            ],
                               "link":  "https://github.com/rtecnocopy89/WinRUtil"
                           },
    "WPFToggleStartMenuRecommendations":  {
                                              "Content":  "Consigliati nel menu Start",
                                              "Description":  "Se disattivo, il menu Start non mostra pi\u00f9 i contenuti consigliati. ATTENZIONE: disattiva anche Windows Spotlight nella schermata di blocco.",
                                              "category":  "Preferenze",
                                              "panel":  "2",
                                              "Type":  "Toggle",
                                              "registry":  [
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
                                                                   "Name":  "IsEducationEnvironment",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               },
                                                               {
                                                                   "Path":  "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
                                                                   "Name":  "HideRecommendedSection",
                                                                   "Value":  "0",
                                                                   "Type":  "DWord",
                                                                   "OriginalValue":  "1",
                                                                   "DefaultState":  "true"
                                                               }
                                                           ],
                                              "InvokeScript":  [
                                                                   "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                               ],
                                              "UndoScript":  [
                                                                 "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                             ],
                                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                          },
    "WPFToggleStickyKeys":  {
                                "Content":  "Tasti permanenti",
                                "Description":  "Se attivo, abilita i Tasti permanenti, una funzione di accessibilit\u00e0 che aiuta chi ha difficolt\u00e0 a premere pi\u00f9 tasti insieme e riduce lo sforzo ripetitivo.",
                                "category":  "Preferenze",
                                "panel":  "2",
                                "Type":  "Toggle",
                                "registry":  [
                                                 {
                                                     "Path":  "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
                                                     "Name":  "Flags",
                                                     "Value":  "506",
                                                     "Type":  "DWord",
                                                     "OriginalValue":  "58",
                                                     "DefaultState":  "true"
                                                 }
                                             ],
                                "link":  "https://github.com/rtecnocopy89/WinRUtil"
                            },
    "WPFToggleTaskbarAlignment":  {
                                      "Content":  "Icone della barra delle applicazioni al centro",
                                      "Description":  "[Windows 11] Se attivo, le icone della barra delle applicazioni sono al centro, altrimenti a sinistra.",
                                      "category":  "Preferenze",
                                      "panel":  "2",
                                      "Type":  "Toggle",
                                      "registry":  [
                                                       {
                                                           "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                           "Name":  "TaskbarAl",
                                                           "Value":  "1",
                                                           "Type":  "DWord",
                                                           "OriginalValue":  "0",
                                                           "DefaultState":  "true"
                                                       }
                                                   ],
                                      "InvokeScript":  [
                                                           "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                       ],
                                      "UndoScript":  [
                                                         "\r\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\r\n      "
                                                     ],
                                      "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                  },
    "WPFToggleTaskbarSearch":  {
                                   "Content":  "Icona Cerca nella barra delle applicazioni",
                                   "Description":  "Se attivo, il pulsante Cerca compare nella barra delle applicazioni.",
                                   "category":  "Preferenze",
                                   "panel":  "2",
                                   "Type":  "Toggle",
                                   "registry":  [
                                                    {
                                                        "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
                                                        "Name":  "SearchboxTaskbarMode",
                                                        "Value":  "1",
                                                        "Type":  "DWord",
                                                        "OriginalValue":  "0",
                                                        "DefaultState":  "true"
                                                    }
                                                ],
                                   "link":  "https://github.com/rtecnocopy89/WinRUtil"
                               },
    "WPFToggleTaskView":  {
                              "Content":  "Icona Visualizzazione attivit\u00e0 nella barra delle applicazioni",
                              "Description":  "Se attivo, il pulsante Visualizzazione attivit\u00e0 compare nella barra delle applicazioni.",
                              "category":  "Preferenze",
                              "panel":  "2",
                              "Type":  "Toggle",
                              "registry":  [
                                               {
                                                   "Path":  "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
                                                   "Name":  "ShowTaskViewButton",
                                                   "Value":  "1",
                                                   "Type":  "DWord",
                                                   "OriginalValue":  "0",
                                                   "DefaultState":  "true"
                                               }
                                           ],
                              "link":  "https://github.com/rtecnocopy89/WinRUtil"
                          },
    "WPFOOSUbutton":  {
                          "Content":  "O\u0026O ShutUp10++ - Esegui",
                          "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                          "panel":  "1",
                          "Type":  "Button",
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFchangedns":  {
                         "Content":  "DNS - Imposta su:",
                         "category":  "z__Ottimizzazioni avanzate - ATTENZIONE",
                         "panel":  "1",
                         "Type":  "Combobox",
                         "ComboItems":  "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
                         "link":  "https://github.com/rtecnocopy89/WinRUtil"
                     },
    "WPFAddUltPerf":  {
                          "Content":  "Profilo Prestazioni eccellenti - Attiva",
                          "category":  "z__Piani di alimentazione",
                          "panel":  "2",
                          "Type":  "Button",
                          "ButtonWidth":  "300",
                          "link":  "https://github.com/rtecnocopy89/WinRUtil"
                      },
    "WPFRemoveUltPerf":  {
                             "Content":  "Profilo Prestazioni eccellenti - Disattiva",
                             "category":  "z__Piani di alimentazione",
                             "panel":  "2",
                             "Type":  "Button",
                             "ButtonWidth":  "300",
                             "link":  "https://github.com/rtecnocopy89/WinRUtil"
                         },
    "WPFTweaksDisableExplorerAutoDiscovery":  {
                                                  "Content":  "Rilevamento automatico del tipo di cartella - Disattiva",
                                                  "Description":  "Esplora file cerca di indovinare il tipo di cartella in base al contenuto e questo rallenta la navigazione. ATTENZIONE: disattiva il raggruppamento in Esplora file.",
                                                  "category":  "Ottimizzazioni essenziali",
                                                  "panel":  "1",
                                                  "InvokeScript":  [
                                                                       "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      # Every folder\r\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\r\n\r\n      if (!(Test-Path $allFolders)) {\r\n        New-Item -Path $allFolders -Force\r\n        Write-Host \"Created $allFolders\"\r\n      }\r\n\r\n      # Generic view\r\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\r\n      Write-Host \"Set FolderType to NotSpecified\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                   ],
                                                  "UndoScript":  [
                                                                     "\r\n      # Previously detected folders\r\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\r\n\r\n      # Folder types lookup table\r\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\r\n\r\n      # Flush Explorer view database\r\n      Remove-Item -Path $bags -Recurse -Force\r\n      Write-Host \"Removed $bags\"\r\n\r\n      Remove-Item -Path $bagMRU -Recurse -Force\r\n      Write-Host \"Removed $bagMRU\"\r\n\r\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\r\n      "
                                                                 ],
                                                  "link":  "https://github.com/rtecnocopy89/WinRUtil"
                                              }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window x:Class="WinRUtil.MainWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinRUtil"
        mc:Ignorable="d"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Width="Auto"
        Height="Auto"
        MinWidth="900"
        MinHeight="640"
        Title="WinRUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="14" GlassFrameThickness="0" ResizeBorderThickness="6"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid x:Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border x:Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="2"/>
        <Setter Property="Padding" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <StackPanel Orientation="Horizontal">
                        <Grid Width="16" Height="16" Margin="0,0,8,0">
                            <Border x:Name="CheckBoxBorder"
                                    BorderBrush="{DynamicResource MainForegroundColor}"
                                    Background="{DynamicResource ButtonBackgroundColor}"
                                    BorderThickness="1"
                                    Width="12"
                                    Height="12"
                                    CornerRadius="2"/>
                            <Path x:Name="CheckMark"
                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                  StrokeThickness="2"
                                  Data="M 2 8 L 6 12 L 14 4"
                                  Visibility="Collapsed"/>
                        </Grid>
                        <ContentPresenter Content="{TemplateBinding Content}"
                                        VerticalAlignment="Center"
                                        HorizontalAlignment="Left"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundDisabledColor}"/>
                                <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundDisabledColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid x:Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track x:Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb x:Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton x:Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton x:Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton x:Name="ToggleButton"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              Margin="0"
                                              Focusable="False"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <ToggleButton.Template>
                                        <ControlTemplate TargetType="ToggleButton">
                                            <Border Background="{TemplateBinding Background}">
                                                <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"/>
                                            </Border>
                                        </ControlTemplate>
                                    </ToggleButton.Template>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup x:Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border x:Name="DropDownBorder"
                                        MinWidth="{TemplateBinding ActualWidth}"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <!-- Sidebar navigation item (glass + neon accent) -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="8,2,8,2"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border x:Name="BackgroundBorder"
                                Background="Transparent"
                                BorderBrush="Transparent"
                                BorderThickness="1"
                                CornerRadius="10">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <Rectangle x:Name="AccentBar" Grid.Column="0" Width="3" RadiusX="2" RadiusY="2"
                                           Margin="3,7,9,7" Opacity="0"
                                           Fill="{DynamicResource ToggleButtonOnColor}"/>
                                <ContentPresenter Grid.Column="1" HorizontalAlignment="Left" VerticalAlignment="Center"
                                                  Margin="4,10,14,10"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter TargetName="AccentBar" Property="Opacity" Value="1"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="{DynamicResource AccentGlowOpacity}" ShadowDepth="0" Color="{DynamicResource CAccentGlowColor}" BlurRadius="18"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundDisabledColor}"/>
                                <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundDisabledColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border x:Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse x:Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundDisabledColor}"/>
                                <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundDisabledColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource DangerColor}"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border x:Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox x:Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path x:Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Foreground" Value="{DynamicResource CheckboxMouseOverColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse x:Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse x:Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid x:Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" x:Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse x:Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="Taglia"/>
                                                    <MenuItem Command="Copy" Header="Copia"/>
                                                    <MenuItem Command="Paste" Header="Incolla"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer x:Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="IconToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Opacity" Value="0.75"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Opacity" Value="1"/>
                </Trigger>
                <Trigger Property="IsChecked" Value="True">
                    <Setter Property="Opacity" Value="1"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="IconButtonStyle" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="4,2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Opacity" Value="0.75"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalAlignment" Value="Left"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Opacity" Value="1"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Foreground" Value="{DynamicResource ProgressBarForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ProgressBarBackgroundColor}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border x:Name="PART_Track" CornerRadius="4" Background="{TemplateBinding Background}"/>
                            <Border x:Name="PART_Indicator" CornerRadius="4" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left"/>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DataGridCellStyle" TargetType="DataGridCell">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="4,3"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="DataGridRowStyle" TargetType="DataGridRow">
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Row colors are set by the style (not as attributes) so the selected row trigger can override them -->
        <Style x:Key="ThemedDataGridStyle" TargetType="DataGrid">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="RowBackground" Value="Transparent"/>
            <Setter Property="AlternatingRowBackground" Value="{DynamicResource DataGridAlternatingRowColor}"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="GridLinesVisibility" Value="None"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CellStyle" Value="{StaticResource DataGridCellStyle}"/>
            <Setter Property="RowStyle" Value="{StaticResource DataGridRowStyle}"/>
        </Style>
    </Window.Resources>
    <!-- Glass root -->
    <Border CornerRadius="14" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1">
        <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="{DynamicResource CWindowBackgroundStartColor}" Offset="0"/>
                <GradientStop Color="{DynamicResource CWindowBackgroundEndColor}" Offset="1"/>
            </LinearGradientBrush>
        </Border.Background>
    <Grid Background="Transparent" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="220"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Row="0" Grid.RowSpan="3" Grid.Column="0" Background="{DynamicResource SidebarBackgroundColor}"
                BorderBrush="{DynamicResource BorderColor}" BorderThickness="0,0,1,0">
            <DockPanel LastChildFill="False" Margin="0,0,0,12">
                <!-- Brand -->
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,18,16,16">
                    <Ellipse Width="11" Height="11" Margin="0,0,10,0">
                        <Ellipse.Fill>
                            <RadialGradientBrush>
                                <GradientStop Color="#3DF5A0" Offset="0"/>
                                <GradientStop Color="#1FAE78" Offset="1"/>
                            </RadialGradientBrush>
                        </Ellipse.Fill>
                        <Ellipse.Effect><DropShadowEffect Color="#3DF5A0" BlurRadius="14" ShadowDepth="0" Opacity="0.8"/></Ellipse.Effect>
                    </Ellipse>
                    <TextBlock Text="WinRUtil" FontSize="19" FontWeight="Bold" Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Name="NavLogoPanel" DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,0,16,0"/>
                <!-- Navigation -->
                <StackPanel Name="NavDockPanel" DockPanel.Dock="Top" Orientation="Vertical" Margin="6,6,6,0">
                    <ToggleButton Name="WPFTab7BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7F8;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Sistema" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab1BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE896;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Installa" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab2BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE90F;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Ottimizza" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab3BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xEC7A;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Configura" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab4BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE895;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Aggiornamenti" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab6BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE749;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Stampanti" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab8BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE701;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Wi-Fi" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                    <ToggleButton Name="WPFTab5BT">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE9F9;" FontSize="15" Width="24" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                            <TextBlock Text="Rapporto" FontSize="14" VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </ToggleButton>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Grid.Column="1" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Modalit&#xE0; offline - Nessuna connessione a Internet" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Grid.Column="1" Name="WPFTitleBar" Background="Transparent">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/> <!-- Draggable title area -->
                <ColumnDefinition Width="Auto"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Draggable title area -->
            <StackPanel Grid.Column="0" Orientation="Vertical" VerticalAlignment="Center" Margin="22,10,10,6">
                <TextBlock Name="WPFCurrentTabTitle" Text="Installa" FontSize="17" FontWeight="SemiBold"
                           Foreground="{DynamicResource MainForegroundColor}"/>
                <TextBlock Text="Strumenti per Windows" FontSize="11"
                           Foreground="{DynamicResource MutedForegroundColor}"/>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="Transparent" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,0,0" Width="{DynamicResource SearchBarWidth}" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Left">
                    <Grid>
                        <TextBox
                            Width="{DynamicResource SearchBarWidth}"
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Left"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,46,0"
                            ToolTip="Premi Ctrl-F e digita il nome di un'app per filtrare l'elenco. Premi Esc per azzerare il filtro">
                        </TextBox>
                        <TextBlock
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource MutedForegroundColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                        <Button
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            Name="SearchBarClearButton"
                            Style="{StaticResource SearchBarClearButtonStyle}"
                            Margin="0,0,26,0" Visibility="Collapsed">
                        </Button>
                    </Grid>
                </Border>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="Transparent"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="Cambia il tema dell'interfaccia"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Auto" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Segui il tema di Windows"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Scuro" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usa il tema scuro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Chiaro" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Usa il tema chiaro"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="Transparent"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="Regola la dimensione del testo per l'accessibilit&#xE0;"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="Dimensione testo"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="Piccolo"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="Grande"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="Ripristina"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="Applica"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="Transparent"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Importa" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Importa la configurazione da un file esportato."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Esporta" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="Esporta gli elementi selezionati e copia il comando negli appunti."/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Informazioni" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="Documentazione" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                    Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="Transparent"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,0,0,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="1" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="Transparent" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="Selezioni consigliate:" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" Standard " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" Minima " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" Azzera " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" Rileva ottimizzazioni attive " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        Nota: passa il mouse sopra le voci per una descrizione. Fai attenzione: molte di queste ottimizzazioni modificano profondamente il sistema.
                                        <LineBreak/>Le selezioni consigliate sono pensate per utenti normali: se hai dubbi, NON selezionare altro!
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="Applica ottimizzazioni" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="Annulla ottimizzazioni selezionate" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Impostazioni predefinite"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configurazione predefinita di Windows Update</Run>
                                        <LineBreak/>
                                         - Nessuna modifica ai valori predefiniti di Windows
                                        <LineBreak/>
                                         - Rimuove le impostazioni di aggiornamento personalizzate
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Nota: ripristina le impostazioni di Windows Update ai valori predefiniti di fabbrica. Rimuove QUALSIASI criterio o personalizzazione applicata a Windows Update.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Impostazioni di sicurezza"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">Configurazione di sicurezza bilanciata</Run>
                                        <LineBreak/>
                                         - Aggiornamenti delle funzionalit&#xE0; ritardati di 365 giorni
                                        <LineBreak/>
                                         - Aggiornamenti di sicurezza installati dopo 4 giorni
                                        <LineBreak/>
                                         - Impedisce a Windows Update di installare driver
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">Aggiornamenti funzionalit&#xE0;:</Run> nuove funzionalit&#xE0; e possibili bug
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">Aggiornamenti di sicurezza:</Run> patch di sicurezza critiche
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">Nota: si applica solo ai sistemi Pro che possono usare i criteri di gruppo.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="Disabilita aggiornamenti"
                                            Foreground="{DynamicResource DangerColor}"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="{DynamicResource DangerColor}">!! Sconsigliato !!</Run>
                                        <LineBreak/>
                                         - Disabilita TUTTI gli aggiornamenti di Windows
                                        <LineBreak/>
                                         - Aumenta i rischi per la sicurezza
                                        <LineBreak/>
                                         - Usare solo su sistemi isolati
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">Avviso: senza aggiornamenti di sicurezza il sistema sar&#xE0; vulnerabile.</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Report" Visibility="Collapsed" Name="WPFTab5">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Toolbar -->
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,13" Margin="6,6,6,6">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Orientation="Vertical" VerticalAlignment="Center">
                                <TextBlock Text="Rapporto di intervento" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}"/>
                                <TextBlock Text="Prepara il rapporto da consegnare al cliente: dati del PC, operazioni eseguite con WinRUtil e note."
                                           FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" TextWrapping="Wrap" Margin="0,2,0,0"/>
                            </StackPanel>
                            <Button Grid.Column="1" Name="WPFReportCreate" Content="Crea rapporto" MinWidth="128" Padding="12,0" VerticalAlignment="Center"/>
                        </Grid>
                    </Border>

                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="6,0,6,6">

                            <!-- Intervention details -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="0,2,0,6">
                                <StackPanel>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                        <TextBlock Text="&#xE77B;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                   VerticalAlignment="Center" Margin="0,0,9,0"/>
                                        <TextBlock Text="DATI DELL'INTERVENTO" FontSize="11" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="16"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <Grid.RowDefinitions>
                                            <RowDefinition Height="Auto"/>
                                            <RowDefinition Height="Auto"/>
                                        </Grid.RowDefinitions>
                                        <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,0,12">
                                            <TextBlock Text="Cliente" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,0,4"/>
                                            <TextBox Name="WPFReportCustomer" BorderBrush="{DynamicResource BorderColor}"/>
                                        </StackPanel>
                                        <StackPanel Grid.Row="0" Grid.Column="2" Margin="0,0,0,12">
                                            <TextBlock Text="Tecnico" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,0,4"/>
                                            <TextBox Name="WPFReportTechnician" BorderBrush="{DynamicResource BorderColor}"/>
                                        </StackPanel>
                                        <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,0,12">
                                            <TextBlock Text="Riferimento (n. lavoro, facoltativo)" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,0,4"/>
                                            <TextBox Name="WPFReportReference" BorderBrush="{DynamicResource BorderColor}"/>
                                        </StackPanel>
                                    </Grid>
                                    <TextBlock Text="Intestazione del rapporto (azienda, indirizzo, contatti)" FontSize="12"
                                               Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,0,4"/>
                                    <TextBox Name="WPFReportHeader" BorderBrush="{DynamicResource BorderColor}" AcceptsReturn="True"
                                             TextWrapping="Wrap" Height="74" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                                    <TextBlock Text="Il tecnico e l'intestazione vengono ricordati per i prossimi rapporti." FontSize="11"
                                               Foreground="{DynamicResource MutedForegroundColor}" Margin="0,6,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Operations recorded in this session -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="0,0,0,6">
                                <StackPanel>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                            <TextBlock Text="&#xE9D5;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="OPERAZIONI ESEGUITE IN QUESTA SESSIONE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Button Grid.Column="1" Name="WPFReportClear" Content="Svuota elenco" MinWidth="110" Padding="12,0" VerticalAlignment="Center"/>
                                    </Grid>

                                    <!-- The header row and the item rows share the widths of the time, section and result columns -->
                                    <StackPanel Name="WPFReportActionsTable" Grid.IsSharedSizeScope="True" Visibility="Collapsed">
                                        <Grid Margin="10,0,10,4">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActTime"/>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActArea"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActResult"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="ORA" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="1" Text="CATEGORIA" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="2" Text="OPERAZIONE" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="3" Text="ESITO" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                        </Grid>
                                        <ItemsControl Name="WPFReportActions" AlternationCount="2">
                                            <ItemsControl.ItemTemplate>
                                                <DataTemplate>
                                                    <Border Name="ActRow" CornerRadius="6" Padding="10,6" Background="Transparent">
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActTime"/>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActArea"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="ActResult"/>
                                                            </Grid.ColumnDefinitions>
                                                            <TextBlock Grid.Column="0" Text="{Binding Time}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                                            <TextBlock Grid.Column="1" Text="{Binding Area}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                                            <TextBlock Grid.Column="2" Text="{Binding Text}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,24,0"/>
                                                            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Top">
                                                                <Ellipse Name="ActResultDot" Width="8" Height="8" Fill="{DynamicResource SuccessColor}"
                                                                         VerticalAlignment="Center" Margin="0,0,7,0"/>
                                                                <TextBlock Name="ActResultText" Text="{Binding Result}" FontSize="{DynamicResource FontSize}"
                                                                           FontWeight="SemiBold" Foreground="{DynamicResource SuccessColor}"/>
                                                            </StackPanel>
                                                        </Grid>
                                                    </Border>
                                                    <DataTemplate.Triggers>
                                                        <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                                                            <Setter TargetName="ActRow" Property="Background" Value="{DynamicResource DataGridAlternatingRowColor}"/>
                                                        </Trigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Error">
                                                            <Setter TargetName="ActResultDot" Property="Fill" Value="{DynamicResource DangerColor}"/>
                                                            <Setter TargetName="ActResultText" Property="Foreground" Value="{DynamicResource DangerColor}"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Status}" Value="Info">
                                                            <Setter TargetName="ActResultDot" Property="Fill" Value="{DynamicResource MutedForegroundColor}"/>
                                                            <Setter TargetName="ActResultText" Property="Foreground" Value="{DynamicResource MutedForegroundColor}"/>
                                                        </DataTrigger>
                                                    </DataTemplate.Triggers>
                                                </DataTemplate>
                                            </ItemsControl.ItemTemplate>
                                        </ItemsControl>
                                    </StackPanel>
                                    <TextBlock Name="WPFReportActionsEmpty" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" TextWrapping="Wrap"
                                               Text="Nessuna operazione registrata. Le operazioni fatte con WinRUtil (app installate, ottimizzazioni, riparazioni, stampanti, Wi-Fi) compaiono qui da sole."/>
                                </StackPanel>
                            </Border>

                            <!-- Notes -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="0,0,0,6">
                                <StackPanel>
                                    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                        <TextBlock Text="&#xE70B;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                   VerticalAlignment="Center" Margin="0,0,9,0"/>
                                        <TextBlock Text="NOTE PER IL CLIENTE" FontSize="11" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <TextBox Name="WPFReportNotes" BorderBrush="{DynamicResource BorderColor}" AcceptsReturn="True" TextWrapping="Wrap"
                                             Height="110" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>
                                    <TextBlock Text="Per esempio: lavori fatti a mano, problemi riscontrati, consigli." FontSize="11"
                                               Foreground="{DynamicResource MutedForegroundColor}" Margin="0,6,0,0"/>
                                </StackPanel>
                            </Border>

                            <!-- Status log -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="0,0,0,6">
                                <StackPanel>
                                    <TextBlock Text="Registro attivit&#xE0;" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,6"/>
                                    <TextBox Name="WPFReportLog" IsReadOnly="True" TextWrapping="Wrap" Height="70"
                                             VerticalScrollBarVisibility="Auto" Background="Transparent"
                                             Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                             BorderThickness="1" Padding="6"
                                             Text="Pronto. Compila i dati e clicca 'Crea rapporto'."/>
                                </StackPanel>
                            </Border>

                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="Printers" Visibility="Collapsed" Name="WPFTab6">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Action toolbar -->
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,6,6,6">
                        <StackPanel Orientation="Vertical">
                            <TextBlock Text="Driver stampanti e code" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,2"/>
                            <TextBlock Text="Rileva le stampanti, installa o aggiorna i driver e gestisci lo spooler di stampa."
                                       FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,0,12"/>
                            <WrapPanel Orientation="Horizontal">
                                <Button Name="WPFPrinterRefresh" Content="Aggiorna elenco" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterRestartSpooler" Content="Riavvia spooler" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterClearQueue" Content="Svuota coda di stampa" Width="Auto" MinWidth="160" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterInstallDriver" Content="Installa driver (INF)" Width="Auto" MinWidth="150" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFPrinterRemoveDriver" Content="Rimuovi driver" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                            </WrapPanel>
                        </StackPanel>
                    </Border>

                    <!-- Printer list -->
                    <Border Grid.Row="1" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="8" Margin="6,2,6,6">
                        <DataGrid Name="WPFPrinterList" AutoGenerateColumns="False" IsReadOnly="True"
                                  Style="{StaticResource ThemedDataGridStyle}" CanUserAddRows="False" SelectionMode="Single">
                            <DataGrid.Resources>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Padding" Value="6,4"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                    <Setter Property="HorizontalContentAlignment" Value="Left"/>
                                </Style>
                            </DataGrid.Resources>
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Stampante" Binding="{Binding Name}" Width="2*"/>
                                <DataGridTextColumn Header="Driver" Binding="{Binding Driver}" Width="2*"/>
                                <DataGridTextColumn Header="Porta" Binding="{Binding Port}" Width="*"/>
                                <DataGridTextColumn Header="Stato" Binding="{Binding Status}" Width="Auto"/>
                                <DataGridTextColumn Header="In coda" Binding="{Binding Jobs}" Width="Auto"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Border>

                    <!-- Status log -->
                    <Border Grid.Row="2" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="10" Margin="6,2,6,6">
                        <StackPanel>
                            <TextBlock Text="Registro attivit&#xE0;" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,4"/>
                            <TextBox Name="WPFPrinterStatusLog" IsReadOnly="True" TextWrapping="Wrap" Height="90"
                                     VerticalScrollBarVisibility="Auto" Background="Transparent"
                                     Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                     BorderThickness="1" Padding="6"
                                     Text="Pronto. Clicca 'Aggiorna elenco' per rilevare le stampanti installate."/>
                        </StackPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="System" Visibility="Collapsed" Name="WPFTab7">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Toolbar -->
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,13" Margin="6,6,6,6">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0" Orientation="Vertical" VerticalAlignment="Center">
                                <TextBlock Text="Panoramica del sistema" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}"/>
                                <TextBlock Text="Diagnostica hardware, stato di Windows e attivazione, in tempo reale."
                                           FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,2,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                <Button Name="WPFSystemInfoRefresh" Content="Aggiorna" MinWidth="104" Margin="0,0,8,0" Padding="12,0"/>
                                <Button Name="WPFSystemInfoExport" Content="Esporta report" MinWidth="128" Padding="12,0"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                        <StackPanel Margin="6,0,6,6">

                            <!-- HERO: Windows status -->
                            <Border CornerRadius="16" BorderThickness="1" Margin="0,2,0,6" Padding="22,20">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                                        <GradientStop Color="#243DF5A0" Offset="0"/>
                                        <GradientStop Color="#0C121724" Offset="1"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                                <Border.BorderBrush>
                                    <SolidColorBrush Color="#3D3DF5A0"/>
                                </Border.BorderBrush>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto"/>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>

                                    <!-- Icon disc -->
                                    <Border Grid.Column="0" Width="58" Height="58" CornerRadius="15" Background="#1F3DF5A0"
                                            VerticalAlignment="Top" Margin="0,2,18,0">
                                        <TextBlock Text="&#xE7F8;" FontFamily="Segoe MDL2 Assets" FontSize="27" Foreground="{DynamicResource AccentColor}"
                                                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>

                                    <!-- Edition + build + mini stats -->
                                    <StackPanel Grid.Column="1" VerticalAlignment="Center">
                                        <TextBlock Name="WPFSysOSCaption" Text="Windows" FontSize="22" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap"/>
                                        <TextBlock Name="WPFSysOSBuild" Text="Caricamento in corso..." FontSize="13"
                                                   Foreground="{DynamicResource MutedForegroundColor}" Margin="0,3,0,0"/>
                                        <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
                                            <StackPanel Orientation="Vertical" Margin="0,0,30,0">
                                                <TextBlock Text="NOME PC" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                                <TextBlock Name="WPFSysHostname" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Orientation="Vertical" Margin="0,0,30,0">
                                                <TextBlock Text="ACCESO DA" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                                <TextBlock Name="WPFSysUptime" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel Orientation="Vertical">
                                                <TextBlock Text="INSTALLATO IL" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                                <TextBlock Name="WPFSysInstallDate" Text="-" FontSize="13" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                        </StackPanel>
                                    </StackPanel>

                                    <!-- Activation pill -->
                                    <Border Grid.Column="2" Name="WPFSysActivationPill" CornerRadius="20" Background="#1F3DF5A0"
                                            Padding="15,9" VerticalAlignment="Top" Margin="14,2,0,0">
                                        <StackPanel Orientation="Horizontal">
                                            <Ellipse Name="WPFSysActivationDot" Width="9" Height="9" Fill="{DynamicResource AccentColor}"
                                                     VerticalAlignment="Center" Margin="0,0,8,0"/>
                                            <TextBlock Name="WPFSysActivation" Text="Verifica..." FontSize="13" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MainForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                    </Border>
                                </Grid>
                            </Border>

                            <!-- CARDS -->
                            <WrapPanel Orientation="Horizontal">

                                <!-- Hardware -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE977;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="HARDWARE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Produttore" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysManufacturer" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Modello" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysModel" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="N. di serie" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysSerial" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="BIOS / UEFI" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBios" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Secure Boot" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysSecureBoot" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="TPM" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysTpm" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="BitLocker" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBitLocker" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"
                                                       ToolTip="Stato della crittografia BitLocker dell'unit&#xE0; di sistema"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- CPU -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE950;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="PROCESSORE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysCpuName" Text="-" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Core / Thread" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuCores" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,12">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Frequenza base" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuClock" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,5">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Carico attuale" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysCpuLoad" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource AccentColor}" TextAlignment="Right"/>
                                        </Grid>
                                        <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True">
                                            <Grid Name="WPFSysCpuLoadBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                            </Grid>
                                        </Border>
                                    </StackPanel>
                                </Border>

                                <!-- RAM -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE964;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="MEMORIA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysRamText" Text="-" FontSize="20" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,10"/>
                                        <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True" Margin="0,0,0,12">
                                            <Grid Name="WPFSysRamBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                            </Grid>
                                        </Border>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Disponibile" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysRamFree" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Moduli" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysRamModules" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Storage -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <Grid Margin="0,0,0,14">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                            <StackPanel Grid.Column="0" Orientation="Horizontal">
                                                <TextBlock Text="&#xEDA2;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                           VerticalAlignment="Center" Margin="0,0,9,0"/>
                                                <TextBlock Text="ARCHIVIAZIONE" FontSize="11" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                            </StackPanel>
                                            <TextBlock Grid.Column="1" Name="WPFSysDiskHealth" Text="-" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource AccentColor}" VerticalAlignment="Center"/>
                                        </Grid>
                                        <StackPanel Name="WPFSysDisk0" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk0Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk0Text" Text="-" FontSize="11" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk0Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk1" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk1Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk1Text" Text="-" FontSize="11" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk1Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk2" Visibility="Collapsed" Margin="0,0,0,11">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk2Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk2Text" Text="-" FontSize="11" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk2Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                        <StackPanel Name="WPFSysDisk3" Visibility="Collapsed">
                                            <Grid Margin="0,0,0,4">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                                <TextBlock Grid.Column="0" Name="WPFSysDisk3Label" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource MainForegroundColor}"/>
                                                <TextBlock Grid.Column="1" Name="WPFSysDisk3Text" Text="-" FontSize="11" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            </Grid>
                                            <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True">
                                                <Grid Name="WPFSysDisk3Bar">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                    <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                                </Grid>
                                            </Border>
                                        </StackPanel>
                                    </StackPanel>
                                </Border>

                                <!-- GPU -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="GRAFICA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysGpuName" Text="-" FontSize="13" FontWeight="SemiBold"
                                                   Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Memoria video" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuVram" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Risoluzione" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuResolution" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Driver" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysGpuDriver" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Network -->
                                <Border Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE968;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="RETE" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Scheda" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetAdapter" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" TextWrapping="Wrap" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Indirizzo IPv4" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetIp" Text="-" FontSize="12" FontWeight="SemiBold" Foreground="{DynamicResource AccentColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Indirizzo MAC" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetMac" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Stato" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysNetStatus" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                                <!-- Battery -->
                                <Border Name="WPFSysBatteryCard" Width="330" CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6" Visibility="Collapsed">
                                    <StackPanel>
                                        <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                                            <TextBlock Text="&#xE83F;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="BATTERIA" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <TextBlock Name="WPFSysBatteryCharge" Text="-" FontSize="20" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,10"/>
                                        <Border CornerRadius="4" Height="8" Background="{DynamicResource ProgressBarBackgroundColor}" ClipToBounds="True" Margin="0,0,0,12">
                                            <Grid Name="WPFSysBatteryBar">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="0*"/><ColumnDefinition Width="100*"/></Grid.ColumnDefinitions>
                                                <Border Grid.Column="0" CornerRadius="4" Background="{DynamicResource AccentColor}"/>
                                            </Grid>
                                        </Border>
                                        <Grid Margin="0,0,0,7">
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Stato" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBatteryStatus" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                        <Grid>
                                            <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="Salute (usura)" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"/>
                                            <TextBlock Grid.Column="1" Name="WPFSysBatteryHealth" Text="-" FontSize="12" Foreground="{DynamicResource MainForegroundColor}" TextAlignment="Right" Margin="10,0,0,0"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>

                            </WrapPanel>

                            <!-- Windows Update history: full width so that long update titles stay readable -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="16,14" Margin="6,4,6,6">
                                <StackPanel>
                                    <Grid Margin="0,0,0,12">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                                            <TextBlock Text="&#xE895;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="{DynamicResource AccentColor}"
                                                       VerticalAlignment="Center" Margin="0,0,9,0"/>
                                            <TextBlock Text="AGGIORNAMENTI WINDOWS" FontSize="11" FontWeight="SemiBold"
                                                       Foreground="{DynamicResource MutedForegroundColor}" VerticalAlignment="Center"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                                            <StackPanel Margin="0,0,28,0">
                                                <TextBlock Text="ULTIMA INSTALLAZIONE" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                                <TextBlock Name="WPFSysUpdLastInstall" Text="-" FontSize="12" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                            <StackPanel>
                                                <TextBlock Text="ULTIMA RICERCA" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                                <TextBlock Name="WPFSysUpdLastSearch" Text="-" FontSize="12" FontWeight="SemiBold"
                                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,2,0,0"/>
                                            </StackPanel>
                                        </StackPanel>
                                    </Grid>

                                    <!-- The header row and the item rows share the widths of the date, KB and result columns -->
                                    <StackPanel Name="WPFSysUpdTable" Grid.IsSharedSizeScope="True">
                                        <Grid Margin="10,0,10,4">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdDate"/>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdKb"/>
                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdResult"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="DATA" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="1" Text="AGGIORNAMENTO" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="2" Text="KB" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                            <TextBlock Grid.Column="3" Text="ESITO" FontSize="10" FontWeight="SemiBold" Foreground="{DynamicResource MutedForegroundColor}"/>
                                        </Grid>
                                        <ItemsControl Name="WPFSysUpdList" AlternationCount="2">
                                            <ItemsControl.ItemTemplate>
                                                <DataTemplate>
                                                    <Border Name="UpdRow" CornerRadius="6" Padding="10,6" Background="Transparent">
                                                        <Grid>
                                                            <Grid.ColumnDefinitions>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdDate"/>
                                                                <ColumnDefinition Width="*"/>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdKb"/>
                                                                <ColumnDefinition Width="Auto" SharedSizeGroup="UpdResult"/>
                                                            </Grid.ColumnDefinitions>
                                                            <TextBlock Grid.Column="0" Text="{Binding Date}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MutedForegroundColor}" Margin="0,0,24,0"/>
                                                            <TextBlock Grid.Column="1" Text="{Binding Title}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MainForegroundColor}" TextWrapping="Wrap" Margin="0,0,24,0"/>
                                                            <TextBlock Grid.Column="2" Text="{Binding KB}" FontSize="{DynamicResource FontSize}"
                                                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,24,0"/>
                                                            <StackPanel Grid.Column="3" Orientation="Horizontal" VerticalAlignment="Top">
                                                                <Ellipse Name="UpdResultDot" Width="8" Height="8" Fill="{DynamicResource SuccessColor}"
                                                                         VerticalAlignment="Center" Margin="0,0,7,0"/>
                                                                <TextBlock Name="UpdResultText" Text="{Binding Result}" FontSize="{DynamicResource FontSize}"
                                                                           FontWeight="SemiBold" Foreground="{DynamicResource SuccessColor}"/>
                                                            </StackPanel>
                                                        </Grid>
                                                    </Border>
                                                    <DataTemplate.Triggers>
                                                        <Trigger Property="ItemsControl.AlternationIndex" Value="1">
                                                            <Setter TargetName="UpdRow" Property="Background" Value="{DynamicResource DataGridAlternatingRowColor}"/>
                                                        </Trigger>
                                                        <DataTrigger Binding="{Binding Level}" Value="Warning">
                                                            <Setter TargetName="UpdResultDot" Property="Fill" Value="{DynamicResource WarningColor}"/>
                                                            <Setter TargetName="UpdResultText" Property="Foreground" Value="{DynamicResource WarningColor}"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Level}" Value="Danger">
                                                            <Setter TargetName="UpdResultDot" Property="Fill" Value="{DynamicResource DangerColor}"/>
                                                            <Setter TargetName="UpdResultText" Property="Foreground" Value="{DynamicResource DangerColor}"/>
                                                        </DataTrigger>
                                                        <DataTrigger Binding="{Binding Level}" Value="Muted">
                                                            <Setter TargetName="UpdResultDot" Property="Fill" Value="{DynamicResource MutedForegroundColor}"/>
                                                            <Setter TargetName="UpdResultText" Property="Foreground" Value="{DynamicResource MutedForegroundColor}"/>
                                                        </DataTrigger>
                                                    </DataTemplate.Triggers>
                                                </DataTemplate>
                                            </ItemsControl.ItemTemplate>
                                        </ItemsControl>
                                    </StackPanel>
                                    <TextBlock Name="WPFSysUpdEmpty" Text="Nessun aggiornamento recente trovato." FontSize="12"
                                               Foreground="{DynamicResource MutedForegroundColor}" Visibility="Collapsed"/>
                                </StackPanel>
                            </Border>

                            <!-- Status log -->
                            <Border CornerRadius="14" Background="{DynamicResource GroupBorderBackgroundColor}"
                                    BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,4,6,6">
                                <StackPanel>
                                    <TextBlock Text="Registro attivit&#xE0;" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,6"/>
                                    <TextBox Name="WPFSystemLog" IsReadOnly="True" TextWrapping="Wrap" Height="80"
                                             VerticalScrollBarVisibility="Auto" Background="Transparent"
                                             Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                             BorderThickness="1" Padding="6"
                                             Text="Pronto. Clicca 'Aggiorna' per rilevare le informazioni di sistema."/>
                                </StackPanel>
                            </Border>

                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="WiFi" Visibility="Collapsed" Name="WPFTab8">
                <Grid Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Border Grid.Row="0" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="14,12" Margin="6,6,6,6">
                        <StackPanel Orientation="Vertical">
                            <TextBlock Text="Password Wi-Fi salvate" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,2"/>
                            <TextBlock Text="Recupera le password delle reti Wi-Fi salvate su questo PC, trasferiscile su un altro PC o condividile con un telefono tramite QR code." FontSize="12"
                                       Foreground="{DynamicResource MutedForegroundColor}" TextWrapping="Wrap" Margin="0,0,0,12"/>
                            <WrapPanel Orientation="Horizontal">
                                <Button Name="WPFWifiRefresh" Content="Scansiona reti Wi-Fi" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFWifiCopyAll" Content="Copia tutte" Width="Auto" MinWidth="110" Margin="0,0,8,8" Padding="12,0"/>
                                <Button Name="WPFWifiExport" Content="Esporta profili" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"
                                        ToolTip="Salva tutte le reti Wi-Fi, con le password, in un file .zip da importare su un altro PC"/>
                                <Button Name="WPFWifiImport" Content="Importa profili" Width="Auto" MinWidth="130" Margin="0,0,8,8" Padding="12,0"
                                        ToolTip="Aggiunge a questo PC le reti Wi-Fi di un file .zip esportato da WinRUtil o di file .xml di netsh"/>
                            </WrapPanel>
                        </StackPanel>
                    </Border>
                    <Border Grid.Row="1" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="8" Margin="6,2,6,6">
                        <DataGrid Name="WPFWifiList" AutoGenerateColumns="False" IsReadOnly="True"
                                  Style="{StaticResource ThemedDataGridStyle}" CanUserAddRows="False" SelectionMode="Single">
                            <DataGrid.Resources>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
                                    <Setter Property="Background" Value="Transparent"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="Padding" Value="6,4"/>
                                    <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                    <Setter Property="HorizontalContentAlignment" Value="Left"/>
                                </Style>
                            </DataGrid.Resources>
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Rete (SSID)" Binding="{Binding Ssid}" Width="2*"/>
                                <DataGridTemplateColumn Header="Password" Width="2*">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <Grid VerticalAlignment="Center">
                                                <StackPanel x:Name="WifiSecret" Orientation="Horizontal" VerticalAlignment="Center">
                                                    <ToggleButton x:Name="WifiEye" Style="{StaticResource IconToggleButtonStyle}"
                                                                  Margin="0,0,8,0" ToolTip="Mostra/Nascondi password">
                                                        <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE7B3;" FontSize="14"
                                                                   Foreground="{DynamicResource MainForegroundColor}"/>
                                                    </ToggleButton>
                                                    <TextBlock x:Name="WifiMasked" Text="&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;&#x2022;"
                                                               VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"
                                                               Visibility="Visible"/>
                                                    <TextBlock x:Name="WifiClear" Text="{Binding Password}"
                                                               VerticalAlignment="Center" Foreground="{DynamicResource MainForegroundColor}"
                                                               Visibility="Collapsed"/>
                                                </StackPanel>
                                                <TextBlock x:Name="WifiOpen" Text="Nessuna (rete aperta)" VerticalAlignment="Center"
                                                           Foreground="{DynamicResource MutedForegroundColor}" Visibility="Collapsed"/>
                                            </Grid>
                                            <DataTemplate.Triggers>
                                                <DataTrigger Binding="{Binding IsChecked, ElementName=WifiEye}" Value="True">
                                                    <Setter TargetName="WifiMasked" Property="Visibility" Value="Collapsed"/>
                                                    <Setter TargetName="WifiClear" Property="Visibility" Value="Visible"/>
                                                </DataTrigger>
                                                <DataTrigger Binding="{Binding Password}" Value="">
                                                    <Setter TargetName="WifiSecret" Property="Visibility" Value="Collapsed"/>
                                                    <Setter TargetName="WifiOpen" Property="Visibility" Value="Visible"/>
                                                </DataTrigger>
                                            </DataTemplate.Triggers>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="Sicurezza" Binding="{Binding Security}" Width="*"/>
                                <DataGridTextColumn Header="Auto" Binding="{Binding AutoConnect}" Width="Auto"/>
                                <DataGridTemplateColumn Header="QR" Width="Auto">
                                    <DataGridTemplateColumn.CellTemplate>
                                        <DataTemplate>
                                            <!-- Handled by the Click handler of WPFWifiList in main.ps1, which reads the network from Tag -->
                                            <Button x:Name="WifiQrButton" Uid="WifiQr" Tag="{Binding}" Style="{StaticResource IconButtonStyle}"
                                                    ToolTip="Mostra il QR code per collegare un telefono a questa rete">
                                                <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xED14;" FontSize="15"
                                                           Foreground="{DynamicResource MainForegroundColor}"/>
                                            </Button>
                                            <DataTemplate.Triggers>
                                                <DataTrigger Binding="{Binding CanShare}" Value="False">
                                                    <Setter TargetName="WifiQrButton" Property="Visibility" Value="Collapsed"/>
                                                </DataTrigger>
                                            </DataTemplate.Triggers>
                                        </DataTemplate>
                                    </DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                            </DataGrid.Columns>
                        </DataGrid>
                    </Border>
                    <Border Grid.Row="2" Background="{DynamicResource GroupBorderBackgroundColor}" CornerRadius="12"
                            BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" Padding="10" Margin="6,2,6,6">
                        <StackPanel>
                            <TextBlock Text="Registro attivit&#xE0;" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                       Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,4"/>
                            <TextBox Name="WPFWifiStatusLog" IsReadOnly="True" TextWrapping="Wrap" Height="90"
                                     VerticalScrollBarVisibility="Auto" Background="Transparent"
                                     Foreground="{DynamicResource MainForegroundColor}" BorderBrush="{DynamicResource BorderColor}"
                                     BorderThickness="1" Padding="6"
                                     Text="Pronto. Clicca 'Scansiona reti Wi-Fi' per elencare le reti salvate."/>
                        </StackPanel>
                    </Border>

                    <!-- QR code of the selected network, shown over the tab -->
                    <Border Name="WPFWifiQrOverlay" Grid.Row="0" Grid.RowSpan="3" Visibility="Collapsed" Background="#99000000" CornerRadius="12" Margin="6">
                        <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1"
                                CornerRadius="14" Padding="22,18" Width="340" HorizontalAlignment="Center" VerticalAlignment="Center">
                            <StackPanel>
                                <TextBlock Text="Condividi la rete Wi-Fi" FontSize="{DynamicResource HeaderFontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}"/>
                                <TextBlock Name="WPFWifiQrSsid" FontSize="14" FontWeight="SemiBold" Foreground="{DynamicResource AccentColor}"
                                           TextWrapping="Wrap" Margin="0,6,0,0"/>
                                <TextBlock Name="WPFWifiQrDetails" FontSize="12" Foreground="{DynamicResource MutedForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,2,0,14"/>
                                <Border Background="White" CornerRadius="8" HorizontalAlignment="Center" Padding="6">
                                    <Image Name="WPFWifiQrImage" Width="236" Height="236" Stretch="Uniform" RenderOptions.EdgeMode="Aliased"/>
                                </Border>
                                <TextBlock Text="Inquadra il codice con la fotocamera del telefono: si collega alla rete senza digitare la password."
                                           FontSize="12" Foreground="{DynamicResource MutedForegroundColor}" TextWrapping="Wrap"
                                           TextAlignment="Center" Margin="0,14,0,16"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button Name="WPFWifiQrSave" Content="Salva immagine" Width="Auto" MinWidth="130" Padding="12,0" Margin="0,0,8,0"
                                            ToolTip="Salva il QR code con il nome della rete e la password, pronto da stampare"/>
                                    <Button Name="WPFWifiQrClose" Content="Chiudi" Width="Auto" MinWidth="90" Padding="12,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
    </Border>
</Window>

'@
# Create enums
Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@

# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$debugVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'DebugPreference',$DebugPreference,$Null
$uiVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_NOUI',$PARAM_NOUI,$Null
$offlineVar = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE',$PARAM_OFFLINE,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)
$InitialSessionState.Variables.Add($debugVar)
$InitialSessionState.Variables.Add($uiVar)
$InitialSessionState.Variables.Add($offlineVar)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

class WingetFailedInstall : Exception {
    [string]$additionalData
    WingetFailedInstall($Message) : base($Message) {}
}

class ChocoFailedInstall : Exception {
    [string]$additionalData
    ChocoFailedInstall($Message) : base($Message) {}
}

class GenericException : Exception {
    [string]$additionalData
    GenericException($Message) : base($Message) {}
}

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

Set-Preferences

if ($PARAM_NOUI) {
    Show-WinRUtilLogo
    if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            Invoke-WinUtilAutoRun
        }
        else {
            Write-Host "Did you forget to add '--Run'?";
        }
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
    else {
        Write-Host "Cannot automatically run without a config file provided."
        $sync.runspace.Dispose()
        $sync.runspace.Close()
        [System.GC]::Collect()
        Stop-Transcript
        exit 1
    }
}

$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Now call the function with the final merged config
Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
Initialize-WPFUI -targetGridName "appscategory"

Initialize-WPFUI -targetGridName "appspanel"

Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2

Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2

# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

#Persist Package Manager preference across winutil restarts
$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Choco
    Set-Preferences -save
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = [PackageManagers]::Winget
    Set-Preferences -save
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            $sync["$psitem"].Add_Click({
                [System.Object]$Sender = $args[0]
                Invoke-WPFButton $Sender.name
            })
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                    Write-Debug "Opening: $($Sender.ToolTip)"
                })
            }

        }
    }
}

#===========================================================================
# Setup background config
#===========================================================================

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = $oldProgressPreference
    }

} | Out-Null

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Print the logo
Show-WinRUtilLogo

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Stop-WinUtilSystemLiveUpdate
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" {
            $sync.SearchBar.Text = ""
            if ($sync.WPFWifiQrOverlay.Visibility -eq "Visible") { Invoke-WPFWifiQrClose }
        }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "P" { Invoke-WPFButton "WPFTab6BT"; $keyEventArgs.Handled = $true } # Navigate to Printers tab
            "S" { Invoke-WPFButton "WPFTab7BT"; $keyEventArgs.Handled = $true } # Navigate to System dashboard
            "F" { Invoke-WPFButton "WPFTab8BT"; $keyEventArgs.Handled = $true } # Navigate to Wi-Fi tab
            "R" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Report tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Write-Debug "WinUtil lost focus"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Print the screen size
        Write-Debug "Primary Monitor Width: $screenWidth pixels"
        Write-Debug "Primary Monitor Height: $screenHeight pixels"

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            Write-Debug "The specified width and/or height is greater than the primary monitor size."
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        } else {
            Write-Debug "The specified width and height are within the primary monitor size limits."
        }
    } else {
        Write-Debug "Unable to retrieve information about the primary monitor."
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Connessione a Internet necessaria per installare le applicazioni"

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab7BT"  # Switch to System dashboard instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab7BT"  # Default to System dashboard
    }

    $sync["Form"].Focus()

   if ($PARAM_CONFIG -and -not [string]::IsNullOrWhiteSpace($PARAM_CONFIG)) {
        Write-Host "Running config file tasks..."
        Invoke-WPFImpex -type "import" -Config $PARAM_CONFIG
        if ($PARAM_RUN) {
            Invoke-WinUtilAutoRun
        }
    }

})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

$sync["Form"].Add_Loaded({
    param($e)
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

# WinRUtil brand is rendered in the sidebar header (XAML); no external logo asset injected.
$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")


if (Test-Path "$winutildir\logo.ico") {
    $sync["logorender"] = "$winutildir\logo.ico"
} else {
    $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
}
$sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
$sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Write-Debug "ThemeButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Write-Debug "Dark Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Write-Debug "Light Theme clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Write-Debug "SettingsButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Write-Debug "Import clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Write-Debug "Export clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Write-Debug "About clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $dash = [char]0x2014
    $copyright = [char]0x00A9
    $authorInfo = @"
WinRUtil $dash Windows toolkit
Maintainer : <a href="https://github.com/rtecnocopy89">@rtecnocopy89</a>
GitHub     : <a href="https://github.com/rtecnocopy89/WinRUtil">rtecnocopy89/WinRUtil</a>
Copyright  : $copyright 2026 rtecnocopy89 $dash $copyright 2022 CT Tech Group LLC
Based on   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a> (MIT)
Version    : $($sync.version)
"@
    Show-CustomDialog -Title "Informazioni" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Write-Debug "Documentation clicked"
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://github.com/rtecnocopy89/WinRUtil"
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Write-Debug "FontScalingButton clicked"
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    Write-Debug "FontScalingResetButton clicked"
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    Write-Debug "FontScalingApplyButton clicked"
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# Wi-Fi tab: the QR code button shown in each row of the network list
$sync["WPFWifiList"].AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($list, $clickArgs)
    if ($clickArgs.OriginalSource.Uid -eq "WifiQr") {
        Show-WinUtilWifiQRCode -Network $clickArgs.OriginalSource.Tag
    }
})

$sync["Form"].ShowDialog() | out-null
Stop-Transcript