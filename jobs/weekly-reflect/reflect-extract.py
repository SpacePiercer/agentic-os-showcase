"""Mine the week's Claude Code transcripts into raw signal for /reflect.

Pulls user messages from ~/.claude/projects/*/*.jsonl modified in the last N
days (default 7), strips harness boilerplate, and prints them grouped by
project, oldest first. The /reflect skill clusters these into candidate
skills/automations/fixes.

Usage:  python reflect-extract.py [days]      (default 7)
"""
import json, glob, os, sys, time

DAYS = int(sys.argv[1]) if len(sys.argv) > 1 else 7
cutoff = time.time() - DAYS * 86400
cutoff_day = time.strftime("%Y-%m-%d", time.localtime(cutoff))

BOILERPLATE = ("<local-command", "<command-name>", "<command-message>",
               "<system-reminder", "<task-notification", "Caveat:",
               "[Request interrupted", "[Image", "## Context Usage",
               "<bash-input>", "<bash-stdout>", "Base directory for this skill:",
               "This session is being continued", "/compact")

def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(x.get("text", "") for x in c
                        if isinstance(x, dict) and x.get("type") == "text")
    return ""

rows = []
for f in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
    if os.path.getmtime(f) < cutoff:
        continue
    proj = os.path.basename(os.path.dirname(f)).replace("C--Users-" + os.environ.get("USERNAME", ""), "") or "(home)"
    try:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                if j.get("type") != "user":
                    continue
                txt = text_of(j.get("message", {})).strip().replace("\n", " ")
                if not txt or any(txt.startswith(p) for p in BOILERPLATE):
                    continue
                if txt.startswith("[{") or "tool_result" in txt[:30]:
                    continue
                ts = j.get("timestamp", "")
                if ts[:10] < cutoff_day:      # old message in a recently-touched file
                    continue
                if len(txt) > 400:
                    txt = txt[:400] + "..."
                rows.append((ts, proj, txt))
    except OSError:
        pass

rows.sort()
print(f"{len(rows)} user messages, last {DAYS} days\n")
for ts, proj, txt in rows:
    print(f"[{ts[:10]}] ({proj[:35]}) {txt}")

# ponytail: one runnable check so the parser/filter can't silently break
if __name__ == "__main__" and os.environ.get("REFLECT_SELFTEST"):
    assert not any(t[2].startswith(BOILERPLATE) for t in rows), "boilerplate leaked"
    print("\nselftest ok")
