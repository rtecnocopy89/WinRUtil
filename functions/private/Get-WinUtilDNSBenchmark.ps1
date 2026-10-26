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
