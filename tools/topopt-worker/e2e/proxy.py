#!/usr/bin/env python3
"""proxy.py — a tiny recording TCP/HTTP proxy in front of the topopt-worker, used
by the liveness E2E harness (handoff 101) to simulate a mid-run network drop and
to OBSERVE every request the client sends (so a test can assert the client never
sent a DELETE except on explicit cancel).

It keeps the worker itself PRISTINE (the worker change this task ships is the
heartbeat only): a faithful "the SSE stream dropped" is a real severed socket, and
"was a DELETE sent?" is answered by watching the wire, not by trusting the client.

One request per client connection (no keep-alive) — URLSession simply opens a new
connection per request, which is exactly what a reconnect does.

Modes / env:
    TOPOPT_E2E_PROXY_LISTEN   listen port (required)
    TOPOPT_E2E_PROXY_BACKEND  worker port to forward to (required)
    TOPOPT_E2E_PROXY_LOG      path to append "<METHOD> <PATH>" for each request
    TOPOPT_E2E_PROXY_DROP     "events-once" → cut the FIRST /events connection
                              after relaying TOPOPT_E2E_PROXY_DROP_AFTER data
                              frames, simulating a mid-run stream drop.
    TOPOPT_E2E_PROXY_DROP_AFTER  data frames to relay before the drop (default 4).
"""

import os
import socket
import sys
import threading

LISTEN = int(os.environ["TOPOPT_E2E_PROXY_LISTEN"])
BACKEND = int(os.environ["TOPOPT_E2E_PROXY_BACKEND"])
LOG = os.environ.get("TOPOPT_E2E_PROXY_LOG")
DROP = os.environ.get("TOPOPT_E2E_PROXY_DROP", "")
DROP_AFTER = int(os.environ.get("TOPOPT_E2E_PROXY_DROP_AFTER", "4"))

_log_lock = threading.Lock()
_drop_lock = threading.Lock()
_dropped_once = False


def record(method, path):
    if not LOG:
        return
    with _log_lock:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (method, path))
            f.flush()


def read_headers(sock):
    """Read up to end-of-headers; return (raw_head_bytes, leftover_body_bytes)."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", rest


def force_close(head):
    """Rewrite the request headers to `Connection: close` so the worker (HTTP/1.1,
    keep-alive by default) closes after each response — otherwise this one-request-
    per-connection proxy would block waiting for a keep-alive socket that never
    ends. A reconnect opens a fresh connection anyway, so nothing is lost."""
    lines = head.split(b"\r\n")
    out = [lines[0]]
    for line in lines[1:]:
        low = line.lower()
        if low.startswith(b"connection:") or low.startswith(b"proxy-connection:"):
            continue
        if line == b"":
            continue
        out.append(line)
    out.append(b"Connection: close")
    return b"\r\n".join(out) + b"\r\n\r\n"


def content_length(head):
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            try:
                return int(line.split(b":", 1)[1].strip())
            except ValueError:
                return 0
    return 0


def send_502(client):
    try:
        body = b"proxy: backend unreachable"
        client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n"
                       b"Content-Type: text/plain\r\n"
                       b"Content-Length: %d\r\nConnection: close\r\n\r\n%s"
                       % (len(body), body))
    except OSError:
        pass


def relay_with_optional_drop(backend, client, path):
    """Relay backend->client. In events-once drop mode, cut the FIRST /events
    connection after DROP_AFTER SSE *data* frames (ignoring ": ping" comments)."""
    global _dropped_once
    do_drop = False
    if DROP == "events-once" and path.endswith("/events"):
        with _drop_lock:
            if not _dropped_once:
                _dropped_once = True
                do_drop = True

    if not do_drop:
        while True:
            try:
                chunk = backend.recv(4096)
            except OSError:
                break
            if not chunk:
                break
            try:
                client.sendall(chunk)
            except OSError:
                break
        return

    # Drop mode: frame the stream, forward whole frames, count data frames, cut.
    buf = b""
    data_frames = 0
    while True:
        try:
            chunk = backend.recv(4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n\n" in buf:
            frame, _, buf = buf.partition(b"\n\n")
            frame += b"\n\n"
            try:
                client.sendall(frame)
            except OSError:
                return
            if frame.lstrip().startswith(b"data:"):
                data_frames += 1
                if data_frames >= DROP_AFTER:
                    # Simulate the worker/network dropping the stream mid-run.
                    sys.stderr.write("proxy: DROPPING %s after %d data frames\n"
                                     % (path, data_frames))
                    sys.stderr.flush()
                    try:
                        client.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    return


def handle(client):
    try:
        head, body = read_headers(client)
        if not head.strip():
            return
        first = head.split(b"\r\n", 1)[0]
        parts = first.split(b" ")
        method = parts[0].decode("latin1") if parts else "?"
        path = parts[1].decode("latin1") if len(parts) > 1 else "?"
        record(method, path)

        # Read any remaining request body (POST /jobs multipart).
        need = content_length(head) - len(body)
        while need > 0:
            chunk = client.recv(min(65536, need))
            if not chunk:
                break
            body += chunk
            need -= len(chunk)

        try:
            backend = socket.create_connection(("127.0.0.1", BACKEND), timeout=5)
        except OSError:
            send_502(client)     # worker is down → probes fail → client sees unreachable
            return
        try:
            backend.sendall(force_close(head) + body)
            relay_with_optional_drop(backend, client, path)
        finally:
            backend.close()
    except OSError:
        pass
    finally:
        try:
            client.close()
        except OSError:
            pass


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", LISTEN))
    srv.listen(64)
    sys.stderr.write("proxy: listening on 127.0.0.1:%d -> 127.0.0.1:%d (drop=%r)\n"
                     % (LISTEN, BACKEND, DROP or "none"))
    sys.stderr.flush()
    while True:
        client, _ = srv.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
