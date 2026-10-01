#!/usr/bin/env bash
#
# Event Radar — nightly headless run.
#
#   crontab -e
#   0 2 * * * /home/agent/agentic-os/jobs/agent-vancouver-tech-event-radar/run.sh >> /home/agent/agentic-os/jobs/agent-vancouver-tech-event-radar/state/cron.log 2>&1
#
# Cron runs with a minimal environment: no PATH to your node install, no shell
# profile, no interactive OAuth session. Everything it needs is set explicitly below.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# --- config -----------------------------------------------------------------
# Keep secrets in config.env (chmod 600), not in this file.
# shellcheck source=/dev/null
# set -a exports everything, so diff_events.py sees TELEGRAM_* and RADAR_MIN_FIT too.
if [ -f "$ROOT/config.env" ]; then set -a; source "$ROOT/config.env"; set +a; fi

: "${CLAUDE_CODE_OAUTH_TOKEN:?set CLAUDE_CODE_OAUTH_TOKEN in config.env (claude setup-token)}"
: "${RADAR_CITY:?set RADAR_CITY in config.env}"
: "${RADAR_HOME:?set RADAR_HOME in config.env}"

# Rolling window: today through today + N days.
WINDOW_DAYS="${RADAR_WINDOW_DAYS:-9}"
export RADAR_WINDOW_START="$(date +%F)"
export RADAR_WINDOW_END="$(date -d "+${WINDOW_DAYS} days" +%F)"
export RADAR_CITY RADAR_HOME

STAMP="$(date +%F)"
export RADAR_OUT="$ROOT/out/events-$STAMP.json"

# Cron's PATH is typically /usr/bin:/bin only. Point at your actual node bin dir.
export PATH="${RADAR_NODE_BIN:-$HOME/.local/bin}:/usr/local/bin:$PATH"

mkdir -p "$ROOT/out" "$ROOT/runs" "$ROOT/state" "$ROOT/reports"

# --- pull the latest brief -------------------------------------------------
# Edit briefs/ from anywhere, push, and the next run picks it up. --autostash
# keeps local-only changes (config.env is gitignored, so this is usually a no-op).
# A pull failure is not fatal: better to run yesterday's brief than not at all.
# ROOT is a subfolder of the agentic-os clone, so ask git rather than test for .git here.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && [ "${RADAR_GIT_PULL:-1}" = "1" ]; then
  echo "--- git pull ---"
  git -C "$ROOT" pull --rebase --autostash --quiet || echo "pull failed, using local copy"
  echo "brief @ $(git -C "$ROOT" log -1 --format=%h\ %s -- briefs/ 2>/dev/null || echo unknown)"
fi

echo "=== $(date -Is) | $RADAR_CITY | $RADAR_WINDOW_START .. $RADAR_WINDOW_END ==="

# --- the run ----------------------------------------------------------------
# --allowedTools is the safety boundary: search, read, and write only. No Bash,
# so a confused run cannot touch anything outside the files it is told to write.
# --max-turns caps a runaway loop. Adjust upward if runs end truncated.

set +e
claude -p "$(cat "$ROOT/briefs/event-research.md")" \
  --allowedTools "WebSearch,WebFetch,Read,Write" \
  --output-format json \
  --max-turns "${RADAR_MAX_TURNS:-80}" \
  --model "${RADAR_MODEL:-claude-opus-4-6}" \
  > "$ROOT/runs/$STAMP.json"
RC=$?
set -e

if [ $RC -ne 0 ]; then
  echo "claude exited $RC — see runs/$STAMP.json"
  exit $RC
fi

if [ ! -s "$RADAR_OUT" ]; then
  echo "run finished but produced no events file at $RADAR_OUT"
  exit 1
fi

# --- diff and notify --------------------------------------------------------
python3 "$ROOT/diff_events.py" "$RADAR_OUT"

echo "=== done $(date -Is) ==="
