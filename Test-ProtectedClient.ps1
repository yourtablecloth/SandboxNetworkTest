param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'SandboxHttp-ProtectedClient.wsb'),

    [ValidateRange(10, 300)]
    [int]$StartupTimeoutSeconds = 120,

    [switch]$CaptureCurrentSessionAsBaseline,

    [switch]$AttachOnly
)

$ErrorActionPreference = 'Stop'

$tokenInspectorSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class SandboxTokenInspector
{
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint TOKEN_QUERY = 0x0008;
    private const int TokenIsAppContainer = 29;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr token,
        int tokenInformationClass,
        out int tokenInformation,
        int tokenInformationLength,
        out int returnLength
    );

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static bool IsAppContainer(int processId)
    {
        IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                int value;
                int returned;
                if (!GetTokenInformation(token, TokenIsAppContainer, out value, sizeof(int), out returned))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                return value != 0;
            }
            finally
            {
                CloseHandle(token);
            }
        }
        finally
        {
            CloseHandle(process);
        }
    }
}
'@

Add-Type -TypeDefinition $tokenInspectorSource

function Get-SandboxClientTokenState {
    $processes = @(Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue)
    if ($processes.Count -ne 1) {
        throw "Expected one Windows Sandbox remote session process, found $($processes.Count)."
    }

    $process = $processes[0]
    return [pscustomobject][ordered]@{
        ProcessName    = $process.ProcessName
        ProcessId      = $process.Id
        IsAppContainer = [SandboxTokenInspector]::IsAppContainer($process.Id)
    }
}

function Stop-CurrentSandboxSession {
    $processes = @(Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue)
    if ($processes.Count -ne 1) {
        throw "Expected one Windows Sandbox remote session process to stop, found $($processes.Count)."
    }
    if ($processes[0].MainWindowTitle -ne 'Windows Sandbox') {
        throw 'The running process is not the expected Windows Sandbox test window.'
    }

    Stop-Process -Id $processes[0].Id -Force
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        $remaining = @(Get-Process -Name WindowsSandboxRemoteSession, WindowsSandboxServer -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw 'The previous Windows Sandbox session did not stop within 30 seconds.'
}

$runtimePath = Join-Path $PSScriptRoot 'runtime'
$baselinePath = Join-Path $runtimePath 'protected-client-baseline-token.json'
$networkResultPath = Join-Path $runtimePath 'host-probe-result.json'
$protectedNetworkResultPath = Join-Path $runtimePath 'protected-client-network-result.json'
$statusPath = Join-Path $runtimePath 'guest-status.json'
$resultPath = Join-Path $runtimePath 'protected-client-result.json'
New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null

$baselineTokenState = $null
if ($CaptureCurrentSessionAsBaseline) {
    $baselineTokenState = Get-SandboxClientTokenState
    $baselineTokenState | ConvertTo-Json | Set-Content -LiteralPath $baselinePath -Encoding utf8
    Stop-CurrentSandboxSession
}
elseif (Test-Path -LiteralPath $baselinePath) {
    $baselineTokenState = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
}
elseif (-not $AttachOnly) {
    throw 'No standard-client baseline token result is available.'
}

[xml]$config = Get-Content -LiteralPath (Resolve-Path -LiteralPath $ConfigPath) -Raw
if ($config.Configuration.ProtectedClient -ne 'Enable') {
    throw 'The selected WSB configuration does not enable ProtectedClient.'
}

$probeParameters = @{
    ConfigPath            = $ConfigPath
    StartupTimeoutSeconds = $StartupTimeoutSeconds
}
if ($AttachOnly) {
    $probeParameters.AttachOnly = $true
}
elseif (Get-Process -Name WindowsSandboxRemoteSession -ErrorAction SilentlyContinue) {
    throw 'A Windows Sandbox session is already running. Close it or use -AttachOnly for the Protected Client session.'
}

& (Join-Path $PSScriptRoot 'Start-Probe.ps1') @probeParameters | Out-Null

$protectedTokenState = Get-SandboxClientTokenState
$networkResult = Get-Content -LiteralPath $networkResultPath -Raw | ConvertFrom-Json
$guestStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
Copy-Item -LiteralPath $networkResultPath -Destination $protectedNetworkResultPath -Force

$guestBootstrapReadSucceeded = $guestStatus.State -eq 'Listening'
$guestRuntimeWriteSucceeded = Test-Path -LiteralPath $statusPath
$tcpSucceeded = [bool]$networkResult.IpRequest.Succeeded
$udpSucceeded = [bool]$networkResult.UdpRequest.Succeeded
$outboundInternetConnected = [bool]$guestStatus.OutboundInternetProbe.Connected
$protectedClientConfirmed = [bool]$protectedTokenState.IsAppContainer
$baselineWasStandard = $null -ne $baselineTokenState -and -not [bool]$baselineTokenState.IsAppContainer
$functionalChecksPassed =
    $guestBootstrapReadSucceeded -and
    $guestRuntimeWriteSucceeded -and
    $tcpSucceeded -and
    $udpSucceeded -and
    $outboundInternetConnected

$testResult = [ordered]@{
    TestedAtUtc                   = [DateTimeOffset]::UtcNow.ToString('o')
    ProtectedClientConfigured     = $true
    StandardClientToken           = $baselineTokenState
    ProtectedClientToken          = $protectedTokenState
    StandardClientWasNotContainer = $baselineWasStandard
    ProtectedClientIsAppContainer = $protectedClientConfirmed
    TokenCheckVerifiedIsolation    = $false
    TokenCheckInterpretation       = 'The outer WindowsSandboxRemoteSession token remained non-AppContainer in both modes and does not expose the documented internal RDP AppContainer boundary.'
    GuestBootstrapReadSucceeded   = $guestBootstrapReadSucceeded
    GuestRuntimeWriteSucceeded    = $guestRuntimeWriteSucceeded
    GuestNetworkAdapterCount      = @($guestStatus.NetworkAdapters).Count
    GuestHasNonLoopbackIPv4       = [bool]$guestStatus.HasNonLoopbackIPv4Address
    GuestHasDefaultIPv4Route      = [bool]$guestStatus.HasDefaultIPv4Route
    GuestOutboundInternetConnected = $outboundInternetConnected
    HostTcpProbeSucceeded         = $tcpSucceeded
    HostUdpProbeSucceeded         = $udpSucceeded
    FunctionalChecksPassed        = $functionalChecksPassed
    ClipboardTested               = $false
    ClipboardNote                 = 'Not tested automatically because the test would modify the user clipboard.'
    Conclusion                    = if ($functionalChecksPassed) {
        'Protected Client preserved mapped folders, guest networking, outbound Internet, and host TCP/UDP probes. The outer process-token check did not directly verify the documented internal isolation boundary.'
    }
    else {
        'The observed Protected Client behavior did not match all expected checks.'
    }
}

$testResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
$testResult | ConvertTo-Json -Depth 8

if (-not $guestBootstrapReadSucceeded -or -not $guestRuntimeWriteSucceeded) {
    throw 'A mapped-folder check failed in Protected Client mode.'
}
if (-not $tcpSucceeded -or -not $udpSucceeded) {
    throw 'A TCP or UDP check failed in Protected Client mode.'
}
if (-not $outboundInternetConnected) {
    throw 'The outbound Internet check failed in Protected Client mode.'
}
