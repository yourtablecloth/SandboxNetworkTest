$ErrorActionPreference = 'Stop'

$desktopPath = [Environment]::GetFolderPath('Desktop')
$guestPath = Join-Path $desktopPath 'guest'
$runtimePath = Join-Path $desktopPath 'runtime'
$sourcePath = Join-Path $guestPath 'WindowsUnixSocketProbe.cs'
$mappedSocketPath = Join-Path $runtimePath 'mapped-af-unix.sock'
$resultPath = Join-Path $runtimePath 'af-unix-guest-result.json'
$localSocketPath = Join-Path $env:TEMP 'sandbox-local-af-unix.sock'

$result = [ordered]@{
    State                       = 'Running'
    TestedAtUtc                 = [DateTimeOffset]::UtcNow.ToString('o')
    ComputerName                = $env:COMPUTERNAME
    DesktopPath                 = $desktopPath
    NetworkingExpectedDisabled  = $true
    NetworkAdapters             = @()
    NonLoopbackIPv4Addresses    = @()
    DefaultIPv4Routes           = @()
    LocalControl                = $null
    MappedSocket                = $null
}

try {
    $result.NetworkAdapters = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceDescription, Status, MacAddress, LinkSpeed
    )
    $result.NonLoopbackIPv4Addresses = @(
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' } |
            Select-Object InterfaceAlias, IPAddress, PrefixLength
    )
    $result.DefaultIPv4Routes = @(
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object InterfaceAlias, NextHop, RouteMetric
    )

    Add-Type -Path $sourcePath

    $localRequest = "guest-local-control:$([guid]::NewGuid())"
    try {
        $localResponse = [WindowsUnixSocketProbe]::RunLocalRoundTrip($localSocketPath, $localRequest)
        $result.LocalControl = [ordered]@{
            SocketPath = $localSocketPath
            Request = $localRequest
            Response = $localResponse
            Succeeded = ($localResponse -eq "local-af-unix-ack:$localRequest")
            Error = $null
        }
    }
    catch {
        $result.LocalControl = [ordered]@{
            SocketPath = $localSocketPath
            Request = $localRequest
            Response = $null
            Succeeded = $false
            Error = $_.Exception.GetBaseException().Message
        }
    }

    $pathVisible = Test-Path -LiteralPath $mappedSocketPath
    $itemEvidence = $null
    $itemError = $null
    if ($pathVisible) {
        try {
            $item = Get-Item -LiteralPath $mappedSocketPath -Force
            $itemEvidence = [ordered]@{
                FullName = $item.FullName
                Attributes = $item.Attributes.ToString()
                Length = $item.Length
                LinkType = $item.LinkType
            }
        }
        catch {
            $itemError = $_.Exception.GetBaseException().Message
        }
    }

    $mappedRequest = "guest-to-host-mapped-path:$([guid]::NewGuid())"
    $connectionJob = Start-Job -ScriptBlock {
        param($ProbeSourcePath, $SocketPath, $Request)

        try {
            Add-Type -Path $ProbeSourcePath
            $response = [WindowsUnixSocketProbe]::ConnectAndExchange($SocketPath, $Request)
            [pscustomobject]@{
                Succeeded = $true
                Response = $response
                Error = $null
            }
        }
        catch {
            [pscustomobject]@{
                Succeeded = $false
                Response = $null
                Error = $_.Exception.GetBaseException().Message
            }
        }
    } -ArgumentList $sourcePath, $mappedSocketPath, $mappedRequest

    $jobCompleted = Wait-Job -Job $connectionJob -Timeout 10
    if ($jobCompleted) {
        $jobResult = Receive-Job -Job $connectionJob
        $connectSucceeded = [bool]$jobResult.Succeeded
        $connectResponse = $jobResult.Response
        $connectError = $jobResult.Error
        $connectTimedOut = $false
    }
    else {
        Stop-Job -Job $connectionJob
        $connectSucceeded = $false
        $connectResponse = $null
        $connectError = 'The mapped-path AF_UNIX connect attempt did not finish within 10 seconds.'
        $connectTimedOut = $true
    }
    Remove-Job -Job $connectionJob -Force

    $result.MappedSocket = [ordered]@{
        GuestPath = $mappedSocketPath
        PathVisible = $pathVisible
        Item = $itemEvidence
        ItemInspectionError = $itemError
        Request = $mappedRequest
        Response = $connectResponse
        ConnectionSucceeded = $connectSucceeded
        TimedOut = $connectTimedOut
        Error = $connectError
    }
    $result.State = 'Completed'
}
catch {
    $result.State = 'Failed'
    $result.FatalError = $_.Exception.GetBaseException().Message
}
finally {
    $result.CompletedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
}
