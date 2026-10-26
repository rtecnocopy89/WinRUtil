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
