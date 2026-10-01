# Agentic OS — one-time setup

Plumbing for the SecondBrain Agentic OS. Vault: `~\OneDrive\SecondBrain`
(config in `os/os-config.yaml`). Skills: `~\.claude\skills\` (`/morning-digest`,
`/evening`, `/os`).

## 1. Scheduled jobs (required)

```powershell
powershell -ExecutionPolicy Bypass -File .\core\register-tasks.ps1
```

Creates Task Scheduler jobs under `AgenticOS\`:

| Job | When | Catch-up if PC off |
|---|---|---|
| morning-digest | 7:30am Mon–Fri | yes — runs at next power-on |
| inbox-triage-toast | 4:00pm daily | yes |
| deep-research-report | 3:00pm Fri | registered **disabled** until the skill exists |

Re-run after changing times in `os/os-config.yaml` (or just run `/os sync`).

Note: headless jobs run `claude -p` with `--permission-mode acceptEdits` and an
explicit `--allowedTools` list — review that list in `core/register-tasks.ps1`.

## 2. Google (Gmail + Calendar + Tasks in the digest) — optional but recommended

Until done, the digest just prints "Google not connected" in those sections.

1. https://console.cloud.google.com → new project (e.g. `agentic-os`).
2. APIs & Services → enable **Gmail API**, **Google Calendar API**, **Tasks API**.
3. OAuth consent screen → External → add your own Google account as test user.
4. Credentials → Create credentials → OAuth client ID → **Desktop app** →
   download the JSON → save as `%USERPROFILE%\.agentic-os\google-client.json`.
5. Run `powershell -ExecutionPolicy Bypass -File .\google\google-auth.ps1` → approve in
   browser. Tokens land in `%USERPROFILE%\.agentic-os\google-tokens.json`.

All scopes are **read-only**. Secrets never live in this repo or the vault.

## 3. Test the toast

```powershell
powershell -ExecutionPolicy Bypass -File .\core\toast.ps1 "Agentic OS" "toast works"
```
