# Agentic OS

A personal "operating system" of scheduled AI agents. Headless Claude Code jobs
and a local LLM run on a timetable, do recurring knowledge work (research,
inbox triage, weekly self-review), and drop the results into an Obsidian-style
notes vault, a Windows notification or a Telegram chat.

> This is a public snapshot of a private repo. Hosts, accounts and personal
> notes are replaced with placeholders; the code is the real thing.

## The idea

Most "AI assistants" wait for you to open a chat. The useful ones should run
**on their own**, on a schedule, and hand you finished work:

- a morning brief that is ready before you sit down,
- a list of tech events worth going to this week,
- a Friday review of where your own workflow keeps getting stuck.

Two rules shape the design:

1. **Private data stays local.** Email, calendar and tasks are read with
   read-only Google scopes and processed by a **local Ollama model**. Only the
   public-web half of the work goes to Claude.
2. **Boring, reliable plumbing.** Plain Windows Task Scheduler and cron, one
   wrapper that logs, retries and records pass/fail, and catch-up for runs
   missed while the PC was off. No servers that listen on the network.

## How it works

```
Task Scheduler (PC) / cron (VPS)
        │
        ▼
core/run-job.ps1 ── claude -p "/<skill>"  (headless Claude Code, retries, logs, state.json)
        │
        ├─ jobs/morning-digest/   two lanes:
        │     local-digest.ps1  → Gmail/Calendar/Tasks (read-only) → local Ollama model
        │                         → triage + drafted replies   [never leaves the machine]
        │     /morning-digest   → Claude researches public sources
        │     morning-digest.ps1 merges both → vault note + Windows toast
        │
        ├─ jobs/weekly-reflect/   mines the week's Claude Code transcripts for
        │                         recurring friction → ranked automation ideas
        │
        └─ jobs/agent-vancouver-tech-event-radar/  (Linux VPS, nightly)
              Claude finds transit-reachable tech events → diff vs last run
              → new/changed events posted to Telegram
```

| Folder | What's in it |
|---|---|
| `core/` | shared plumbing: task registration, the job wrapper, hidden launcher, toast notifications, VPS → vault sync |
| `google/` | one-time OAuth consent + token refresh (read-only scopes; credentials live outside the repo) |
| `jobs/<job>/` | one folder per scheduled job |
| `SETUP.md` | one-time setup |

The Claude Code skills the jobs call (`/morning-digest`, `/reflect`, `/os`, …)
live in `~/.claude/skills` and are not part of this snapshot.

## Current state

Running daily since July 2026.

- **5 PC jobs** in Task Scheduler (morning digest, inbox reminder, weekly
  reflect, biweekly skill sync, catch-up at login) and **1 VPS job** (event radar).
- A central job wrapper that logs every run, retries transient API drops, and
  records each job's last result so a catch-up job can rerun failures.
- The private/public split for the morning digest, with a test for the trickiest
  logic (free calendar slots proposed in drafted replies).

## Ideal state

- **Everything on the always-on VPS**, so nothing depends on the PC being on
  (then the login catch-up job can be retired).
- More jobs: an `/ingest` job that turns dropped files and downloads into vault
  notes, a spaced-repetition `/quiz`, and a Monday planning nudge.
- A memory layer: long-term state and structure shared across jobs, with more
  of the work moved to local models.
- A small UI to see job health and results at a glance, then packaging so
  others can run their own agentic OS.

## Tech

PowerShell 5.1 · Python · Bash · Windows Task Scheduler · cron · Claude Code (headless) ·
Ollama (local LLM) · Google Gmail/Calendar/Tasks REST APIs · Telegram Bot API
