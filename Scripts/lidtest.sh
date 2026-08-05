#!/bin/bash
#
# Endurance test for closed-lid mode.
#
# Records a heartbeat plus battery, thermal and power state every 30s, so a run can be
# checked for gaps and for the things a long run might hit that a short one will not:
# battery drain, thermal throttling, or macOS deciding to sleep anyway after some delay.
#
#   ./Scripts/lidtest.sh            # run until Ctrl-C
#   ./Scripts/lidtest.sh --report   # analyse the log from a finished run
#
# Procedure:
#   1. Plug in. An unattended closed laptop on battery is how you flatten a battery.
#   2. Turn Unblinking on with "Keep Awake With Lid Closed" ticked — the eye must be RED.
#   3. Start this script, close the lid, leave it for as long as you can (hours is ideal).
#   4. Reopen, Ctrl-C, then run with --report.
#
# For a meaningful result, do the same run with closed-lid mode OFF. Without that
# negative control, an absent gap could just mean the machine never tried to sleep.

set -uo pipefail

LOG="${LIDTEST_LOG:-$HOME/lidtest.log}"
INTERVAL="${LIDTEST_INTERVAL:-30}"

report() {
    [[ -f "$LOG" ]] || { echo "No log at $LOG" >&2; exit 1; }

    echo "=== $LOG ==="
    python3 - "$LOG" "$INTERVAL" <<'PY'
import sys, re
from datetime import datetime

path, interval = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(path):
    m = re.match(r'(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+batt=(\S+)\s+power=(\S+)\s+thermal=(\S+)', line)
    if m:
        rows.append((datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'), *m.groups()[1:]))

if len(rows) < 2:
    print("  not enough samples"); sys.exit(0)

span = (rows[-1][0] - rows[0][0]).total_seconds()
print(f"  window   : {rows[0][0]}  ->  {rows[-1][0]}")
print(f"  duration : {span/3600:.2f} h   ({len(rows)} samples)")

gaps = [(a[0], b[0], (b[0]-a[0]).total_seconds())
        for a, b in zip(rows, rows[1:]) if (b[0]-a[0]).total_seconds() > interval * 1.5]
if gaps:
    print(f"  GAPS     : {len(gaps)}  <-- the machine stopped running")
    for s, e, d in gaps[:10]:
        print(f"      {d:7.0f}s   {s}  ->  {e}")
else:
    print("  GAPS     : none  <-- ran continuously")

b0, b1 = rows[0][1].rstrip('%'), rows[-1][1].rstrip('%')
print(f"  battery  : {rows[0][1]} -> {rows[-1][1]}", end="")
try:
    drop = int(b0) - int(b1)
    if span > 0:
        print(f"   ({drop}% over {span/3600:.1f}h = {drop/(span/3600):.1f}%/h)")
    else:
        print()
except ValueError:
    print()

thermals = sorted({r[3] for r in rows})
print(f"  thermal  : {', '.join(thermals)}")
powers = sorted({r[2] for r in rows})
print(f"  power    : {', '.join(powers)}")
PY

    echo
    echo "=== kernel sleep events during the run ==="
    local first
    first=$(head -1 "$LOG" | cut -d' ' -f1-2)
    if pmset -g log 2>/dev/null | grep -E "Entering Sleep state|Clamshell Sleep" \
        | awk -v start="$first" '$0 >= start' | head -20 | grep .; then
        echo "  ^ the machine slept. If closed-lid mode was ON, that is a FAILURE."
    else
        echo "  none since the run began."
    fi
}

[[ "${1:-}" == "--report" ]] && { report; exit 0; }

echo "Logging to $LOG every ${INTERVAL}s. Ctrl-C to stop, then: $0 --report"
echo "Make sure the eye is RED (closed-lid mode on) before you shut the lid."
: > "$LOG"
while true; do
    batt=$(pmset -g batt | grep -Eo '[0-9]+%' | head -1)
    power=$(pmset -g batt | head -1 | grep -Eo "'.*'" | tr -d "'" | tr ' ' '_')
    thermal=$(pmset -g therm 2>/dev/null | grep -i "CPU_Speed_Limit" | grep -Eo '[0-9]+$')
    printf '%s batt=%s power=%s thermal=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${batt:-?}" "${power:-?}" "${thermal:-100}" >> "$LOG"
    sleep "$INTERVAL"
done
