# Event Radar

A nightly headless Claude Code job that finds transit-reachable tech events and
pushes only the new ones to Telegram.

```
briefs/event-research.md   the research brief — what to find, where to look, how to verify
run.sh                     cron wrapper — sets the window, runs `claude -p`, calls the differ
diff_events.py             compares against state/seen.json, notifies on the delta only
config.env.example         copy to config.env, fill in, chmod 600
```

## Setup

```bash
cp config.env.example config.env && chmod 600 config.env
$EDITOR config.env          # OAuth token, city, home address, bot token
chmod +x run.sh diff_events.py
```

Test before scheduling. The first run costs real tokens, so watch it:

```bash
./run.sh
```

Then check `out/events-YYYY-MM-DD.json` parses and looks sane. To re-test the
notification path without burning another run:

```bash
python3 diff_events.py out/events-2026-09-05.json --dry-run
```

## Schedule

```bash
crontab -e
```

```
0 2 * * * /home/agent/agentic-os/jobs/agent-vancouver-tech-event-radar/run.sh >> /home/agent/agentic-os/jobs/agent-vancouver-tech-event-radar/state/cron.log 2>&1
```

## How the pieces fit

`run.sh` computes a rolling window (today → today + `RADAR_WINDOW_DAYS`) and exports
it, then feeds the brief to `claude -p`. The brief tells the agent to write its
result as JSON to `RADAR_OUT` using the `Write` tool — not to stdout. That matters:
parsing a structured file the agent deliberately wrote is far more reliable than
scraping prose out of a transcript.

`diff_events.py` then compares that file against `state/seen.json`. An event is
**new** if its `id` hasn't been seen; **changed** if a material field moved — date,
time, venue, registration status, cost, or URL. Wording changes in the description
are ignored, because they churn between runs and would train you to ignore the
notifications.

The `id` is derived from name + date only. If it included venue or status, every
correction the agent made would look like a brand-new event.

## Things that will bite you

**Cron's environment is nearly empty.** No PATH to your node install, no shell
profile. `RADAR_NODE_BIN` in config.env exists for this; set it to
`dirname "$(which claude)"`.

**Auth is a `claude setup-token` OAuth token**, not the interactive login.
The interactive session can fail to refresh under cron (`OAuth session expired`);
the setup-token is long-lived (~1 year) and needs no refresh. Renew it yearly.

**`--allowedTools` is the safety boundary.** The run gets `WebSearch,WebFetch,Read,Write`
and no `Bash`. A confused agent can write files; it cannot execute anything.

**Watch the first week's cost.** A thorough run makes a lot of fetches. If runs come
back truncated, raise `RADAR_MAX_TURNS`; if they're expensive, narrow
`RADAR_WINDOW_DAYS` or drop the model to Sonnet for weekday runs.

## Tuning

- `RADAR_MIN_FIT` — floor on `fit_score` for notification. `3` keeps infra and
  security; `4` narrows to Python / agents / dev-infra only.
- The scoring rubric lives in section 4 of the brief. Edit it there, not here.
- To follow a different city, change `RADAR_CITY` and `RADAR_HOME`. The brief is
  written to be region-agnostic — it derives its source list from the city rather
  than hardcoding Bay Area calendars.
