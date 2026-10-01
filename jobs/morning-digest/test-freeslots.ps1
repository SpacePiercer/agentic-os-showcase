# test-freeslots.ps1 — check the free-slot math in local-digest.ps1.
# A bug here means a drafted reply proposes a time you are already busy, so the
# invariant test (no slot overlaps a busy block) matters more than the strings.
# Run: powershell -ExecutionPolicy Bypass -File .\test-freeslots.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\local-digest.ps1" -DefineOnly

function Assert($cond, [string]$msg) { if (-not $cond) { throw "FAIL: $msg" } }

$mon = Get-Date '2026-07-27 08:00'          # a Monday, before working hours
function Busy([string]$s, [string]$e) { [pscustomobject]@{ Start = (Get-Date $s); End = (Get-Date $e) } }
$busy = @(
    (Busy '2026-07-27 10:00' '2026-07-27 11:00'),
    (Busy '2026-07-27 13:00' '2026-07-27 14:30')
)

$s = Get-FreeSlots -Busy $busy -Now $mon
Assert ($s[0] -eq 'Mon Jul 27, 09:00-10:00') "gap before first event, got '$($s[0])'"
Assert ($s -contains 'Mon Jul 27, 11:00-13:00') 'gap between two events'
Assert ($s -contains 'Mon Jul 27, 14:30-18:00') 'gap after last event to close'
Assert ($s -notcontains 'Mon Jul 27, 09:00-18:00') 'busy blocks must be subtracted'

# The real invariant: no proposed slot may overlap a busy block.
foreach ($slot in $s) {
    if ($slot -notmatch '^(\w+ \w+ \d+), (\d\d:\d\d)-(\d\d:\d\d)$') { throw "FAIL: bad format '$slot'" }
    $d = [datetime]::Parse("$($matches[1]) 2026")
    $a = $d.Date.Add([timespan]$matches[2]); $b = $d.Date.Add([timespan]$matches[3])
    foreach ($x in $busy) { Assert (-not ($a -lt $x.End -and $b -gt $x.Start)) "slot '$slot' overlaps a busy block" }
}

# Slots never start in the past: mid-afternoon "now", empty calendar.
$s2 = Get-FreeSlots -Busy @() -Now (Get-Date '2026-07-27 14:00')
Assert ($s2[0] -eq 'Mon Jul 27, 14:30-18:00') "no past slots, got '$($s2[0])'"

# Weekends are skipped: Friday "now" must roll to Monday, not Saturday.
$s3 = Get-FreeSlots -Busy @() -Now (Get-Date '2026-07-31 19:00')   # Friday, after close
Assert ($s3[0] -eq 'Mon Aug 3, 09:00-18:00') "weekend skipped, got '$($s3[0])'"

# A day fully booked yields nothing for that day.
$allday = @((Busy '2026-07-27 00:00' '2026-07-28 00:00'))
$s4 = Get-FreeSlots -Busy $allday -Now $mon
Assert ($s4[0] -eq 'Tue Jul 28, 09:00-18:00') "all-day event blocks the day, got '$($s4[0])'"

Write-Host 'free-slot math OK'
