param(
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidateRange(1, 65535)]
    [int]$UdpPort = 8081,

    [switch]$TestOutboundInternet,

    [string]$RuntimeDirectory,

    [string]$StatusPath,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if (-not $RuntimeDirectory) {
    $desktopDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    $RuntimeDirectory = Join-Path $desktopDirectory 'runtime'
}
if (-not $StatusPath) {
    $StatusPath = Join-Path $RuntimeDirectory 'guest-status.json'
}
if (-not $LogPath) {
    $LogPath = Join-Path $RuntimeDirectory 'guest-listener.log'
}

function Write-ListenerLog {
    param([string]$Message)

    $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message" -Encoding utf8
}

function Get-GuestIPv4Address {
    $defaultRoutes = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric

    foreach ($route in $defaultRoutes) {
        $address = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and
                $_.IPAddress -notlike '169.254.*'
            } |
            Select-Object -First 1 -ExpandProperty IPAddress

        if ($address) {
            return $address
        }
    }

    return Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*'
        } |
        Select-Object -First 1 -ExpandProperty IPAddress
}

function Get-GuestNetworkSnapshot {
    $adapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceDescription, Status, MacAddress, ifIndex
    )
    $addresses = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -ne '127.0.0.1' -and
                $_.IPAddress -notlike '169.254.*'
            } |
            Select-Object -ExpandProperty IPAddress
    )
    $defaultRoutes = @(
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -ne '0.0.0.0' } |
            Select-Object InterfaceIndex, NextHop, RouteMetric, InterfaceMetric
    )

    return [pscustomobject][ordered]@{
        Adapters                     = $adapters
        NonLoopbackIPv4Addresses     = $addresses
        DefaultIPv4Routes            = $defaultRoutes
        HasNonLoopbackIPv4Address    = $addresses.Count -gt 0
        HasDefaultIPv4Route          = $defaultRoutes.Count -gt 0
    }
}

function Test-OutboundInternetTcp {
    param(
        [string]$Address = '1.1.1.1',
        [int]$Port = 443,
        [int]$TimeoutMilliseconds = 3000
    )

    $result = [ordered]@{
        Target    = "${Address}:$Port"
        Connected = $false
        Error     = $null
    }
    $client = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($Address, $Port)
        if (-not $connectTask.Wait($TimeoutMilliseconds)) {
            throw "Timed out after $TimeoutMilliseconds milliseconds."
        }
        if (-not $client.Connected) {
            throw 'The TCP connection did not reach the connected state.'
        }

        $result.Connected = $true
    }
    catch {
        $result.Error = $_.Exception.GetBaseException().Message
    }
    finally {
        if ($client) {
            $client.Dispose()
        }
    }

    return [pscustomobject]$result
}

New-Item -ItemType Directory -Path $RuntimeDirectory -Force | Out-Null
Remove-Item -LiteralPath $StatusPath, $LogPath -Force -ErrorAction SilentlyContinue

