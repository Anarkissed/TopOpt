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
#                                     #   stream_drop worker_dies reattach
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
# The config file is what ARMS the otherwise-skipped E2E test. Left behind, it makes
# every later plain `swift test` run the gated case against a worker that is no
# longer listening — a green suite turning red for no code reason (handoff 134).
# Remove it when the harness exits, whatever the outcome.
trap 'cleanup; rm -f /tmp/topopt-e2e.json' EXIT

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

# Submit one job and BLOCK until the worker reports it terminal, echoing the job id
# (handoff 134). No SSE client is ever attached — the job runs, and finishes, with
# nobody watching, which is exactly the force-quit window the re-attach must survive.
submit_and_wait_done() {  # <port>  -> job_id on stdout
  python3 - "$1" <<'PY'
import http.client, json, sys, time
port = int(sys.argv[1])
boundary = "----e2e"
doc = {"model": "m.step", "material": "PLA", "resolution": 32,
       "mode": "minimize_plastic", "loads": {"anchor_face_ids": [1]}}
body = (
    '--%s\r\nContent-Disposition: form-data; name="step"; filename="m.step"\r\n'
    'Content-Type: application/octet-stream\r\n\r\nISO-10303-21;\r\n' % boundary
    + '--%s\r\nContent-Disposition: form-data; name="job"; filename="job.json"\r\n'
      'Content-Type: application/json\r\n\r\n%s\r\n' % (boundary, json.dumps(doc))
    + '--%s--\r\n' % boundary).encode()
c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
c.request("POST", "/jobs", body,
          {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
job = json.loads(c.getresponse().read())["job_id"]
for _ in range(600):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request("GET", "/jobs/%s" % job)
    snap = json.loads(c.getresponse().read())
    if snap.get("state") in ("done", "error", "cancelled"):
        sys.stderr.write("worker record: state=%s started=%s finished=%s\n"
                         % (snap["state"], snap["started_at"], snap["finished_at"]))
        print(job)
        sys.exit(0 if snap["state"] == "done" else 1)
    time.sleep(0.1)
sys.exit(1)
PY
}

run_case() {
  local CASE="$1"
  echo
  echo "############################################################"
  echo "# CASE: $CASE"
  echo "############################################################"

  local CLIENT_PORT GRACE PROXY_LOG WORKER_PORT JOB_ID
  GRACE=3
  PROXY_LOG=""
  JOB_ID=""

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
    reattach)
      # Handoff 134, item 2 — the re-attach QA repro at the HTTP level: submit a job,
      # then let it run to COMPLETION with NO client attached (the "app force-quit"
      # window), and only then hand the finished job's id to the relaunched client.
      # The solve is paced (0.5s × 6 progress events ≈ 3s) so the worker's recorded
      # duration is clearly LONGER than the client's attach window — which is what
      # makes "the duration is the worker's, not the observer's" a real assertion.
      WORKER_PORT="$(freeport)"; CLIENT_PORT="$WORKER_PORT"
      start_worker "$WORKER_PORT" normal 0.5 20
      wait_health "$WORKER_PORT" || { echo "worker failed to start"; return 1; }
      JOB_ID="$(submit_and_wait_done "$WORKER_PORT")" || {
        echo "job did not finish"; return 1; }
      echo "-- job $JOB_ID finished on the worker with no client attached --" ;;
    *) echo "unknown case $CASE"; return 2 ;;
  esac

  # Hand the client its config (a simulator/macOS xctest reads this host file).
  python3 - "$CLIENT_PORT" "$CASE" "$GRACE" "$PROXY_LOG" "${JOB_ID:-}" >/tmp/topopt-e2e.json <<'PY'
import json, sys
port, case, grace, plog, job = sys.argv[1:6]
d = {"TOPOPT_E2E": "1", "TOPOPT_E2E_CASE": case,
     "TOPOPT_WORKER_PORT": port, "TOPOPT_INACTIVITY_GRACE": grace}
if plog:
    d["TOPOPT_PROXY_LOG"] = plog
if job:
    d["TOPOPT_E2E_JOB_ID"] = job     # handoff 134: the completed job to re-attach to
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
  python3 "$HERE/queue_state_machine.py" \
    && python3 "$HERE/queue_http_e2e.py" \
    && python3 "$HERE/real_cli_smoke.py"   # handoff 129 item 3: schema-drift guard (skips if no CLI)
}

if [ "${1:-}" = "all" ]; then
  for c in offline mismatch happy bad_mesh reject_all cancel slow_sparse stream_drop worker_dies reattach; do
    run_case "$c"
  done
  run_queue
elif [ "${1:-}" = "queue" ]; then
  run_queue
else
  run_case "${1:?usage: run_e2e.sh <case|queue|all>}"
fi
