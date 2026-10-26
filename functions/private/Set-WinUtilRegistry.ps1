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
