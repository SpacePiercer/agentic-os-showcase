# morning-digest.ps1 — orchestrates the two-lane morning digest and composes the
# final report. This is what the Task Scheduler job runs.
#
#   1. PRIVATE lane  : local-digest.ps1  -> <date>-private.md  (Gmail/Cal/Tasks,
#                      triaged by LOCAL Gemma; never touches Claude)
#   2. PUBLIC lane   : run-job.ps1 -> claude -p /morning-digest -> <date>-public.md
#                      (web research only; retried + logged)
#   3. COMPOSE       : merge the two fragments into the vault report note, refresh
#                      the folder index, stamp state.lastRun, toast, clean up.
#
# The merge is done HERE in PowerShell, so the Claude (public-lane) process never
# reads the private fragment — the privacy boundary holds by construction.
#
# Usage:  morning-digest.ps1           (skips if today's report already exists)
#         morning-digest.ps1 -Force    (rebuild today's report)

param([switch]$Force)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$scripts   = $PSScriptRoot
$core      = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'core'
$vault     = "$env:USERPROFILE\OneDrive\SecondBrain"
$fragDir   = "$env:USERPROFILE\.agentic-os\fragments"
$day       = Get-Date -Format 'yyyy-MM-dd'
$weekday   = (Get-Date).DayOfWeek
$reportDir = Join-Path $vault 'inbox\reports\morning'
$report    = Join-Path $reportDir "$day-morning-intel.md"
$privF     = Join-Path $fragDir "$day-private.md"
$pubF      = Join-Path $fragDir "$day-public.md"
$stateF    = Join-Path $vault 'os\state.json'
$utf8      = New-Object Text.UTF8Encoding $false   # no BOM

New-Item -ItemType Directory -Force -Path $reportDir, $fragDir | Out-Null

if ((Test-Path $report) -and -not $Force) {
    Write-Host "already done today: $report"
    exit 0
}

# --- 1. PRIVATE lane (local only) -------------------------------------------
try { & "$scripts\local-digest.ps1" -OutFile $privF }
catch { Write-Host "local-digest failed: $($_.Exception.Message)" }

# --- 2. PUBLIC lane (Claude, retried+logged) --------------------------------
# Run via a child process so run-job.ps1's `exit` can't abort this orchestrator;
# we compose from whatever fragments exist regardless of the public lane result.
# PS 5.1 turns a native command's stderr into a NativeCommandError, which under
# -EA Stop is TERMINATING and would skip compose - so relax it for this call.
$eap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$core\run-job.ps1" `
    -Name agent-morning-digest -Skill "/morning-digest"
$ErrorActionPreference = $eap

# --- 3. COMPOSE -------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('---')
[void]$sb.AppendLine('type: capture')
[void]$sb.AppendLine("created: $day")
[void]$sb.AppendLine('tags: [morning-intel]')
[void]$sb.AppendLine('---')
[void]$sb.AppendLine("# Morning Intel - $day ($weekday)")
[void]$sb.AppendLine('')
# Personal (private) block first - what's on the plate today.
if (Test-Path $privF) { [void]$sb.AppendLine(([IO.File]::ReadAllText($privF))) }
else { [void]$sb.AppendLine('## Personal'); [void]$sb.AppendLine('Private lane unavailable - see ~/.agentic-os/logs.'); [void]$sb.AppendLine('') }
# Research (public) block second.
if (Test-Path $pubF) { [void]$sb.AppendLine(([IO.File]::ReadAllText($pubF))) }
else { [void]$sb.AppendLine('## Research picks'); [void]$sb.AppendLine('Research lane unavailable - see state.results["agent-morning-digest"] / ~/.agentic-os/logs.'); [void]$sb.AppendLine('') }
[IO.File]::WriteAllText($report, $sb.ToString(), $utf8)
Write-Host "composed: $report"

# --- 4. refresh folder index (self-healing: list all reports, newest first) --
$idx = Join-Path $reportDir 'index.md'
$files = Get-ChildItem $reportDir -Filter '*-morning-intel.md' | Sort-Object Name -Descending
$ib = New-Object System.Text.StringBuilder
[void]$ib.AppendLine('# morning/ - Morning Intel reports')
[void]$ib.AppendLine('')
[void]$ib.AppendLine('Weekday digests. Personal sections (email/calendar/tasks) are produced by a')
[void]$ib.AppendLine('LOCAL model; research sections by Claude. Newest first.')
[void]$ib.AppendLine('')
foreach ($f in $files) { [void]$ib.AppendLine("- [$($f.BaseName)]($($f.Name))") }
[IO.File]::WriteAllText($idx, $ib.ToString(), $utf8)

# --- 5. stamp state.lastRun (preserve the rest of the file) -----------------
try {
    $state = if (Test-Path $stateF) { Get-Content $stateF -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $state.PSObject.Properties['lastRun']) {
        $state | Add-Member -Name lastRun -Value ([pscustomobject]@{}) -MemberType NoteProperty -Force
    }
    $state.lastRun | Add-Member -Name 'agent-morning-digest' -Value ((Get-Date).ToString('o')) -MemberType NoteProperty -Force
    [IO.File]::WriteAllText($stateF, ($state | ConvertTo-Json -Depth 8), $utf8)
} catch { Write-Host "state update failed: $($_.Exception.Message)" }

# --- 6. toast (teaser = first bold headline in the report, if any) ----------
# Teaser comes from the RESEARCH half only: the private block's first bold line
# is just "Needs attention:", and personal detail has no business in a toast.
$teaser = 'Your morning digest is ready.'
$pubText = if (Test-Path $pubF) { [IO.File]::ReadAllText($pubF) } else { '' }
$m = [regex]::Match($pubText, '\*\*(.+?)\*\*')
if ($m.Success) { $teaser = $m.Groups[1].Value }
try { & "$core\toast.ps1" 'Morning Intel ready' $teaser } catch {}

# --- 7. clean up today's fragments ------------------------------------------
Remove-Item $privF, $pubF -Force -ErrorAction SilentlyContinue
