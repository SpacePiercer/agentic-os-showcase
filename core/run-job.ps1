# run-job.ps1 — wrapper for headless `claude -p` Agentic OS jobs.
# Logs stdout+stderr, records pass/fail into the vault state.json, exits the
# child's code so Task Scheduler still sees success/failure. Centralizes the
# claude flag list so every job (morning-digest, deep-report, weekly, catchup)
# is invoked identically.
#
# Usage:
#   run-job.ps1 -Name agent-morning-digest -Skill "/morning-digest"
#
# Logs:  %USERPROFILE%\.agentic-os\logs\<name>-YYYY-MM-DD.log
# State: <vault>\os\state.json  ->  results[name] = {lastAttempt, exitCode, log[, lastError]}

param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Skill,
    # Variadic tool allow-list. Each entry is ONE arg (commander needs separate
    # tokens; a single "Read Write ..." string is parsed as one bogus tool).
    [string[]]$Tools = @('Read','Write','Edit','Glob','Grep','Bash','WebSearch','WebFetch','ToolSearch','Skill'),
    [string]$PermissionMode = 'acceptEdits'
)

$ErrorActionPreference = 'Stop'
$claude   = "$env:USERPROFILE\.local\bin\claude.exe"
$vault    = "$env:USERPROFILE\OneDrive\SecondBrain"
$stateF   = Join-Path $vault 'os\state.json'
$logDir   = "$env:USERPROFILE\.agentic-os\logs"
$day      = Get-Date -Format 'yyyy-MM-dd'
$iso      = (Get-Date).ToString('o')
$log      = Join-Path $logDir "$Name-$day.log"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# Prune logs older than 30 days.
Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$claudeArgs = @('-p', $Skill, '--permission-mode', $PermissionMode, '--allowedTools') + $Tools

"=== $Name @ $iso ===" | Out-File $log -Encoding utf8
"claude $($claudeArgs -join ' ')" | Out-File $log -Encoding utf8 -Append

# Retry transient API failures (the observed exit-1 cause: "Connection closed
# mid-response" on long headless turns). Up to 3 attempts, backoff 15s then 45s.
$maxAttempts = 3
$backoff     = @(15, 45)
$transient   = 'Connection closed|API Error|overloaded|rate limit|Connection error|ECONNRESET|fetch failed|(^|\D)(429|500|502|503|529)(\D|$)'
$exit = 1

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    "--- attempt $attempt/$maxAttempts ---" | Out-File $log -Encoding utf8 -Append
    # Start-Process with redirected streams: avoids PS 5.1 wrapping native stderr
    # in ErrorRecords (NativeCommandError) and gives a reliable ExitCode.
    $outTmp = [IO.Path]::GetTempFileName()
    $errTmp = [IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $claude -ArgumentList $claudeArgs `
            -WorkingDirectory $vault -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outTmp -RedirectStandardError $errTmp
        $exit = $proc.ExitCode
    } catch {
        ("LAUNCH FAILED: " + $_.Exception.Message) | Out-File $log -Encoding utf8 -Append
        $exit = 127
    }

    $out = (Get-Content $outTmp -Raw -ErrorAction SilentlyContinue)
    $err = (Get-Content $errTmp -Raw -ErrorAction SilentlyContinue)
    $out | Out-File $log -Encoding utf8 -Append
    "--- stderr ---" | Out-File $log -Encoding utf8 -Append
    $err | Out-File $log -Encoding utf8 -Append
    Remove-Item $outTmp,$errTmp -Force -ErrorAction SilentlyContinue

    if ($exit -eq 0) { break }
    $isTransient = "$out`n$err" -match $transient
    if (-not $isTransient -or $attempt -eq $maxAttempts) { break }
    $wait = $backoff[$attempt - 1]
    "transient failure (exit $exit) - retrying in ${wait}s" | Out-File $log -Encoding utf8 -Append
    Start-Sleep -Seconds $wait
}
"=== exit $exit ===" | Out-File $log -Encoding utf8 -Append

# Record result into state.json (create/patch results[name]).
try {
    $state = if (Test-Path $stateF) { Get-Content $stateF -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $state.PSObject.Properties['results']) {
        $state | Add-Member -Name results -Value ([pscustomobject]@{}) -MemberType NoteProperty -Force
    }
    $entry = [pscustomobject]@{ lastAttempt = $iso; exitCode = $exit; log = $log }
    if ($exit -ne 0) {
        $tail = (Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n"
        $entry | Add-Member -Name lastError -Value $tail -MemberType NoteProperty -Force
    }
    $state.results | Add-Member -Name $Name -Value $entry -MemberType NoteProperty -Force
    # UTF-8 without BOM — PS 5.1 Out-File -Encoding utf8 adds a BOM that strict
    # JSON parsers (e.g. Python json.load) reject.
    [IO.File]::WriteAllText($stateF, ($state | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding $false))
} catch {
    ("STATE WRITE FAILED: " + $_.Exception.Message) | Out-File $log -Encoding utf8 -Append
}

Write-Host "$Name -> exit $exit (log: $log)"
exit $exit
