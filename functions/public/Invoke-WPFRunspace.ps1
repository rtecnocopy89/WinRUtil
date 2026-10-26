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
