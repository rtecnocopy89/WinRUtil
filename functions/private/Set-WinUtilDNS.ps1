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
