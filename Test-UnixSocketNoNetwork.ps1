param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SandboxUnixSocket-NoNetwork.wsb'),

    [ValidateRange(10, 300)]
    [int]$StartupTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$runtimePath = Join-Path $PSScriptRoot 'runtime'
$sourcePath = Join-Path $PSScriptRoot 'guest\WindowsUnixSocketProbe.cs'
$serverScriptPath = Join-Path $PSScriptRoot 'Start-UnixSocketServer.ps1'
$socketPath = Join-Path $runtimePath 'mapped-af-unix.sock'
$readyPath = Join-Path $runtimePath 'af-unix-host-ready.txt'
$transcriptPath = Join-Path $runtimePath 'af-unix-host-transcript.txt'
$guestResultPath = Join-Path $runtimePath 'af-unix-guest-result.json'
$resultPath = Join-Path $runtimePath 'af-unix-no-network-result.json'
$serverStdoutPath = Join-Path $runtimePath 'af-unix-host-server.stdout.log'
$serverStderrPath = Join-Path $runtimePath 'af-unix-host-server.stderr.log'
$serverProcess = $null

New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

$activeSandboxSessions = @(
    Get-Process -Name 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue
)
if ($activeSandboxSessions.Count -gt 0) {
    $processIds = ($activeSandboxSessions.Id -join ', ')
    throw "Close the currently running Windows Sandbox session before this test. Active WindowsSandboxRemoteSession PID: $processIds"
}

$cleanupPaths = @(
    $socketPath,
    $readyPath,
    $transcriptPath,
    $guestResultPath,
    $resultPath,
    $serverStdoutPath,
    $serverStderrPath
)
Remove-Item -LiteralPath $cleanupPaths -Force -ErrorAction SilentlyContinue

try {
    $serverArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$serverScriptPath`"",
        '-SourcePath',
        "`"$sourcePath`"",
        '-SocketPath',
        "`"$socketPath`"",
        '-ReadyPath',
        "`"$readyPath`"",
        '-TranscriptPath',
        "`"$transcriptPath`""
    )

    $serverProcess = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList $serverArguments `
        -WindowStyle Hidden `
        -RedirectStandardOutput $serverStdoutPath `
        -RedirectStandardError $serverStderrPath `
        -PassThru

    $serverReadyDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ([DateTimeOffset]::UtcNow -lt $serverReadyDeadline) {
        if (Test-Path -LiteralPath $readyPath) {
            break
        }
        if ($serverProcess.HasExited) {
            $serverError = if (Test-Path -LiteralPath $serverStderrPath) {
                Get-Content -LiteralPath $serverStderrPath -Raw
            }
            else {
                'No error output was captured.'
            }
            throw "The host AF_UNIX server exited before becoming ready. $serverError"
        }
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-Path -LiteralPath $readyPath)) {
        throw 'The host AF_UNIX server did not become ready within 10 seconds.'
    }

    $hostSocketItem = Get-Item -LiteralPath $socketPath -Force
    $hostSocketEvidence = [ordered]@{
        FullName = $hostSocketItem.FullName
        Attributes = $hostSocketItem.Attributes.ToString()
        Length = $hostSocketItem.Length
        LinkType = $hostSocketItem.LinkType
    }

    Write-Host "Opening network-disabled AF_UNIX Windows Sandbox configuration: $resolvedConfigPath"
    Start-Process -FilePath $resolvedConfigPath

    $guestDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $guestResult = $null
    while ([DateTimeOffset]::UtcNow -lt $guestDeadline) {
        if (Test-Path -LiteralPath $guestResultPath) {
            try {
                $guestResult = Get-Content -LiteralPath $guestResultPath -Raw | ConvertFrom-Json
            }
            catch {
                $guestResult = $null
            }
        }
        if ($guestResult -and $guestResult.State -in @('Completed', 'Failed')) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    if (-not $guestResult) {
        throw "The guest AF_UNIX result did not arrive within $StartupTimeoutSeconds seconds."
    }
    if ($guestResult.State -eq 'Failed') {
        throw "The guest AF_UNIX test failed: $($guestResult.FatalError)"
    }

    Start-Sleep -Milliseconds 500
    $hostAcceptedConnection = Test-Path -LiteralPath $transcriptPath
    $hostReceivedRequest = if ($hostAcceptedConnection) {
        Get-Content -LiteralPath $transcriptPath -Raw
    }
    else {
        $null
    }

    $networkRemainedDisabled =
        @($guestResult.NetworkAdapters).Count -eq 0 -and
        @($guestResult.NonLoopbackIPv4Addresses).Count -eq 0 -and
        @($guestResult.DefaultIPv4Routes).Count -eq 0
    $localControlSucceeded = [bool]$guestResult.LocalControl.Succeeded
    $crossKernelConnectionSucceeded = [bool]$guestResult.MappedSocket.ConnectionSucceeded
    $expectedIsolationObserved =
        $networkRemainedDisabled -and
        $localControlSucceeded -and
        -not $crossKernelConnectionSucceeded -and
        -not $hostAcceptedConnection

    $testResult = [ordered]@{
        TestedAtUtc                    = [DateTimeOffset]::UtcNow.ToString('o')
        LaunchMethod                   = 'Direct network-disabled .wsb file launch'
        Configuration                  = $resolvedConfigPath
        Networking                     = 'Disable'
        HostSocket                     = $hostSocketEvidence
        Guest                          = $guestResult
        HostAcceptedConnection         = $hostAcceptedConnection
        HostReceivedRequest            = $hostReceivedRequest
        NetworkRemainedDisabled        = $networkRemainedDisabled
        LocalAfUnixControlSucceeded    = $localControlSucceeded
        CrossKernelConnectionSucceeded = $crossKernelConnectionSucceeded
        ExpectedIsolationObserved      = $expectedIsolationObserved
        Conclusion                     = if ($expectedIsolationObserved) {
            'AF_UNIX worked inside the guest kernel, but the socket reparse point in a mapped folder did not bridge the host and Sandbox kernels.'
        }
        else {
            'The observed result differed from the expected host-guest AF_UNIX isolation behavior.'
        }
    }

    $testResult | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding utf8
    $testResult | ConvertTo-Json -Depth 10

    if (-not $expectedIsolationObserved) {
        throw 'The AF_UNIX isolation checks did not produce the expected control and cross-kernel results.'
    }
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
    Remove-Item -LiteralPath $socketPath -Force -ErrorAction SilentlyContinue
}
