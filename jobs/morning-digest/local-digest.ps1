# local-digest.ps1 — PRIVATE lane of the morning digest. Runs ENTIRELY on this
# machine: fetches Gmail/Calendar/Tasks (read-only), triages email and drafts
# replies with a LOCAL Ollama model. Nothing here ever reaches Anthropic/Claude.
# Writes a markdown "private fragment" that compose later merges into the report.
#
# Output (default): %USERPROFILE%\.agentic-os\fragments\<YYYY-MM-DD>-private.md
# Kept OUTSIDE the vault on purpose, so the Claude (public-lane) process - which
# works inside the vault - never even sees the private text.
#
# Encoding: everything is forced to UTF-8 end to end so non-ASCII (Cyrillic,
# emoji, accents) survives. PowerShell 5.1 otherwise (a) reads .ps1 as ANSI and
# (b) decodes charset-less HTTP responses as Latin-1 - both corrupt UTF-8.
#
# Usage:  local-digest.ps1            (writes today's fragment, prints the path)
#         local-digest.ps1 -Show      (also prints the fragment to stdout)

param(
    [string]$Model   = 'gemma4:e4b',
    [string]$OutFile,
    [string]$Me      = $env:USERNAME,   # name the drafted replies sign off as
    [int]$MaxDrafts  = 3,           # each draft is a local generation; CPU-bound
    [switch]$Show,
    [switch]$DefineOnly             # dot-source the functions only (for tests)
)

$ErrorActionPreference = 'Stop'
# Make the console + native pipes speak UTF-8 (guarded: throws if no console).
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [Text.Encoding]::UTF8

$scripts  = $PSScriptRoot
$fragDir  = "$env:USERPROFILE\.agentic-os\fragments"
$ledgerF  = "$env:USERPROFILE\.agentic-os\drafted.json"   # messageId -> date drafted
$day      = Get-Date -Format 'yyyy-MM-dd'
if (-not $OutFile) { $OutFile = Join-Path $fragDir "$day-private.md" }
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null

# Build emoji from code points so the SOURCE stays pure ASCII (see encoding note).
$E_MAIL  = [char]::ConvertFromUtf32(0x1F4E7)   # envelope
$E_CAL   = [char]::ConvertFromUtf32(0x1F4C5)   # calendar
$E_TASK  = [char]::ConvertFromUtf32(0x2705)    # check mark
$E_DRAFT = [char]::ConvertFromUtf32(0x1F4DD)   # memo

