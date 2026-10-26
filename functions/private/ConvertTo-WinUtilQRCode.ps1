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
