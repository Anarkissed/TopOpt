#!/usr/bin/env bash
# run_e2e.sh — the handoff-101 liveness E2E harness. For one CASE it stands up the
# real tools/topopt-worker (wrapping the protocol-faithful stub_cli.py), optionally
# a recording proxy in front (to drop the stream / observe the wire), points the
# RemoteRunnerE2ETests at it via /tmp/topopt-e2e.json, and runs the single test on
# a macOS destination — proving the CLIENT (RemoteRunner + RunModel) handles the
# liveness path. All app-side + worker/proxy output is printed raw.
#
# Usage:  ./run_e2e.sh <case>        # one of: happy mismatch offline bad_mesh
#                                     #   reject_all cancel slow_sparse
#                                     #   stream_drop worker_dies
#         ./run_e2e.sh all           # every case, in sequence
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "$HERE/.." && pwd)"
WORKER="$WORKER_DIR/topopt_worker.py"
STUB="$HERE/stub_cli.py"
PROXY="$HERE/proxy.py"
PKG="$(cd "$HERE/../../../app/TopOptKit" && pwd)"
GENFP="$PKG/Sources/TopOptFlows/CoreFingerprint.generated.swift"

# The fingerprint the app was built against — the stub must report it so the
# version-skew guard passes. Parsed from the generated Swift, fallback to default.
FP="$(sed -n 's/.*value *= *"\([0-9a-f]*\)".*/\1/p' "$GENFP" 2>/dev/null | head -1)"
FP="${FP:-b9d0a2fb03e4}"

freeport() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

wait_health() {  # <port>
  for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$1/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

start_worker() {  # <port> <stub_mode> <gap> <heartbeat>
  local port="$1" mode="$2" gap="$3" hb="$4"
  TOPOPT_CLI="$STUB" TOPOPT_STUB_MODE="$mode" TOPOPT_STUB_GAP="$gap" \
    TOPOPT_STUB_FINGERPRINT="$FP" TOPOPT_HEARTBEAT_SECONDS="$hb" \
    TOPOPT_WORKER_DIR="$HERE/.e2e-work-$port" \
    python3 "$WORKER" --host 127.0.0.1 --port "$port" --cli "$STUB" \
    >"$HERE/.worker-$port.log" 2>&1 &
  PIDS+=($!)
}

start_proxy() {  # <listen> <backend> <droparg> <logfile>
  TOPOPT_E2E_PROXY_LISTEN="$1" TOPOPT_E2E_PROXY_BACKEND="$2" \
    TOPOPT_E2E_PROXY_DROP="$3" TOPOPT_E2E_PROXY_LOG="$4" \
    python3 "$PROXY" >"$HERE/.proxy-$1.log" 2>&1 &
  PIDS+=($!)
  sleep 0.4
}

run_case() {
  local CASE="$1"
  echo
  echo "############################################################"
  echo "# CASE: $CASE"
  echo "############################################################"

  local CLIENT_PORT GRACE PROXY_LOG WORKER_PORT
  GRACE=3
  PROXY_LOG=""

  case "$CASE" in
    offline)
      CLIENT_PORT=1 ;;                       # nothing listening → fast-fail
    happy|mismatch|bad_mesh|reject_all)
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$WORKER_PORT"
      start_worker "$WORKER_PORT" "$( [ "$CASE" = happy ] && echo normal || echo "$CASE" )" 0 20
      [ "$CASE" = mismatch ] && start_worker_noop
      wait_health "$WORKER_PORT" || { echo "worker failed to start"; return 1; } ;;
    cancel)
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$WORKER_PORT"
      start_worker "$WORKER_PORT" slow 0.3 20
      wait_health "$WORKER_PORT" || { echo "worker failed"; return 1; } ;;
    slow_sparse)
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$WORKER_PORT"; GRACE=2
      start_worker "$WORKER_PORT" slow_sparse 2.5 1   # gap>grace, heartbeat<grace
      wait_health "$WORKER_PORT" || { echo "worker failed"; return 1; } ;;
    stream_drop)
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$(freeport)"
      start_worker "$WORKER_PORT" normal 0.4 20
      wait_health "$WORKER_PORT" || { echo "worker failed"; return 1; }
      start_proxy "$CLIENT_PORT" "$WORKER_PORT" events-once "" ;;
    worker_dies)
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$(freeport)"; GRACE=3
      PROXY_LOG="$HERE/.proxy-reqs-$CLIENT_PORT.log"; : >"$PROXY_LOG"
      start_worker "$WORKER_PORT" dies 0.4 20
      wait_health "$WORKER_PORT" || { echo "worker failed"; return 1; }
      start_proxy "$CLIENT_PORT" "$WORKER_PORT" "" "$PROXY_LOG" ;;
    *) echo "unknown case $CASE"; return 2 ;;
  esac

  # Hand the client its config (a simulator/macOS xctest reads this host file).
  python3 - "$CLIENT_PORT" "$CASE" "$GRACE" "$PROXY_LOG" >/tmp/topopt-e2e.json <<'PY'
import json, sys
port, case, grace, plog = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = {"TOPOPT_E2E": "1", "TOPOPT_E2E_CASE": case,
     "TOPOPT_WORKER_PORT": port, "TOPOPT_INACTIVITY_GRACE": grace}
if plog:
    d["TOPOPT_PROXY_LOG"] = plog
print(json.dumps(d))
PY
  echo "-- /tmp/topopt-e2e.json --"; cat /tmp/topopt-e2e.json; echo

  ( cd "$PKG" && xcodebuild test \
      -scheme TopOptKit-Package -destination 'platform=macOS' \
      -only-testing:TopOptFlowsTests/RemoteRunnerE2ETests/testEndToEnd 2>&1 ) \
    | grep -E '^== E2E|^  |Test Case .*(passed|failed)|Executed .* test' \
    | grep -vE 'autoShortcut|Instance Registry|synchronousRemoteObjectProxy'

  cleanup; PIDS=()
}

# `mismatch` reuses `happy`'s worker (a healthy worker; the client sends a bad
# fingerprint and is refused before submit) — no second worker needed.
start_worker_noop() { :; }

# The handoff-121 QUEUE harness is pure-Python (no Xcode): the queue state machine
# (headless) + the HTTP-level /jobs golden, webhook, reorder, and pause/resume.
run_queue() {
  echo; echo "############################################################"
  echo "# CASE: queue (handoff 121 — headless + HTTP)"
  echo "############################################################"
  python3 "$HERE/queue_state_machine.py" && python3 "$HERE/queue_http_e2e.py"
}

if [ "${1:-}" = "all" ]; then
  for c in offline mismatch happy bad_mesh reject_all cancel slow_sparse stream_drop worker_dies; do
    run_case "$c"
  done
  run_queue
elif [ "${1:-}" = "queue" ]; then
  run_queue
else
  run_case "${1:?usage: run_e2e.sh <case|queue|all>}"
fi
