#!/usr/bin/env python3
"""
Event Radar - turn a run's JSON into a readable markdown report, and post the
delta (new + changed events only) to Telegram.

The report holds the WHOLE window with new/changed marked inline; Telegram only
pings when something moved. No TELEGRAM_* env vars = report only.

Usage:
    python3 diff_events.py out/events-2026-09-09.json
    python3 diff_events.py out/events-2026-09-09.json --dry-run
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path
from typing import Any

# ponytail: IPv4 only for this whole script (its only network call is Telegram).
# The VPS's IPv6 path to Telegram dies upstream in Cogent, and urllib tries IPv6
# first, so every send waited out the timeout. Drop this if that route heals.
_getaddrinfo = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a, **k: _getaddrinfo(host, port, socket.AF_INET, *a, **k)

ROOT = Path(__file__).resolve().parent
STATE_PATH = ROOT / "state" / "seen.json"
REPORT_DIR = ROOT / "reports"

# Fields that count as a material change. Description wording churns between
# runs and would mark half the list as "changed" every morning.
MATERIAL_FIELDS = ("date", "start_time", "venue", "registration", "cost", "url")

MIN_FIT = int(os.environ.get("RADAR_MIN_FIT", "3"))


# --------------------------------------------------------------------------- io


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        sys.exit(f"{path} is not valid JSON: {exc}")


def load_state() -> dict[str, dict]:
    data = load_json(STATE_PATH)
    return data.get("events", {}) if isinstance(data, dict) else {}


def save_state(seen: dict[str, dict]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {"updated_at": datetime.now().astimezone().isoformat(), "events": seen}
    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(STATE_PATH)


# ------------------------------------------------------------------------ diff


def is_past(ev: dict) -> bool:
    try:
        return date.fromisoformat(ev["date"]) < date.today()
    except (KeyError, ValueError):
        return False


def changed_fields(old: dict, new: dict) -> list[str]:
    return [f for f in MATERIAL_FIELDS if old.get(f) != new.get(f)]


def classify(events: list[dict], seen: dict[str, dict]) -> dict[str, Any]:
    """Tag each event as new / changed / known. Returns the kept list plus counts."""
    kept, new_ids, changed = [], set(), {}

    for ev in events:
        eid = ev.get("id")
        if not eid or is_past(ev):
            continue
        if ev.get("fit_score", 0) < MIN_FIT:
            continue

        prior = seen.get(eid)
        if prior is None:
            new_ids.add(eid)
        else:
            deltas = changed_fields(prior, ev)
            if deltas:
                changed[eid] = deltas
        kept.append(ev)

    return {"events": kept, "new": new_ids, "changed": changed}


def prune(seen: dict[str, dict]) -> dict[str, dict]:
    return {k: v for k, v in seen.items() if not is_past(v)}


# -------------------------------------------------------------------- markdown


def pretty_day(iso: str) -> str:
    try:
        d = date.fromisoformat(iso)
    except (ValueError, TypeError):
        return iso or "Date unknown"
    return f"{d.strftime('%a')} {d.day} {d.strftime('%b')}"


def render_event(ev: dict, marker: str, deltas: list[str] | None) -> list[str]:
    name = ev.get("name", "Untitled")
    host = ev.get("host")
    out = [f"### {marker}{name}" + (f" - {host}" if host else "")]

    facts = []
    if ev.get("start_time"):
        t = ev["start_time"]
        if ev.get("end_time"):
            t += "-" + ev["end_time"]
        facts.append(f"**{t}**")
    if ev.get("venue"):
        facts.append(ev["venue"])
    transit = ev.get("transit") or {}
    if transit.get("minutes") is not None:
        facts.append(f"~{transit['minutes']} min")
    if facts:
        out.append(" · ".join(facts))

    status = []
    if ev.get("cost"):
        status.append(str(ev["cost"]))
    if ev.get("registration"):
        status.append(ev["registration"].replace("_", " "))
    if ev.get("card_required"):
        status.append("**card required**")
    if ev.get("fit_score") is not None:
        status.append(f"fit {ev['fit_score']}/5")
    if ev.get("confidence") in ("likely", "unverified"):
        status.append(f"!! {ev['confidence']}")
    if status:
        out.append(" · ".join(status))

    if deltas:
        out.append(f"*Changed since last run: {', '.join(deltas)}*")

    if ev.get("description"):
        out += ["", ev["description"]]

    if transit.get("route"):
        line = f"*Getting there:* {transit['route']}"
        if transit.get("warning"):
            line += f" - {transit['warning']}"
        out += ["", line]

    if ev.get("notes"):
        out += ["", f"*Note:* {ev['notes']}"]

    if ev.get("url"):
        out += ["", f"[Open event page]({ev['url']})"]

    out.append("")
    return out


def render_section(title: str, events: list[dict], new_ids: set, changed: dict) -> list[str]:
    if not events:
        return []

    lines = [f"# {title}", ""]
    by_day: dict[str, list[dict]] = defaultdict(list)
    for ev in events:
        by_day[ev.get("date", "")].append(ev)

    for day in sorted(by_day):
        lines += [f"## {pretty_day(day)}", ""]
        ranked = sorted(
            by_day[day],
            key=lambda e: (e.get("start_time") or "99:99", -e.get("fit_score", 0)),
        )
        for ev in ranked:
            eid = ev.get("id")
            marker = "[NEW] " if eid in new_ids else ("[UPD] " if eid in changed else "")
            lines += render_event(ev, marker, changed.get(eid))

    return lines


def build_report(payload: dict, result: dict) -> str:
    events = result["events"]
    new_ids, changed = result["new"], result["changed"]
    win = payload.get("window", {})

    lines = [
        f"# Event Radar - {payload.get('city', 'Unknown')}",
        "",
        f"**{pretty_day(win.get('start', ''))} to {pretty_day(win.get('end', ''))}**  ",
        f"Generated {datetime.now().astimezone().strftime('%Y-%m-%d %H:%M %Z')}",
        "",
        f"{len(new_ids)} new · {len(changed)} changed · {len(events)} total (fit >= {MIN_FIT})",
        "",
        "---",
        "",
    ]

    in_person = [e for e in events if not e.get("is_online")]
    online = [e for e in events if e.get("is_online")]

    if not events:
        lines += ["Nothing matched this run.", ""]

    lines += render_section("In person", in_person, new_ids, changed)
    lines += render_section("Online", online, new_ids, changed)

    if payload.get("thin_days"):
        lines += [
            "---", "", "## Thin days", "",
            ", ".join(pretty_day(d) for d in payload["thin_days"]), "",
            "*Check again closer to the date - events post 2-5 days ahead.*", "",
        ]

    if payload.get("gaps"):
        lines += ["## Gaps and caveats", ""]
        lines += [f"- {g}" for g in payload["gaps"]]
        lines.append("")

    if payload.get("calendars_to_watch"):
        lines += ["## Calendars to check manually", ""]
        lines += [f"- {c}" for c in payload["calendars_to_watch"]]
        lines.append("")

    return "\n".join(lines)


# -------------------------------------------------------------------- telegram

TG_LIMIT = 4000  # Telegram caps a message at 4096 chars.


def tg_event(ev: dict, is_new: bool, deltas: list[str] | None) -> str:
    name = ev.get("name", "Untitled") + (f" - {ev['host']}" if ev.get("host") else "")
    lines = [("NEW: " if is_new else "UPDATED: ") + name]

    minutes = (ev.get("transit") or {}).get("minutes")
    where = [f"{pretty_day(ev.get('date', ''))} {ev.get('start_time') or ''}".strip(),
             "online" if ev.get("is_online") else ev.get("venue"),
             f"~{minutes} min" if minutes is not None else None]
    lines.append(" · ".join(x for x in where if x))

    status = [str(ev["cost"]) if ev.get("cost") else None,
              ev["registration"].replace("_", " ") if ev.get("registration") else None,
              "card required" if ev.get("card_required") else None,
              f"fit {ev['fit_score']}/5" if ev.get("fit_score") is not None else None]
    if any(status):
        lines.append(" · ".join(x for x in status if x))
    if deltas:
        lines.append("changed: " + ", ".join(deltas))
    if ev.get("url"):
        lines.append(ev["url"])
    return "\n".join(lines)[:TG_LIMIT]


def tg_messages(result: dict) -> list[str]:
    """Delta only, packed into as few <=TG_LIMIT messages as fit. [] = stay silent."""
    new_ids, changed = result["new"], result["changed"]
    moved = sorted((e for e in result["events"] if e["id"] in new_ids or e["id"] in changed),
                   key=lambda e: (e.get("date", ""), e.get("start_time") or "99:99"))
    if not moved:
        return []
    msgs = [f"Event Radar: {len(new_ids)} new, {len(changed)} changed"]
    for ev in moved:
        block = tg_event(ev, ev["id"] in new_ids, changed.get(ev["id"]))
        if len(msgs[-1]) + 2 + len(block) > TG_LIMIT:
            msgs.append(block)
        else:
            msgs[-1] += "\n\n" + block
    return msgs


def send_telegram(msgs: list[str]) -> None:
    token, chat = os.environ.get("TELEGRAM_BOT_TOKEN"), os.environ.get("TELEGRAM_CHAT_ID")
    if not (token and chat):
        print("telegram not configured, skipping")
        return
    for text in msgs:
        body = urllib.parse.urlencode({"chat_id": chat, "text": text,
                                       "disable_web_page_preview": "true"}).encode()
        # Plain text on purpose: no parse_mode means no escaping bugs in event names.
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage",
                                    body, timeout=30) as resp:
            if not json.load(resp).get("ok"):
                raise RuntimeError("telegram returned ok=false")
    print(f"telegram: sent {len(msgs)} message(s)")


# ----------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("events_file", type=Path)
    ap.add_argument("--dry-run", action="store_true",
                    help="print the report; don't write files or update state")
    args = ap.parse_args()

    payload = load_json(args.events_file)
    if not isinstance(payload, dict):
        sys.exit(f"unreadable payload: {args.events_file}")

    events = payload.get("events") or []
    if not isinstance(events, list):
        sys.exit("payload.events is not a list")

    seen = load_state()
    result = classify(events, seen)
    report = build_report(payload, result)

    print(f"{len(events)} in run · {len(result['new'])} new · "
          f"{len(result['changed'])} changed")

    msgs = tg_messages(result)

    if args.dry_run:
        print("\n--- dry run ---\n")
        print(report)
        print(f"\n--- telegram ({len(msgs)} message(s)) ---")
        for m in msgs:
            print(f"\n[{len(m)} chars]\n{m}")
        return 0

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    dated = REPORT_DIR / f"{date.today().isoformat()}.md"
    dated.write_text(report, encoding="utf-8")
    # latest.md always points at the newest report - one stable path to open.
    (REPORT_DIR / "latest.md").write_text(report, encoding="utf-8")

    try:
        send_telegram(msgs)
    except Exception as exc:
        # str(exc) never includes the URL, so the token stays out of cron.log.
        print(f"telegram send failed, state NOT saved so the next run retries: {exc}")
        return 1

    for ev in result["events"]:
        seen[ev["id"]] = ev
    save_state(prune(seen))

    print(f"report: {dated}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
