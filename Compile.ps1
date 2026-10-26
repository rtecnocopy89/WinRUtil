param (
    [switch]$Run,
    [string]$Arguments
)

if ((Get-Item ".\winrutil.ps1" -ErrorAction SilentlyContinue).IsReadOnly) {
    Remove-Item ".\winrutil.ps1" -Force
}

$OFS = "`r`n"
$scriptname = "winrutil.ps1"
$workingdir = $PSScriptRoot

# Read every source file as UTF-8 so Italian accents, em-dashes, arrows and (c) survive
# the bundle even when Compile.ps1 is run under Windows PowerShell 5.1 (whose default
# Get-Content encoding is the ANSI codepage, which would mangle non-ASCII characters).
$PSDefaultParameterValues['Get-Content:Encoding'] = 'utf8'

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.configs = @{}

function Update-Progress {
    param (
        [Parameter(Mandatory, position=0)]
        [string]$StatusMessage,

        [Parameter(Mandatory, position=1)]
        [ValidateRange(0,100)]
        [int]$Percent,

        [Parameter(position=2)]
        [string]$Activity = "Compiling"
    )

    Write-Progress -Activity $Activity -Status $StatusMessage -PercentComplete $Percent
}

# The bundle must be pure ASCII: 'irm | iex' rejects a BOM, while Windows PowerShell 5.1 reads a
# BOM-less local file with the ANSI codepage. Non-ASCII characters in the embedded XML and JSON
# are therefore written as character references / \u escapes, which decode to the same text.
function ConvertTo-XmlCharacterReference {
    param([string]$Text)
    [regex]::Replace($Text, '[\uD800-\uDBFF][\uDC00-\uDFFF]|[^\x00-\x7F]', {
        param($match)
        '&#x{0:X};' -f [char]::ConvertToUtf32($match.Value, 0)
    })
}

function ConvertTo-JsonUnicodeEscape {
    param([string]$Text)
    [regex]::Replace($Text, '[^\x00-\x7F]', {
        param($match)
        '\u{0:x4}' -f [int][char]$match.Value
    })
}

Update-Progress "Pre-req: Running Preprocessor..." 0

# Dot source the 'Invoke-Preprocessing' Function from 'tools/Invoke-Preprocessing.ps1' Script
$preprocessingFilePath = ".\tools\Invoke-Preprocessing.ps1"
. $preprocessingFilePath

$excludedFiles = @()

# Add directories only if they exist
if (Test-Path '.\.git\') { $excludedFiles += '.\.git\' }
if (Test-Path '.\.vs\') { $excludedFiles += '.\.vs\' }
if (Test-Path '.\binary\') { $excludedFiles += '.\binary\' }

# Add files that should always be excluded
$excludedFiles += @(
    '.\.gitignore',
    '.\.gitattributes',
    '.\.github\CODEOWNERS',
    '.\LICENSE',
    "$preprocessingFilePath",
    '*.png',
    '.\.preprocessor_hashes.json'
)

$msg = "Pre-req: Code Formatting"
Invoke-Preprocessing -WorkingDir "$workingdir" -ExcludedFiles $excludedFiles -ProgressStatusMessage $msg

# Create the script in memory.
Update-Progress "Pre-req: Allocating Memory" 0
$script_content = [System.Collections.Generic.List[string]]::new()

Update-Progress "Adding: Version" 10
$script_content.Add($(Get-Content "scripts\start.ps1").replace('#{replaceme}',"$(Get-Date -Format yy.MM.dd)"))

Update-Progress "Adding: Functions" 20
Get-ChildItem "functions" -Recurse -File | ForEach-Object {
    $script_content.Add($(Get-Content $psitem.FullName))
    }
Update-Progress "Adding: Config *.json" 40
Get-ChildItem "config" | Where-Object {$psitem.extension -eq ".json"} | ForEach-Object {
    $json = (Get-Content $psitem.FullName -Raw)
    $jsonAsObject = $json | ConvertFrom-Json

    # Add 'WPFInstall' as a prefix to every entry-name in 'applications.json' file
    if ($psitem.Name -eq "applications.json") {
        foreach ($appEntryName in $jsonAsObject.PSObject.Properties.Name) {
            $appEntryContent = $jsonAsObject.$appEntryName
            $jsonAsObject.PSObject.Properties.Remove($appEntryName)
            $jsonAsObject | Add-Member -MemberType NoteProperty -Name "WPFInstall$appEntryName" -Value $appEntryContent
        }
    }

    # Line 90 requires no whitespace inside the here-strings, to keep formatting of the JSON in the final script.
    $json = @"
$($jsonAsObject | ConvertTo-Json -Depth 3)
"@
    $json = ConvertTo-JsonUnicodeEscape $json

    $sync.configs.$($psitem.BaseName) = $json | ConvertFrom-Json
    $script_content.Add($(Write-Output "`$sync.configs.$($psitem.BaseName) = @'`r`n$json`r`n'@ `| ConvertFrom-Json" ))
}

# Read the entire XAML file as a single string, preserving line breaks
$xaml = ConvertTo-XmlCharacterReference (Get-Content "$workingdir\xaml\inputXML.xaml" -Raw)

Update-Progress "Adding: Xaml " 90

# Add the XAML content to $script_content using a here-string
$script_content.Add(@"
`$inputXML = @'
$xaml
'@
"@)

$script_content.Add($(Get-Content "scripts\main.ps1"))

Update-Progress "Removing temporary files" 99
Remove-Item "xaml\inputApp.xaml" -ErrorAction SilentlyContinue
Remove-Item "xaml\inputTweaks.xaml" -ErrorAction SilentlyContinue
Remove-Item "xaml\inputFeatures.xaml" -ErrorAction SilentlyContinue

# Write WITHOUT BOM: a BOM survives `irm | iex` as a literal U+FEFF character at the start of the
# string and breaks parsing (the opening <# is seen as the token '<U+FEFF><#').
# The content is pure ASCII (checked below), so irm, Windows PowerShell 5.1 and PowerShell 7 all read it the same way.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path $workingdir $scriptname), ($script_content -join "`r`n"), $utf8NoBom)
Write-Progress -Activity "Compiling" -Completed

Update-Progress -Activity "Validating" -StatusMessage "Checking winrutil.ps1 Encoding" -Percent 0
$nonAsciiLines = @(Select-String -LiteralPath (Join-Path $workingdir $scriptname) -Pattern '[^\x00-\x7F]' -CaseSensitive -Encoding utf8)
if ($nonAsciiLines.Count -gt 0) {
    Write-Warning "winrutil.ps1 must be pure ASCII. In PowerShell code write non-ASCII characters with [char] codes, e.g. `$([char]0x00E8). Found on:"
    $nonAsciiLines | Select-Object -First 10 | ForEach-Object { Write-Host "  line $($_.LineNumber): $($_.Line.Trim())" -ForegroundColor Red }
    exit 1
}

Update-Progress -Activity "Validating" -StatusMessage "Checking winrutil.ps1 Syntax" -Percent 0
try {
    Get-Command -Syntax .\winrutil.ps1 | Out-Null
} catch {
    Write-Warning "Syntax Validation for 'winrutil.ps1' has failed"
    Write-Host "$($Error[0])" -ForegroundColor Red
    exit 1
}
Write-Progress -Activity "Validating" -Completed

if ($run) {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    .\winrutil.ps1 $Arguments
    break
}
