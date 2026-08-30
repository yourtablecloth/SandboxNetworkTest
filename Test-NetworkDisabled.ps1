param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SandboxHttp-NoNetwork.wsb'),

    [ValidateRange(1, 65535)]
    [int]$TcpPort = 8080,

    [ValidateRange(1, 65535)]
    [int]$UdpPort = 8081,

    [ValidateRange(10, 300)]
    [int]$StartupTimeoutSeconds = 120,

    [ValidateRange(1, 30)]
    [int]$ProbeTimeoutSeconds = 5,

    [switch]$AttachOnly
)

$ErrorActionPreference = 'Stop'

function Test-HostTcpProbe {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $result = [ordered]@{
        Target    = "${TargetHost}:$Port"
        Connected = $false
        Blocked   = $true
        Error     = $null
    }
    $client = $null

    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($TargetHost, $Port)
        if (-not $connectTask.Wait($TimeoutSeconds * 1000)) {
            throw "Timed out after $TimeoutSeconds seconds."
        }
        if (-not $client.Connected) {
            throw 'The TCP connection did not reach the connected state.'
        }

        $result.Connected = $true
        $result.Blocked = $false
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

function Test-HostUdpProbe {
    param(
        [string]$TargetHost,
        [int]$Port,
        [int]$TimeoutSeconds
    )

    $requestPayload = "sandbox-disabled-udp-probe:$([guid]::NewGuid())"
    $result = [ordered]@{
        Target           = "${TargetHost}:$Port"
        RequestPayload   = $requestPayload
        ResponseReceived = $false
        Blocked          = $true
        ResponseFrom     = $null
        Error            = $null
    }
    $client = $null

    try {
        $client = [System.Net.Sockets.UdpClient]::new()
        $client.Client.ReceiveTimeout = $TimeoutSeconds * 1000
        $client.Connect($TargetHost, $Port)
        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestPayload)
        [void]$client.Send($requestBytes, $requestBytes.Length)

        $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        [void]$client.Receive([ref]$remoteEndpoint)
        $result.ResponseReceived = $true
        $result.Blocked = $false
        $result.ResponseFrom = $remoteEndpoint.ToString()
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

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimePath = Join-Path $PSScriptRoot 'runtime'
$statusPath = Join-Path $runtimePath 'guest-status.json'
$listenerLogPath = Join-Path $runtimePath 'guest-listener.log'
$enabledResultPath = Join-Path $runtimePath 'host-probe-result.json'
$enabledBaselinePath = Join-Path $runtimePath 'network-enabled-result.json'
$resultPath = Join-Path $runtimePath 'network-disabled-result.json'
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

if (-not $AttachOnly) {
    if (Test-Path -LiteralPath $enabledResultPath) {
        Copy-Item -LiteralPath $enabledResultPath -Destination $enabledBaselinePath -Force
    }
    Remove-Item -LiteralPath $statusPath, $listenerLogPath, $resultPath -Force -ErrorAction SilentlyContinue

    Write-Host "Opening network-disabled Windows Sandbox configuration: $resolvedConfigPath"
    Start-Process -FilePath $resolvedConfigPath
}
else {
    Write-Host 'Using the status file from an already running network-disabled Sandbox session.'
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
$guestStatus = $null

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $statusPath) {
        try {
            $guestStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        }
        catch {
            $guestStatus = $null
        }
    }

    if ($guestStatus -and $guestStatus.State -eq 'Listening') {
        break
    }
    if ($guestStatus -and $guestStatus.State -eq 'Failed') {
        throw "The guest listener failed: $($guestStatus.Error)"
    }

    Start-Sleep -Milliseconds 500
}

if (-not $guestStatus -or $guestStatus.State -ne 'Listening') {
    throw "The guest listener did not become ready within $StartupTimeoutSeconds seconds."
}

$resolvedHostAddresses = @()
try {
    $resolvedHostAddresses = @(
        [System.Net.Dns]::GetHostAddresses($guestStatus.ComputerName) |
            ForEach-Object { $_.ToString() }
    )
}
catch {
    $resolvedHostAddresses = @()
}

$tcpProbe = Test-HostTcpProbe -TargetHost $guestStatus.ComputerName -Port $TcpPort -TimeoutSeconds $ProbeTimeoutSeconds
$udpProbe = Test-HostUdpProbe -TargetHost $guestStatus.ComputerName -Port $UdpPort -TimeoutSeconds $ProbeTimeoutSeconds
$hasNonLoopbackIPv4 = [bool]$guestStatus.HasNonLoopbackIPv4Address
$hasDefaultIPv4Route = [bool]$guestStatus.HasDefaultIPv4Route
$outboundInternetConnected = [bool]$guestStatus.OutboundInternetProbe.Connected
$networkIsolationConfirmed =
    -not $hasNonLoopbackIPv4 -and
    -not $hasDefaultIPv4Route -and
    -not $outboundInternetConnected -and
    $tcpProbe.Blocked -and
    $udpProbe.Blocked

$testResult = [ordered]@{
    TestedAtUtc                  = [DateTimeOffset]::UtcNow.ToString('o')
    LaunchMethod                 = if ($AttachOnly) { 'Existing network-disabled .wsb session' } else { 'Direct network-disabled .wsb file launch' }
    GuestComputerName            = $guestStatus.ComputerName
    GuestNetworkAdapters         = @($guestStatus.NetworkAdapters)
    GuestNonLoopbackIPv4         = @($guestStatus.NonLoopbackIPv4Addresses)
    GuestHasNonLoopbackIPv4      = $hasNonLoopbackIPv4
    GuestDefaultIPv4Routes       = @($guestStatus.DefaultIPv4Routes)
    GuestHasDefaultIPv4Route     = $hasDefaultIPv4Route
    GuestOutboundInternetProbe   = $guestStatus.OutboundInternetProbe
    HostResolvedAddress          = $resolvedHostAddresses
    HostTcpProbeByComputerName   = $tcpProbe
    HostUdpProbeByComputerName   = $udpProbe
    MappedFolderStatusReceived   = $true
    NetworkIsolationConfirmed    = $networkIsolationConfirmed
    Conclusion                   = if ($networkIsolationConfirmed) {
        'Networking Disable removed usable guest networking; outbound Internet and host TCP/UDP probing were unavailable.'
    }
    else {
        'The observed evidence did not confirm complete guest network isolation.'
    }
}

$testResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$testResult | ConvertTo-Json -Depth 8

if (-not $networkIsolationConfirmed) {
    throw 'The network-disabled isolation checks did not all pass.'
}
