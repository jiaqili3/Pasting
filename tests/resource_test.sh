#!/bin/bash
# Resource budget test. Runs Pasting in isolated test mode (temp data dir, no menu bar icon,
# no hotkey, clipboard capture paused, invisible panel) — never touches the real store.
set -euo pipefail
APP="${APP:-$HOME/Applications/Pasting.app}/Contents/MacOS/Pasting"
DATA="$(mktemp -d /tmp/pasting-test.XXXXXX)"
LOG="$HOME/Library/Logs/Pasting-test.log"
: > "$LOG"
PASTING_DATA_DIR="$DATA" "$APP" --test resources axdrag >/dev/null 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$DATA"' EXIT

for i in $(seq 1 120); do [[ -f "$DATA/results.json" ]] && break; sleep 0.5; done
[[ -f "$DATA/results.json" ]] || { echo "FAIL: no results"; exit 1; }

# Idle CPU over 30 s (cumulative CPU time delta)
cpu_s() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
sleep 3; C0=$(cpu_s); sleep 30; C1=$(cpu_s)
IDLE_CPU=$(python3 -c "print(round(($C1-$C0)/30*100,3))")
IDLE_FP=$(footprint -p "$PID" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}' || true)

python3 - "$DATA/results.json" "$IDLE_CPU" "$IDLE_FP" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); cpu = float(sys.argv[2])
budgets = [
    ("idle footprint (MB)",            r["idle_mb"],            60),
    ("footprint with 500 items (MB)",  r["after_scroll_all_mb"], 150),
    ("growth over 50 open/close (MB)", r["growth_50_cycles_mb"], 5),
    ("panel open avg (ms)",            r["open_avg_ms"],        50),
    ("idle CPU over 30 s (%)",         cpu,                     1),
]
fail = False
for name, v, b in budgets:
    ok = v < b; fail |= not ok
    print(f"{'PASS' if ok else 'FAIL'}  {name:34s} {v:8.2f}  (budget < {b})")
for k in ["first_open_ms", "open_max_ms", "after_500_items_mb", "after_50_cycles_mb", "data_dir_mb", "items", "generate_s"]:
    print(f"      {k:34s} {r[k]:8.2f}" if isinstance(r[k], float) else f"      {k:34s} {r[k]}")
print("      footprint(1) at idle:", sys.argv[3] or "n/a")
sys.exit(1 if fail else 0)
PY
RC=$?
grep -E "AXDRAG" "$LOG" | tail -1
exit $RC
