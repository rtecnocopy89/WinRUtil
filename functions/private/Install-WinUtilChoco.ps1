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
