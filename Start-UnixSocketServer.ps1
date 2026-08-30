param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    [string]$SocketPath,

    [Parameter(Mandatory)]
    [string]$ReadyPath,

    [Parameter(Mandatory)]
    [string]$TranscriptPath
)

$ErrorActionPreference = 'Stop'

Add-Type -Path $SourcePath
[WindowsUnixSocketProbe]::RunServer($SocketPath, $ReadyPath, $TranscriptPath)
