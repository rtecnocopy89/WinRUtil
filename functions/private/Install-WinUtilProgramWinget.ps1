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