try {
    $tcpFirewallRuleName = "Sandbox HTTP probe TCP $Port"
    $udpFirewallRuleName = "Sandbox UDP probe $UdpPort"
    Get-NetFirewallRule -DisplayName $tcpFirewallRuleName, $udpFirewallRuleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -DisplayName $tcpFirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -Profile Any | Out-Null

    New-NetFirewallRule `
        -DisplayName $udpFirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol UDP `
        -LocalPort $UdpPort `
        -Profile Any | Out-Null

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
    $listener.Start()
    $udpListener = [System.Net.Sockets.UdpClient]::new($UdpPort)

    $networkSnapshot = Get-GuestNetworkSnapshot
    $guestAddress = Get-GuestIPv4Address
    $outboundInternetProbe = if ($TestOutboundInternet) {
        Test-OutboundInternetTcp
    }
    else {
        $null
    }
    $status = [ordered]@{
        State                       = 'Listening'
        StartedAtUtc                = [DateTimeOffset]::UtcNow.ToString('o')
        ComputerName                = $env:COMPUTERNAME
        IPv4Address                 = $guestAddress
        Port                        = $Port
        UdpPort                     = $UdpPort
        ProcessId                   = $PID
        RuntimePath                 = $RuntimeDirectory
        NetworkAdapters             = $networkSnapshot.Adapters
        NonLoopbackIPv4Addresses    = $networkSnapshot.NonLoopbackIPv4Addresses
        HasNonLoopbackIPv4Address   = $networkSnapshot.HasNonLoopbackIPv4Address
        DefaultIPv4Routes           = $networkSnapshot.DefaultIPv4Routes
        HasDefaultIPv4Route         = $networkSnapshot.HasDefaultIPv4Route
        OutboundInternetProbe       = $outboundInternetProbe
    }
    $status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusPath -Encoding utf8
    $reportedAddress = if ($guestAddress) { $guestAddress } else { '<none>' }
    Write-ListenerLog "Listening on TCP 0.0.0.0:$Port and UDP 0.0.0.0:$UdpPort as $($status.ComputerName), reported IPv4 $reportedAddress."

    while ($true) {
        $handledRequest = $false

        if ($listener.Pending()) {
            $handledRequest = $true
            $client = $listener.AcceptTcpClient()
            $stream = $null
            $reader = $null

            try {
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 5000
                $stream = $client.GetStream()
                $reader = [System.IO.StreamReader]::new(
                    $stream,
                    [System.Text.Encoding]::ASCII,
                    $false,
                    1024,
                    $true
                )

                $requestLine = $reader.ReadLine()
                while ($null -ne ($headerLine = $reader.ReadLine()) -and $headerLine.Length -gt 0) {
                    # Consume the request headers.
                }

                $remoteEndpoint = $client.Client.RemoteEndPoint.ToString()
                $bodyObject = [ordered]@{
                    Message        = 'Hello from Windows Sandbox'
                    Protocol       = 'TCP/HTTP'
                    ComputerName   = $env:COMPUTERNAME
                    IPv4Address    = Get-GuestIPv4Address
                    Port           = $Port
                    ProcessId      = $PID
                    RequestLine    = $requestLine
                    RemoteEndpoint = $remoteEndpoint
                    RespondedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                }
                $body = $bodyObject | ConvertTo-Json -Compress
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $headers = @(
                    'HTTP/1.1 200 OK'
                    'Content-Type: application/json; charset=utf-8'
                    "Content-Length: $($bodyBytes.Length)"
                    'Connection: close'
                    ''
                    ''
                ) -join "`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)

                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()
                Write-ListenerLog "Responded over TCP to $remoteEndpoint for request '$requestLine'."
            }
            catch {
                Write-ListenerLog "TCP request failed: $($_.Exception.Message)"
            }
            finally {
                if ($reader) {
                    $reader.Dispose()
                }
                if ($stream) {
                    $stream.Dispose()
                }
                $client.Dispose()
            }
        }

        if ($udpListener.Available -gt 0) {
            $handledRequest = $true
            $udpRemoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

            try {
                $requestBytes = $udpListener.Receive([ref]$udpRemoteEndpoint)
                $requestPayload = [System.Text.Encoding]::UTF8.GetString($requestBytes)
                $responseObject = [ordered]@{
                    Message        = 'Hello from Windows Sandbox over UDP'
                    Protocol       = 'UDP'
                    ComputerName   = $env:COMPUTERNAME
                    IPv4Address    = Get-GuestIPv4Address
                    Port           = $UdpPort
                    ProcessId      = $PID
                    RequestPayload = $requestPayload
                    RemoteEndpoint = $udpRemoteEndpoint.ToString()
                    RespondedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                }
                $responseText = $responseObject | ConvertTo-Json -Compress
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes($responseText)
                [void]$udpListener.Send($responseBytes, $responseBytes.Length, $udpRemoteEndpoint)
                Write-ListenerLog "Responded over UDP to $udpRemoteEndpoint for payload '$requestPayload'."
            }
            catch {
                Write-ListenerLog "UDP request failed: $($_.Exception.Message)"
            }
        }

        if (-not $handledRequest) {
            Start-Sleep -Milliseconds 25
        }
    }
}
catch {
    $failure = [ordered]@{
        State        = 'Failed'
        FailedAtUtc  = [DateTimeOffset]::UtcNow.ToString('o')
        ComputerName = $env:COMPUTERNAME
        Port         = $Port
        UdpPort      = $UdpPort
        ProcessId    = $PID
        RuntimePath  = $RuntimeDirectory
        Error        = $_.Exception.ToString()
    }
    $failure | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusPath -Encoding utf8
    Write-ListenerLog "Listener failed: $($_.Exception)"
    throw
}
finally {
    if ($listener) {
        $listener.Stop()
    }
    if ($udpListener) {
        $udpListener.Dispose()
    }
}
