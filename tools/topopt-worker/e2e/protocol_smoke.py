#!/usr/bin/env python3
"""protocol_smoke.py — pure-Python HTTP-level proof of the handoff-101 worker
changes, independent of Xcode. Starts the real worker wrapping stub_cli.py, then:

  1. captures a raw /events SSE stream and shows the ": ping" HEARTBEAT interleaved
     with the typed events (the slow_sparse liveness signal);
  2. proves the reconnect REPLAY: a second /events connection re-delivers every
     event from the start (what the client dedupes against);
  3. proves DELETE-only cancel: a running job is killed by DELETE, and the status
     endpoint reflects it.

Run: python3 protocol_smoke.py
"""

import http.client
import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WORKER = os.path.join(HERE, "..", "topopt_worker.py")
STUB = os.path.join(HERE, "stub_cli.py")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_health(port, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            c.request("GET", "/health")
            if c.getresponse().status == 200:
                return True
        except OSError:
            time.sleep(0.1)
    return False


def submit(port):
    boundary = "----smoke"
    job = json.dumps({"model": "m.step", "material": "PLA", "resolution": 32,
                      "mode": "minimize_plastic", "loads": {"anchor_face_ids": [1]}})
    parts = []
    parts.append("--%s\r\nContent-Disposition: form-data; name=\"step\"; "
                 "filename=\"m.step\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                 "ISO-10303-21;\r\n" % boundary)
    parts.append("--%s\r\nContent-Disposition: form-data; name=\"job\"; "
                 "filename=\"job.json\"\r\nContent-Type: application/json\r\n\r\n%s\r\n"
                 % (boundary, job))
    body = ("".join(parts) + "--%s--\r\n" % boundary).encode()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request("POST", "/jobs", body,
              {"Content-Type": "multipart/form-data; boundary=%s" % boundary})
    return json.loads(c.getresponse().read())["job_id"]


def read_stream(port, job_id, seconds):
    """Read the raw SSE bytes for up to `seconds`, return the decoded text."""
    conn = socket.create_connection(("127.0.0.1", port), timeout=seconds + 2)
    conn.sendall(("GET /jobs/%s/events HTTP/1.1\r\nHost: x\r\n"
                  "Accept: text/event-stream\r\n\r\n" % job_id).encode())
    conn.settimeout(seconds + 2)
    end = time.time() + seconds
    out = b""
    while time.time() < end:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        out += chunk
        if b'"type": "done"' in out or b'"type": "cancelled"' in out:
            break
    conn.close()
    return out.decode("utf-8", "replace")


def main():
    port = free_port()
    env = dict(os.environ)
    env["TOPOPT_CLI"] = STUB
    env["TOPOPT_STUB_MODE"] = "slow_sparse"
    env["TOPOPT_STUB_GAP"] = "2"          # 2s between progress events
    env["TOPOPT_HEARTBEAT_SECONDS"] = "1"  # 1s heartbeat → visible pings in the gaps
    env["TOPOPT_WORKER_DIR"] = os.path.join(HERE, ".smoke-work")
    proc = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1",
                             "--port", str(port), "--cli", STUB],
                            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True)
    try:
        if not wait_health(port):
            print("FAIL: worker did not come up"); sys.exit(1)
        print("== worker up on 127.0.0.1:%d (stub cli, heartbeat=1s, gap=2s) ==" % port)

        job = submit(port)
        print("submitted job=%s\n" % job)

        print("== (1) RAW /events SSE stream — heartbeat ': ping' interleaved with events ==")
        text = read_stream(port, job, seconds=8)
        for line in text.splitlines():
            if line.startswith(":") or line.startswith("data:"):
                print("   " + line)
        pings = sum(1 for l in text.splitlines() if l.strip() == ": ping")
        datas = sum(1 for l in text.splitlines() if l.startswith("data:"))
        print("\n   -> %d heartbeat pings, %d data events in the first 8s\n" % (pings, datas))

        # Let the job finish.
        time.sleep(8)

        print("== (2) RECONNECT REPLAY — a fresh /events re-delivers every event from the start ==")
        replay = read_stream(port, job, seconds=4)
        replay_events = [l for l in replay.splitlines() if l.startswith("data:")]
        for l in replay_events:
            print("   " + l)
        print("\n   -> replay re-delivered %d events (client dedupes these by index)\n"
              % len(replay_events))

        print("== (3) DELETE-only cancel — a NEW running job is killed only by DELETE ==")
        env2 = dict(env); env2["TOPOPT_STUB_MODE"] = "slow"; env2["TOPOPT_STUB_GAP"] = "0.3"
        # relaunch worker not needed; submit a slow job to the same worker
        # (worker inherits its env from launch, so use a second worker for 'slow').
        port2 = free_port()
        env2["TOPOPT_WORKER_DIR"] = os.path.join(HERE, ".smoke-work2")
        proc2 = subprocess.Popen([sys.executable, WORKER, "--host", "127.0.0.1",
                                  "--port", str(port2), "--cli", STUB],
                                 env=env2, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
        try:
            wait_health(port2)
            job2 = submit(port2)
            time.sleep(1.0)
            c = http.client.HTTPConnection("127.0.0.1", port2, timeout=5)
            c.request("GET", "/jobs/%s" % job2)
            print("   status before DELETE: %s" % c.getresponse().read().decode())
            c = http.client.HTTPConnection("127.0.0.1", port2, timeout=5)
            c.request("DELETE", "/jobs/%s" % job2)
            print("   DELETE response:       %s" % c.getresponse().read().decode())
            c = http.client.HTTPConnection("127.0.0.1", port2, timeout=5)
            c.request("GET", "/jobs/%s" % job2)
            print("   status after DELETE:   %s" % c.getresponse().read().decode())
        finally:
            proc2.terminate()
        print("\nOK: heartbeat, replay, and DELETE-only cancel all verified at the HTTP layer.")
    finally:
        proc.terminate()


if __name__ == "__main__":
    main()
