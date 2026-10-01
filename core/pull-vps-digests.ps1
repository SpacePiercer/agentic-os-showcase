# Pull digests the VPS jobs wrote into the vault. Outbound SSH from this PC only:
# nothing new listens on the VPS, so existing services on it are untouched.
param(
    [string]$VpsHost   = $env:AGENTIC_VPS,   # user@your-vps-host
    [string]$RemoteDir = '/home/agent/agentic-os/jobs/agent-vancouver-tech-event-radar/reports',
    [string]$LocalDir  = "$env:USERPROFILE\OneDrive\SecondBrain\inbox\reports\vps"
)
$ErrorActionPreference = 'Stop'
if (-not $VpsHost) { throw 'Set AGENTIC_VPS (user@host) or pass -VpsHost' }

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
# ponytail: re-copies every .md each run; switch to rsync or a date filter if the folder grows large.
& scp -q -o BatchMode=yes -o ConnectTimeout=15 "${VpsHost}:${RemoteDir}/*.md" $LocalDir
if ($LASTEXITCODE -ne 0) { throw "scp from $VpsHost failed (exit $LASTEXITCODE)" }
Write-Output "pulled VPS digests -> $LocalDir"
