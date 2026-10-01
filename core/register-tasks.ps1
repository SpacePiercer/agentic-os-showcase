# register-tasks.ps1 — (re)create the Agentic OS jobs in Windows Task Scheduler.
# Idempotent: run again after editing SecondBrain\os\os-config.yaml (or via /os sync).
# All tasks use StartWhenAvailable = catch-up at next PC-on if the scheduled time was missed.
# Headless `claude -p` jobs go through run-job.ps1 (logging + retry + state.results).
# Task names follow agent-<job>; registry + conventions in JOBS.md.

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot                      # core\
$root   = Split-Path $here -Parent
$runjob = "$here\run-job.ps1"
$vault  = "$env:USERPROFILE\OneDrive\SecondBrain"
$ps     = 'powershell.exe'

$hidden = "$here\hidden.vbs"

function Register-OsTask {
    param([string]$Name, [string]$Exe, [string]$Arguments, $Trigger)
    # Every action goes through hidden.vbs: powershell.exe from Task Scheduler
    # always flashes a console window, wscript.exe never does.
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' `
                -Argument "`"$hidden`" $Exe $Arguments" -WorkingDirectory $vault
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries `
                -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskPath '\AgenticOS' -TaskName $Name -Action $action -Trigger $Trigger `
        -Settings $settings -Force | Out-Null
    Write-Host "registered AgenticOS\$Name"
}

# Argument string for a claude job routed through run-job.ps1.
function JobArgs([string]$Name, [string]$Skill) {
    "-NoProfile -ExecutionPolicy Bypass -File `"$runjob`" -Name $Name -Skill `"$Skill`""
}

# morning-digest: 7:30am Mon-Fri — orchestrator runs the private (local) + public
# (Claude, via run-job) lanes and composes the report. See morning-digest.ps1.
Register-OsTask -Name 'agent-morning-digest' -Exe $ps `
    -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$root\jobs\morning-digest\morning-digest.ps1`"" `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday,Tuesday,Wednesday,Thursday,Friday -At 7:30am)

# inbox-triage toast: 4:00pm daily (fires at next power-on if PC was off) — pure PowerShell, no wrapper.
Register-OsTask -Name 'agent-inbox-triage-reminder' -Exe $ps `
    -Arguments "-NoProfile -WindowStyle Hidden -File `"$here\toast.ps1`" `"Inbox triage`" `"One touch per item: delete / resolve / promote. Also empty Ingest_bucket via /evening.`"" `
    -Trigger (New-ScheduledTaskTrigger -Daily -At 4:00pm)

# login-catchup: at logon (+2 min) run /os catchup — reruns any enabled job whose
# last successful run is behind its due slot, or whose last result was nonzero.
$logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$logon.Delay = 'PT2M'
Register-OsTask -Name 'agent-login-catchup' -Exe $ps -Arguments (JobArgs 'agent-login-catchup' '/os catchup') -Trigger $logon

# reflect: Friday 6pm — weekly workflow audit of the week's own transcripts.
Register-OsTask -Name 'agent-weekly-reflect' -Exe $ps -Arguments (JobArgs 'agent-weekly-reflect' '/reflect') `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At 6:00pm)

# skill-sync: every 2nd Saturday 10am — 3-way merge public skills with upstream, keep local edits.
Register-OsTask -Name 'agent-skill-sync' -Exe $ps -Arguments (JobArgs 'agent-skill-sync' '/skill-sync') `
    -Trigger (New-ScheduledTaskTrigger -Weekly -WeeksInterval 2 -DaysOfWeek Saturday -At 10:00am)
