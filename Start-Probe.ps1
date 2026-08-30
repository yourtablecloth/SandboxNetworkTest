param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SandboxHttp.wsb'),

    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [ValidateRange(1, 65535)]
    [int]$UdpPort = 8081,

    [ValidateRange(10, 300)]
    [int]$StartupTimeoutSeconds = 120,

    [switch]$AttachOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-ProbeRequest {
    param(
        [string]$Uri,
        [int]$TimeoutSeconds = 10
    )

    $result = [ordered]@{
        Uri       = $Uri
        Succeeded = $false
        Response  = $null
        Error     = $null
    }

    try {
        $requestParameters = @{
            Uri        = $Uri
            TimeoutSec = $TimeoutSeconds
        }
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('NoProxy')) {
            $requestParameters.NoProxy = $true
        }

        $result.Response = Invoke-RestMethod @requestParameters
        $result.Succeeded = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Invoke-UdpProbe {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds = 10
    )

    $requestPayload = "sandbox-udp-probe:$([guid]::NewGuid())"
    $result = [ordered]@{
        Host           = $HostName
        Port           = $Port
        Succeeded      = $false
        RequestPayload = $requestPayload
        Response       = $null
        ResponseFrom   = $null
        Error          = $null
    }
    $udpClient = $null

    try {
        $udpClient = [System.Net.Sockets.UdpClient]::new()
        $udpClient.Client.ReceiveTimeout = $TimeoutSeconds * 1000
        $udpClient.Connect($HostName, $Port)

        $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestPayload)
        [void]$udpClient.Send($requestBytes, $requestBytes.Length)

        $remoteEndpoint = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $responseBytes = $udpClient.Receive([ref]$remoteEndpoint)
        $responseText = [System.Text.Encoding]::UTF8.GetString($responseBytes)
        $response = $responseText | ConvertFrom-Json

        if ($response.Protocol -ne 'UDP') {
            throw "Unexpected UDP response protocol: '$($response.Protocol)'."
        }
        if ($response.RequestPayload -ne $requestPayload) {
            throw 'The UDP response did not contain the request payload.'
        }

        $result.Response = $response
        $result.ResponseFrom = $remoteEndpoint.ToString()
        $result.Succeeded = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($udpClient) {
            $udpClient.Dispose()
        }
    }

    return [pscustomobject]$result
}

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimePath = Join-Path $PSScriptRoot 'runtime'
$statusPath = Join-Path $runtimePath 'guest-status.json'
$resultPath = Join-Path $runtimePath 'host-probe-result.json'
$logPath = Join-Path $runtimePath 'guest-listener.log'
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

if (-not $AttachOnly) {
    Remove-Item -LiteralPath $statusPath, $resultPath, $logPath -Force -ErrorAction SilentlyContinue

    Write-Host "Opening Windows Sandbox configuration directly: $resolvedConfigPath"
    Start-Process -FilePath $resolvedConfigPath
}
else {
    Write-Host 'Using the status file from an already running Windows Sandbox session.'
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

$guestIp = $guestStatus.IPv4Address
if (-not ($guestIp -as [System.Net.IPAddress])) {
    throw "The guest did not report a valid IPv4 address: '$guestIp'."
}
if ([int]$guestStatus.Port -ne $Port) {
    throw "The guest TCP port '$($guestStatus.Port)' does not match the requested port '$Port'."
}
if ([int]$guestStatus.UdpPort -ne $UdpPort) {
    throw "The guest UDP port '$($guestStatus.UdpPort)' does not match the requested port '$UdpPort'."
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

$hostNameMatchesGuestIPv4 = $resolvedHostAddresses -contains $guestIp
$ipRequest = Invoke-ProbeRequest -Uri "http://${guestIp}:$Port/health"
$hostNameRequest = Invoke-ProbeRequest -Uri "http://$($guestStatus.ComputerName):$Port/health"
$udpRequest = Invoke-UdpProbe -HostName $guestIp -Port $UdpPort

$testResult = [ordered]@{
    TestedAtUtc          = [DateTimeOffset]::UtcNow.ToString('o')
    LaunchMethod         = if ($AttachOnly) { 'Existing .wsb session' } else { 'Direct .wsb file launch' }
    GuestComputerName   = $guestStatus.ComputerName
    GuestReportedIPv4   = $guestIp
    GuestRuntimePath    = $guestStatus.RuntimePath
    GuestTcpPort        = [int]$guestStatus.Port
    GuestUdpPort        = [int]$guestStatus.UdpPort
    HostResolvedAddress = $resolvedHostAddresses
    HostNameMatchesIPv4 = $hostNameMatchesGuestIPv4
    IpRequest           = $ipRequest
    HostNameRequest     = $hostNameRequest
    UdpRequest          = $udpRequest
    Conclusion          = if (-not $ipRequest.Succeeded -and -not $udpRequest.Succeeded) {
        'Host-to-sandbox TCP/HTTP and UDP requests both failed.'
    }
    elseif (-not $ipRequest.Succeeded) {
        'Host-to-sandbox HTTP over the guest-reported IPv4 address failed.'
    }
    elseif (-not $udpRequest.Succeeded) {
        'Host-to-sandbox HTTP succeeded, but the UDP request failed.'
    }
    elseif ($hostNameMatchesGuestIPv4 -and $hostNameRequest.Succeeded) {
        'The TCP/HTTP, UDP, and host-name requests reached the current sandbox session.'
    }
    else {
        'The TCP/HTTP and UDP requests succeeded, but the host name is not a stable endpoint for the current sandbox session.'
    }
}

$testResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$testResult | ConvertTo-Json -Depth 8