# --- UTF-8-safe JSON over HTTP ----------------------------------------------
# Reads the raw response bytes and decodes them as UTF-8 explicitly, instead of
# trusting Invoke-RestMethod (which falls back to Latin-1 when the response has
# no charset - the Cyrillic-corruption bug). Works for GET (Google) and POST
# (Ollama) alike.
function Invoke-JsonUtf8 {
    param([string]$Uri, [hashtable]$Headers, [string]$Method = 'Get',
          [string]$Body, [string]$ContentType)
    $p = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true; TimeoutSec = 300 }
    if ($Headers)     { $p.Headers     = $Headers }
    if ($Body)        { $p.Body        = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    $resp  = Invoke-WebRequest @p
    $bytes = $resp.RawContentStream.ToArray()
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

# --- local model call (Ollama, localhost only) ------------------------------
# $Schema (optional): a JSON-schema hashtable passed to Ollama's `format` field.
# When present, Ollama constrains decoding so the output is valid JSON matching
# the schema - the format harness. The model only supplies the JUDGMENT; the
# caller renders the markdown deterministically from the parsed object.
function Invoke-Gemma([string]$Prompt, $Schema) {
    $payload = @{ model = $Model; prompt = $Prompt; stream = $false
                  options = @{ temperature = 0.2 } }
    if ($Schema) { $payload.format = $Schema }
    # ConvertTo-Json escapes non-ASCII to \uXXXX, so the request body is ASCII-safe.
    $body = $payload | ConvertTo-Json -Depth 12
    $r = Invoke-JsonUtf8 -Uri 'http://localhost:11434/api/generate' -Method Post `
            -Body $body -ContentType 'application/json'
    return $r.response.Trim()
}

# --- Gmail body extraction --------------------------------------------------
# Gmail returns bodies base64url-encoded, buried in a nested MIME part tree.
function ConvertFrom-B64Url([string]$d) {
    $s = $d.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
function Get-PlainBody($payload) {
    if ($payload.mimeType -eq 'text/plain' -and $payload.body.data) {
        return (ConvertFrom-B64Url $payload.body.data)
    }
    foreach ($p in $payload.parts) { $t = Get-PlainBody $p; if ($t) { return $t } }
    return ''
}

# --- free calendar slots (deterministic - no model) -------------------------
# Walks the next N weekdays inside working hours, subtracts busy blocks, and
# returns the gaps. Computed in PowerShell ON PURPOSE: a drafted reply can then
# only propose a time that is genuinely free, because it picks from this list
# rather than reasoning about the calendar itself.
function Get-BusyBlocks {
    param([int]$Days = 7, [datetime]$Now = (Get-Date))
    $tMin = $Now.ToString('yyyy-MM-ddTHH:mm:ssK')
    $tMax = $Now.AddDays($Days).ToString('yyyy-MM-ddTHH:mm:ssK')
    $ev = Invoke-JsonUtf8 -Headers $H -Uri ("https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=$([uri]::EscapeDataString($tMin))&timeMax=$([uri]::EscapeDataString($tMax))&singleEvents=true&orderBy=startTime&maxResults=250")
    # Objects, not nested arrays: PowerShell flattens an array-of-arrays on
    # return, which silently turns each pair into two loose DateTimes.
    $busy = @()
    foreach ($e in $ev.items) {
        if ($e.start.dateTime) {
            $busy += [pscustomobject]@{ Start = (Get-Date $e.start.dateTime); End = (Get-Date $e.end.dateTime) }
        } elseif ($e.start.date) {
            $d = (Get-Date $e.start.date).Date
            $busy += [pscustomobject]@{ Start = $d; End = $d.AddDays(1) }
        }
    }
    return $busy
}
# Pure interval math, kept separate from the fetch so it can be checked without
# touching the network - see test-freeslots.ps1.
function Get-FreeSlots {
    param($Busy = @(), [datetime]$Now = (Get-Date), [int]$Days = 7,
          [int]$StartHour = 9, [int]$EndHour = 18,
          [int]$MinMinutes = 60, [int]$Max = 5)
    $now  = $Now
    $busy = @($Busy)
    $out = @()
    for ($i = 0; $i -lt $Days -and $out.Count -lt $Max; $i++) {
        $dayStart = $now.Date.AddDays($i)
        if ($dayStart.DayOfWeek -eq 'Saturday' -or $dayStart.DayOfWeek -eq 'Sunday') { continue }
        $open  = $dayStart.AddHours($StartHour)
        $close = $dayStart.AddHours($EndHour)
        if ($open -lt $now) { $open = $now.AddMinutes(30) }   # no slots in the past
        if ($open -ge $close) { continue }
        $cur = $open
        foreach ($b in @($busy | Where-Object { $_.End -gt $open -and $_.Start -lt $close } | Sort-Object Start)) {
            if ($b.Start -gt $cur -and ($b.Start - $cur).TotalMinutes -ge $MinMinutes) {
                $out += ('{0}, {1:HH:mm}-{2:HH:mm}' -f $cur.ToString('ddd MMM d'), $cur, $b.Start)
            }
            if ($b.End -gt $cur) { $cur = $b.End }
        }
        if ($close -gt $cur -and ($close - $cur).TotalMinutes -ge $MinMinutes) {
            $out += ('{0}, {1:HH:mm}-{2:HH:mm}' -f $cur.ToString('ddd MMM d'), $cur, $close)
        }
    }
    return @($out | Select-Object -First $Max)
}

# Dot-source with -DefineOnly to get the functions without running the digest.
if ($DefineOnly) { return }

# --- Google token (read-only; refresh flow, no browser) ---------------------
$token = & powershell -NoProfile -File "$(Split-Path (Split-Path $scripts -Parent) -Parent)\google\get-google-token.ps1"
$haveGoogle = [bool]$token
$H = @{ Authorization = "Bearer $token" }

$sb = New-Object System.Text.StringBuilder
$drafts = @()   # filled during triage, rendered after it

# --- Email triage (LOCAL model) ---------------------------------------------
[void]$sb.AppendLine("## $E_MAIL Email triage")
if (-not $haveGoogle) {
    [void]$sb.AppendLine('Google not connected - run google-auth.ps1 (see SETUP.md).')
} else {
    try {
        # Everything from the last day, read or not - being read is not the same
        # as being answered. What gets excluded from DRAFTING (not from the
        # summary) is threads already replied to, threads holding a draft, and
        # messages a previous run already drafted.
        $q = [uri]::EscapeDataString('in:inbox newer_than:1d -from:me')
        $list = Invoke-JsonUtf8 -Headers $H -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$q&maxResults=25"
        $msgs = @()
        foreach ($m in $list.messages) {
            $msg = Invoke-JsonUtf8 -Headers $H -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages/$($m.id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject"
            $msgs += [pscustomobject]@{
                Id       = $m.id
                ThreadId = $m.threadId
                From     = ($msg.payload.headers | Where-Object name -eq 'From').value
                Subject  = ($msg.payload.headers | Where-Object name -eq 'Subject').value
            }
        }
        # Two list calls, not one per message: a thread you have sent into counts
        # as answered, a thread holding a draft counts as already in progress.
        $sq = [uri]::EscapeDataString('in:sent newer_than:2d')
        $sentThreads  = @((Invoke-JsonUtf8 -Headers $H -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$sq&maxResults=100").messages | ForEach-Object { $_.threadId })
        $draftThreads = @((Invoke-JsonUtf8 -Headers $H -Uri 'https://gmail.googleapis.com/gmail/v1/users/me/drafts?maxResults=100').drafts | ForEach-Object { $_.message.threadId })
        # Ledger of what this script has already drafted, so an email that sits
        # unanswered for days is drafted once - not every morning.
        $ledger = @{}
        if (Test-Path $ledgerF) {
            try { (Get-Content $ledgerF -Raw | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $ledger[$_.Name] = $_.Value } } catch {}
        }
        if ($msgs.Count -eq 0) {
            [void]$sb.AppendLine('Nothing new in the last day.')
        } else {
            # Number the lines so the model can point back at a message without
            # having to copy a long opaque Gmail id.
            $emailBlock = ((0..($msgs.Count - 1) | ForEach-Object {
                "[$($_ + 1)] $($msgs[$_].From) | $($msgs[$_].Subject)"
            }) -join "`n")
            # The model returns ONLY the decision as schema-constrained JSON;
            # PowerShell renders the markdown, so the format cannot drift.
            $schema = @{
                type = 'object'
                properties = @{
                    needs_attention = @{
                        type  = 'array'
                        items = @{
                            type = 'object'
                            properties = @{
                                index         = @{ type = 'integer' }
                                sender        = @{ type = 'string' }
                                subject       = @{ type = 'string' }
                                expects_reply = @{ type = 'boolean' }
                            }
                            required = @('index','sender','subject','expects_reply')
                        }
                    }
                    routine_count = @{ type = 'integer' }
                }
                required = @('needs_attention','routine_count')
            }
            $prompt = @"
Triage this person's unread email. Each line is "[number] Sender | Subject". Subjects may be in English or Russian - handle both.
Classify each as important (from a real person, a reply expected, time-sensitive, account/security, money/bills) or routine (newsletters, promotions, social notifications, automated receipts).
A newsletter is routine even when it is written by a named individual (Substack authors, columnists, commentators) - what matters is whether a reply is expected from this person, not whether a human wrote it.
Return only the important ones in needs_attention, copying each one's [number] into index (sender = just the name or address, not the full header), and set routine_count to the number of routine ones.
Set expects_reply true ONLY when a human is waiting on an answer from this person - a question, an invitation, a request, a proposed meeting. Automated alerts and receipts are important but expects_reply false.
Use only the emails listed; do not invent any.

EMAILS:
$emailBlock
"@
            # Parse the JSON; retry once; fall back to a plain count if malformed.
            $triage = $null
            foreach ($try in 1..2) {
                try { $triage = Invoke-Gemma $prompt $schema | ConvertFrom-Json; break }
                catch { $triage = $null }
            }
            if ($null -eq $triage) {
                [void]$sb.AppendLine("$($msgs.Count) new in the last day (triage model returned no valid output).")
            } else {
                $imp = @($triage.needs_attention)
                if ($imp.Count -gt 0) {
                    [void]$sb.AppendLine('**Needs attention:**')
                    foreach ($e in $imp) { [void]$sb.AppendLine("- $($e.sender) - $($e.subject)") }
                }
                $routine = if ($null -ne $triage.routine_count) { [int]$triage.routine_count } else { $msgs.Count - $imp.Count }
                [void]$sb.AppendLine("**Routine:** $routine newsletters/notifications")

                # --- draft replies for the ones a human is waiting on --------
                $toDraft = @($imp | Where-Object {
                    $_.expects_reply -and $_.index -ge 1 -and $_.index -le $msgs.Count
                } | Where-Object {
                    $c = $msgs[$_.index - 1]
                    ($sentThreads  -notcontains $c.ThreadId) -and
                    ($draftThreads -notcontains $c.ThreadId) -and
                    (-not $ledger.ContainsKey($c.Id))
                } | Select-Object -First $MaxDrafts)
                # Drafting has its own catch: a failure here is not an email
                # failure, and the triage above must still ship.
                if ($toDraft.Count -gt 0) { try {
                    $slots = Get-FreeSlots -Busy (Get-BusyBlocks) -Now (Get-Date)
                    $slotBlock = if ($slots.Count) { ($slots | ForEach-Object { "- $_" }) -join "`n" }
                                 else { '- (no free weekday slots in the next 7 days)' }
                    $draftSchema = @{
                        type = 'object'
                        properties = @{
                            needs_reply = @{ type = 'boolean' }
                            reply       = @{ type = 'string' }
                        }
                        required = @('needs_reply','reply')
                    }
                    foreach ($d in $toDraft) {
                        $src = $msgs[$d.index - 1]
                        try {
                            $full = Invoke-JsonUtf8 -Headers $H -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages/$($src.Id)?format=full"
                            $body = Get-PlainBody $full.payload
                            if ($body.Length -gt 2000) { $body = $body.Substring(0, 2000) }
                            # The name someone signs off with beats the From display
                            # name - that is the name they actually go by.
                            $senderName = ((($src.From -replace '<[^>]*>', '') -replace '"', '').Trim())
                            if (-not $senderName) { $senderName = ($src.From -replace '[<>]', '').Trim() }
                            $dp = @"
Draft the reply that $Me will send to this email. Output ONLY the message body: no subject line, no commentary about what you did.
Write in the same language as the incoming email (English or Russian). Keep it short and plain - 2 to 5 sentences.
Greet the sender by the name they sign off with at the end of their message. Only if they sign off with no name, fall back to "$senderName" from the header. Never invent a name that appears in neither place.
End with a final line containing only: $Me
If the sender proposes a meeting, call, or event, pick ONE time from AVAILABLE SLOTS below and propose it explicitly by day and time. Never propose a time that is not in that list - every other hour is already taken.
Do NOT claim to be busy, unavailable, or to have a conflict. You cannot see which times the sender suggested well enough to judge that. Simply propose a time from the list.
If no human reply is actually needed, set needs_reply to false and leave reply empty.

AVAILABLE SLOTS ($Me is free, local time):
$slotBlock

FROM: $($src.From)
SUBJECT: $($src.Subject)
BODY:
$body
"@
                            $res = $null
                            foreach ($try in 1..2) {
                                try { $res = Invoke-Gemma $dp $draftSchema | ConvertFrom-Json; break }
                                catch { $res = $null }
                            }
                            if ($res -and $res.needs_reply -and $res.reply.Trim()) {
                                $drafts += [pscustomobject]@{
                                    To = $src.From; Subject = $src.Subject; Reply = $res.reply.Trim()
                                }
                                $ledger[$src.Id] = $day   # only on success: a failure retries tomorrow
                            }
                        } catch {
                            $drafts += [pscustomobject]@{
                                To = $src.From; Subject = $src.Subject
                                Reply = "(draft failed: $($_.Exception.Message))"
                            }
                        }
                    }
                    # Persist the ledger, pruned to 30 days (dates sort as strings).
                    $cutoff = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
                    $keep = @{}
                    foreach ($k in $ledger.Keys) { if ($ledger[$k] -ge $cutoff) { $keep[$k] = $ledger[$k] } }
                    [IO.File]::WriteAllText($ledgerF, ($keep | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
                } catch {
                    [void]$sb.AppendLine("(reply drafting unavailable: $($_.Exception.Message))")
                } }
            }
        }
    } catch {
        [void]$sb.AppendLine("Email unavailable: $($_.Exception.Message)")
    }
}
[void]$sb.AppendLine('')

# --- Draft replies (LOCAL model, never sent) --------------------------------
if ($drafts.Count -gt 0) {
    [void]$sb.AppendLine("## $E_DRAFT Draft replies")
    [void]$sb.AppendLine("Written locally by $Model against your real calendar. Read before sending -")
    [void]$sb.AppendLine('copy/paste into Gmail. Nothing is sent or saved to your mailbox.')
    [void]$sb.AppendLine('')
    foreach ($d in $drafts) {
        [void]$sb.AppendLine("### $($d.To) - re: $($d.Subject)")
        [void]$sb.AppendLine('```text')
        [void]$sb.AppendLine($d.Reply)
        [void]$sb.AppendLine('```')
        [void]$sb.AppendLine('')
    }
}

# --- Today (deterministic, no model) ----------------------------------------
[void]$sb.AppendLine("## $E_CAL Today")
if (-not $haveGoogle) {
    [void]$sb.AppendLine('Google not connected.')
} else {
    try {
        $tMin = (Get-Date -Hour 0 -Minute 0 -Second 0).ToString('yyyy-MM-ddTHH:mm:ssK')
        $tMax = (Get-Date -Hour 23 -Minute 59 -Second 59).ToString('yyyy-MM-ddTHH:mm:ssK')
        $ev = Invoke-JsonUtf8 -Headers $H -Uri ("https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=$([uri]::EscapeDataString($tMin))&timeMax=$([uri]::EscapeDataString($tMax))&singleEvents=true&orderBy=startTime")
        if (($ev.items | Measure-Object).Count -eq 0) {
            [void]$sb.AppendLine('No events today.')
        } else {
            foreach ($e in $ev.items) {
                if ($e.start.dateTime) { $when = (Get-Date $e.start.dateTime -Format 'HH:mm') } else { $when = 'all-day' }
                [void]$sb.AppendLine("- $when - $($e.summary)")
            }
        }
    } catch {
        [void]$sb.AppendLine("Calendar unavailable: $($_.Exception.Message)")
    }
}
[void]$sb.AppendLine('')

# --- Tasks (deterministic, no model) ----------------------------------------
[void]$sb.AppendLine("## $E_TASK Tasks")
if (-not $haveGoogle) {
    [void]$sb.AppendLine('Google not connected.')
} else {
    try {
        $tk = Invoke-JsonUtf8 -Headers $H -Uri 'https://tasks.googleapis.com/tasks/v1/lists/@default/tasks?showCompleted=false'
        if (($tk.items | Measure-Object).Count -eq 0) {
            [void]$sb.AppendLine('No open tasks.')
        } else {
            foreach ($t in ($tk.items | Sort-Object { $_.due })) {
                $due = if ($t.due) { ' (due ' + (Get-Date $t.due -Format 'MMM d') + ')' } else { '' }
                # Task titles can hold pasted multi-line notes; raw, they break the
                # markdown list. Flatten to one line and cap it - this is a digest.
                $title = ($t.title -replace '\s+', ' ').Trim()
                if ($title.Length -gt 100) { $title = $title.Substring(0, 97) + '...' }
                [void]$sb.AppendLine("- $title$due")
            }
        }
    } catch {
        [void]$sb.AppendLine("Tasks unavailable: $($_.Exception.Message)")
    }
}

# --- write fragment (UTF-8 no BOM) ------------------------------------------
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
Write-Host "private fragment -> $OutFile"
if ($Show) { Write-Host "----------------------------------------"; Get-Content $OutFile -Encoding UTF8 }
