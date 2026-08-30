param(
    [ValidateRange(10, 300)]
    [int]$StartupTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

function Stop-TestSandboxSession {
    $remoteSessions = @(Get-Process -Name 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue)
    if ($remoteSessions.Count -gt 1) {
        throw "Expected at most one Windows Sandbox session, found $($remoteSessions.Count)."
    }

    if ($remoteSessions.Count -eq 1) {
        $session = $remoteSessions[0]
        if ([IO.Path]::GetFileName($session.Path) -ne 'WindowsSandboxRemoteSession.exe') {
            throw 'The running process path does not identify WindowsSandboxRemoteSession.exe.'
        }
        Stop-Process -Id $session.Id -Force
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(
            Get-Process -Name 'WindowsSandboxRemoteSession', 'WindowsSandboxServer' -ErrorAction SilentlyContinue
        )
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'The Windows Sandbox test session did not stop within 30 seconds.'
}

function Get-NodeFirewallEvidence {
    param(
        [string]$NodePath,
        [int]$TcpPort,
        [int]$UdpPort
    )

    $evidence = @(
        Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop |
            Where-Object {
                $_.Enabled -eq 'True' -and
                $_.Direction -eq 'Inbound' -and
                $_.Action -eq 'Allow'
            } |
            ForEach-Object {
                $rule = $_
                $application = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
                if ($application.Program -and $application.Program -ieq $NodePath) {
                    $port = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
                    [pscustomobject][ordered]@{
                        Name = $rule.Name
                        DisplayName = $rule.DisplayName
                        Profile = $rule.Profile.ToString()
                        Program = $application.Program
                        Protocol = $port.Protocol.ToString()
                        LocalPort = $port.LocalPort.ToString()
                    }
                }
            }
    )

    $tcpAllowed = [bool]($evidence | Where-Object {
        $_.Protocol -in @('Any', 'TCP', '6') -and
        $_.LocalPort -in @('Any', $TcpPort.ToString()) -and
        ($_.Profile -match 'Public|Any')
    })
    $udpAllowed = [bool]($evidence | Where-Object {
        $_.Protocol -in @('Any', 'UDP', '17') -and
        $_.LocalPort -in @('Any', $UdpPort.ToString()) -and
        ($_.Profile -match 'Public|Any')
    })

    return [pscustomobject][ordered]@{
        Rules = $evidence
        TcpAllowed = $tcpAllowed
        UdpAllowed = $udpAllowed
    }
}

function Invoke-ListenerModeTest {
    param(
        [ValidateSet('Standard', 'ProtectedClient')]
        [string]$Mode,
        [string]$ConfigPath,
        [string]$NodePath,
        [string]$ListenerScriptPath,
        [string]$RuntimePath,
        [int]$TcpPort,
        [int]$UdpPort,
        [int]$StartupTimeoutSeconds
    )

    $modeSlug = if ($Mode -eq 'Standard') { 'standard' } else { 'protected-client' }
    $readyPath = Join-Path $RuntimePath "guest-to-host-$modeSlug-host-ready.json"
    $hostResultPath = Join-Path $RuntimePath "guest-to-host-$modeSlug-host.json"
    $guestResultPath = Join-Path $RuntimePath "guest-to-host-$modeSlug-guest.json"
    $stdoutPath = Join-Path $RuntimePath "guest-to-host-$modeSlug-host.stdout.log"
    $stderrPath = Join-Path $RuntimePath "guest-to-host-$modeSlug-host.stderr.log"
    $listenerProcess = $null
    $sandboxStarted = $false

    Remove-Item -LiteralPath @(
        $readyPath,
        $hostResultPath,
        $guestResultPath,
        $stdoutPath,
        $stderrPath
    ) -Force -ErrorAction SilentlyContinue

    try {
        $listenerArguments = @(
            "`"$ListenerScriptPath`"",
            '--mode',
            $Mode,
            '--tcp-port',
            $TcpPort.ToString(),
            '--udp-port',
            $UdpPort.ToString(),
            '--ready-path',
            "`"$readyPath`"",
            '--result-path',
            "`"$hostResultPath`""
        )
        $listenerProcess = Start-Process -FilePath $NodePath `
            -ArgumentList $listenerArguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru

        $listenerDeadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
        while ([DateTimeOffset]::UtcNow -lt $listenerDeadline) {
            if (Test-Path -LiteralPath $readyPath) {
                break
            }
            if ($listenerProcess.HasExited) {
                $errorText = if (Test-Path -LiteralPath $stderrPath) {
                    Get-Content -LiteralPath $stderrPath -Raw
                }
                else {
                    'No listener error output was captured.'
                }
                throw "The $Mode host listener exited before becoming ready. $errorText"
            }
            Start-Sleep -Milliseconds 100
        }
        if (-not (Test-Path -LiteralPath $readyPath)) {
            throw "The $Mode host listeners did not become ready within 10 seconds."
        }

        Write-Host "Opening $Mode Windows Sandbox configuration: $ConfigPath"
        Start-Process -FilePath $ConfigPath
        $sandboxStarted = $true

        $resultDeadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        $guestResult = $null
        $hostResult = $null
        while ([DateTimeOffset]::UtcNow -lt $resultDeadline) {
            if (-not $guestResult -and (Test-Path -LiteralPath $guestResultPath)) {
                try {
                    $guestResult = Get-Content -LiteralPath $guestResultPath -Raw | ConvertFrom-Json
                }
                catch {
                    $guestResult = $null
                }
            }
            if (-not $hostResult -and (Test-Path -LiteralPath $hostResultPath)) {
                try {
                    $hostResult = Get-Content -LiteralPath $hostResultPath -Raw | ConvertFrom-Json
                }
                catch {
                    $hostResult = $null
                }
            }
            if ($guestResult -and $hostResult) {
                break
            }
            Start-Sleep -Milliseconds 250
        }

        if (-not $guestResult) {
            throw "The $Mode guest probe result did not arrive within $StartupTimeoutSeconds seconds."
        }
        if (-not $hostResult) {
            throw "The $Mode host listener result did not arrive within $StartupTimeoutSeconds seconds."
        }

        $tcpSucceeded =
            [bool]$guestResult.TcpProbe.Succeeded -and
            $null -ne $hostResult.TcpRequest
        $udpSucceeded =
            [bool]$guestResult.UdpProbe.Succeeded -and
            $null -ne $hostResult.UdpRequest
        $modeSucceeded =
            $guestResult.State -eq 'Completed' -and
            $hostResult.State -eq 'Completed' -and
            $tcpSucceeded -and
            $udpSucceeded

        return [pscustomobject][ordered]@{
            Mode = $Mode
            ConfigPath = $ConfigPath
            ProtectedClientConfigured = ($Mode -eq 'ProtectedClient')
            HostAddress = $guestResult.HostAddress
            GuestIPv4Addresses = @($guestResult.NonLoopbackIPv4Addresses)
            TcpSucceeded = $tcpSucceeded
            UdpSucceeded = $udpSucceeded
            Succeeded = $modeSucceeded
            GuestResult = $guestResult
            HostResult = $hostResult
        }
    }
    finally {
        if ($listenerProcess -and -not $listenerProcess.HasExited) {
            Stop-Process -Id $listenerProcess.Id -Force
            $listenerProcess.WaitForExit()
        }
        if ($sandboxStarted) {
            Stop-TestSandboxSession
        }
    }
}

$runtimePath = Join-Path $PSScriptRoot 'runtime'
$listenerScriptPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'Start-HostTcpUdpListener.mjs')).Path
$standardConfigPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'SandboxHostListeners.wsb')).Path
$protectedConfigPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'SandboxHostListeners-ProtectedClient.wsb')).Path
$comparisonPath = Join-Path $runtimePath 'guest-to-host-comparison.json'
$nodePath = (Get-Command 'node.exe' -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

$activeSandboxSessions = @(Get-Process -Name 'WindowsSandboxRemoteSession' -ErrorAction SilentlyContinue)
if ($activeSandboxSessions.Count -gt 0) {
    throw 'Close the currently running Windows Sandbox session before starting the two-mode comparison.'
}

[xml]$standardConfig = Get-Content -LiteralPath $standardConfigPath -Raw
[xml]$protectedConfig = Get-Content -LiteralPath $protectedConfigPath -Raw
if ($standardConfig.Configuration.Networking -ne 'Enable' -or $standardConfig.Configuration.ProtectedClient) {
    throw 'The standard comparison configuration must enable Networking and omit ProtectedClient.'
}
if ($protectedConfig.Configuration.Networking -ne 'Enable' -or $protectedConfig.Configuration.ProtectedClient -ne 'Enable') {
    throw 'The protected comparison configuration must enable Networking and ProtectedClient.'
}
if (@($standardConfig.SelectNodes('//SandboxFolder')).Count -ne 0 -or @($protectedConfig.SelectNodes('//SandboxFolder')).Count -ne 0) {
    throw 'The reverse-probe configurations must omit SandboxFolder elements.'
}

$standardCommand = [string]$standardConfig.Configuration.LogonCommand.Command
$protectedCommand = [string]$protectedConfig.Configuration.LogonCommand.Command
$standardTcpPortMatch = [regex]::Match($standardCommand, '(?i)-TcpPort\s+(\d+)')
$standardUdpPortMatch = [regex]::Match($standardCommand, '(?i)-UdpPort\s+(\d+)')
$protectedTcpPortMatch = [regex]::Match($protectedCommand, '(?i)-TcpPort\s+(\d+)')
$protectedUdpPortMatch = [regex]::Match($protectedCommand, '(?i)-UdpPort\s+(\d+)')
if (-not $standardTcpPortMatch.Success -or -not $standardUdpPortMatch.Success -or
    -not $protectedTcpPortMatch.Success -or -not $protectedUdpPortMatch.Success) {
    throw 'Both reverse-probe configurations must specify TcpPort and UdpPort in LogonCommand.'
}
$TcpPort = [int]$standardTcpPortMatch.Groups[1].Value
$UdpPort = [int]$standardUdpPortMatch.Groups[1].Value
if ($TcpPort -ne [int]$protectedTcpPortMatch.Groups[1].Value -or
    $UdpPort -ne [int]$protectedUdpPortMatch.Groups[1].Value) {
    throw 'The standard and Protected Client configurations must use the same TCP and UDP ports.'
}

$firewallEvidence = Get-NodeFirewallEvidence -NodePath $nodePath -TcpPort $TcpPort -UdpPort $UdpPort
if (-not $firewallEvidence.TcpAllowed -or -not $firewallEvidence.UdpAllowed) {
    throw 'The selected Node.js host listener does not have active Public-profile inbound allow rules for both TCP and UDP.'
}

Remove-Item -LiteralPath $comparisonPath -Force -ErrorAction SilentlyContinue
$standardResult = Invoke-ListenerModeTest `
    -Mode Standard `
    -ConfigPath $standardConfigPath `
    -NodePath $nodePath `
    -ListenerScriptPath $listenerScriptPath `
    -RuntimePath $runtimePath `
    -TcpPort $TcpPort `
    -UdpPort $UdpPort `
    -StartupTimeoutSeconds $StartupTimeoutSeconds
$protectedResult = Invoke-ListenerModeTest `
    -Mode ProtectedClient `
    -ConfigPath $protectedConfigPath `
    -NodePath $nodePath `
    -ListenerScriptPath $listenerScriptPath `
    -RuntimePath $runtimePath `
    -TcpPort $TcpPort `
    -UdpPort $UdpPort `
    -StartupTimeoutSeconds $StartupTimeoutSeconds

$bothModesSucceeded = [bool]$standardResult.Succeeded -and [bool]$protectedResult.Succeeded
$comparison = [ordered]@{
    TestedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    LaunchMethod = 'Direct .wsb file launch for each mode'
    TcpPort = $TcpPort
    UdpPort = $UdpPort
    HostListenerExecutable = $nodePath
    HostFirewallEvidence = $firewallEvidence
    Standard = $standardResult
    ProtectedClient = $protectedResult
    BothModesSucceeded = $bothModesSucceeded
    Conclusion = if ($bothModesSucceeded) {
        'The Sandbox reached host TCP and UDP listeners in both standard and Protected Client modes.'
    }
    else {
        'At least one Sandbox-to-host TCP or UDP probe failed.'
    }
}
$comparison | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $comparisonPath -Encoding utf8
$comparison | ConvertTo-Json -Depth 12

if (-not $bothModesSucceeded) {
    throw 'The two-mode Sandbox-to-host comparison did not pass all TCP and UDP checks.'
}
