param(
    [Parameter(Mandatory)]
    [ValidateSet('Standard', 'ProtectedClient')]
    [string]$Mode,

    [ValidateRange(1, 65535)]
    [int]$TcpPort = 18080,

    [ValidateRange(1, 65535)]
    [int]$UdpPort = 18081,

    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'

function Test-HostTcpListener {
    param(
        [string]$HostAddress,
        [int]$Port,
        [int]$TimeoutSeconds,
        [string]$Mode
    )

    $requestPayload = "sandbox-to-host-tcp:${Mode}:$([guid]::NewGuid())"
    $result = [ordered]@{
        Target = "${HostAddress}:$Port"
        RequestPayload = $requestPayload
        Response = $null
        LocalEndpoint = $null
        Succeeded = $false
        Error = $null
    }
    $client = $null
    $stream = $null
    $reader = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($HostAddress, $Port)
        if (-not $connectTask.Wait($TimeoutSeconds * 1000)) {
            throw "TCP connect timed out after $TimeoutSeconds seconds."
        }
        if (-not $client.Connected) {
            throw 'The TCP client did not reach the connected state.'
        }

        $client.ReceiveTimeout = $TimeoutSeconds * 1000
        $client.SendTimeout = $TimeoutSeconds * 1000
        $result.LocalEndpoint = $client.Client.LocalEndPoint.ToString()
        $stream = $client.GetStream()
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes("$requestPayload`n")
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Flush()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
        $responseLine = $reader.ReadLine()
        if (-not $responseLine) {
            throw 'The host TCP listener returned an empty response.'
        }

        $response = $responseLine | ConvertFrom-Json
        $result.Response = $response
        $result.Succeeded =
            $response.Protocol -eq 'TCP' -and
            $response.Mode -eq $Mode -and
            $response.RequestPayload -eq $requestPayload
    }
    catch {
        $result.Error = $_.Exception.GetBaseException().Message
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
        if ($client) {
            $client.Dispose()
        }
    }

    return [pscustomobject]$result
}

function Test-HostUdpListener {
    param(
        [string]$HostAddress,
        [int]$Port,
        [int]$TimeoutSeconds,
        [string]$Mode
    )

    $requestPayload = "sandbox-to-host-udp:${Mode}:$([guid]::NewGuid())"
    $result = [ordered]@{
        Target = "${HostAddress}:$Port"
        RequestPayload = $requestPayload
        Response = $null
        LocalEndpoint = $null
        ResponseFrom = $null
        Succeeded = $false
        Error = $null
    }
    $client = $null

    try {
        $client = [System.Net.Sockets.UdpClient]::new()
        $client.Client.ReceiveTimeout = $TimeoutSeconds * 1000
        $client.Connect($HostAddress, $Port)
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestPayload)
        [void]$client.Send($requestBytes, $requestBytes.Length)
        $result.LocalEndpoint = $client.Client.LocalEndPoint.ToString()

        $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $responseBytes = $client.Receive([ref]$remoteEndpoint)
        $responseText = [System.Text.Encoding]::UTF8.GetString($responseBytes)
        $response = $responseText | ConvertFrom-Json
        $result.ResponseFrom = $remoteEndpoint.ToString()
        $result.Response = $response
        $result.Succeeded =
            $response.Protocol -eq 'UDP' -and
            $response.Mode -eq $Mode -and
            $response.RequestPayload -eq $requestPayload
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

$desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
$runtimePath = Join-Path $desktopPath 'runtime'
$resultFileName = if ($Mode -eq 'Standard') {
    'guest-to-host-standard-guest.json'
}
else {
    'guest-to-host-protected-client-guest.json'
}
$resultPath = Join-Path $runtimePath $resultFileName
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

$defaultRoutes = @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object InterfaceIndex, InterfaceAlias, NextHop, RouteMetric, InterfaceMetric
)
$hostAddress = $defaultRoutes | Select-Object -First 1 -ExpandProperty NextHop
$nonLoopbackAddresses = @(
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object InterfaceIndex, InterfaceAlias, IPAddress, PrefixLength
)

$result = [ordered]@{
    State = 'Running'
    Mode = $Mode
    TestedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    ComputerName = $env:COMPUTERNAME
    HostAddressSource = 'First IPv4 default-route next hop'
    HostAddress = $hostAddress
    DefaultIPv4Routes = $defaultRoutes
    NonLoopbackIPv4Addresses = $nonLoopbackAddresses
    TcpProbe = $null
    UdpProbe = $null
}

try {
    if (-not $hostAddress) {
        throw 'The guest did not have an IPv4 default-route next hop for the host probe.'
    }

    $result.TcpProbe = Test-HostTcpListener -HostAddress $hostAddress -Port $TcpPort -TimeoutSeconds $TimeoutSeconds -Mode $Mode
    $result.UdpProbe = Test-HostUdpListener -HostAddress $hostAddress -Port $UdpPort -TimeoutSeconds $TimeoutSeconds -Mode $Mode
    $result.State = 'Completed'
}
catch {
    $result.State = 'Failed'
    $result.FatalError = $_.Exception.GetBaseException().Message
}
finally {
    $result.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding utf8
}
