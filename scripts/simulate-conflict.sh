#!/bin/bash
# Simulates a real port conflict for PortPilot manual testing.
#
# Two python processes bind to the same port (9999) via different address
# families (IPv4 + IPv6-only). The kernel allows this because IPV6_V6ONLY
# tells the IPv6 socket to ignore IPv4-mapped traffic, so the two binds
# don't overlap at the socket level — but PortPilot still sees two entries
# on port 9999 with different PIDs, which is exactly what ConflictDetector flags.
#
# Usage:
#   ./scripts/simulate-conflict.sh          # launch both binders (blocks)
#   Ctrl-C once to resolve, Ctrl-C twice to exit

set -euo pipefail

PORT="${1:-9999}"

cleanup() {
    echo ""
    echo "Cleaning up..."
    kill "$PID4" 2>/dev/null || true
    kill "$PID6" 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

echo "Starting IPv4 binder on 0.0.0.0:$PORT..."
python3 -c "
import socket, time, os
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $PORT))
s.listen()
print(f'[IPv4] pid={os.getpid()} bound to 0.0.0.0:$PORT', flush=True)
time.sleep(86400)
" &
PID4=$!

sleep 0.3

echo "Starting IPv6-only binder on [::]:$PORT..."
python3 -c "
import socket, time, os
s = socket.socket(socket.AF_INET6)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.bind(('::', $PORT))
s.listen()
print(f'[IPv6] pid={os.getpid()} bound to [::]:$PORT', flush=True)
time.sleep(86400)
" &
PID6=$!

sleep 0.3

echo ""
echo "✓ Conflict active on port $PORT (pids $PID4 + $PID6)"
echo "  Check PortPilot for: red lighthouse, red row highlights, macOS notification"
echo "  Ctrl-C to stop both processes"
echo ""

wait
