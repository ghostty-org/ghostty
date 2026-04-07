#!/usr/bin/env python3
"""
Rate-limiting TCP proxy that preserves end-to-end backpressure.

Unlike a naive proxy that buffers internally, this one stops reading from
the server when it can't write to the client. This lets TCP backpressure
propagate all the way to the server, triggering TCP_NOTSENT_LOWAT-based
flow control.

Usage:
    python3 rate-limit-proxy.py [--rate BYTES_PER_SEC] [--listen PORT] [--target PORT]
"""

import argparse
import select
import socket
import sys
import time


def proxy_loop(client, server, rate_bps):
    """Single-threaded proxy that rate-limits server→client and propagates backpressure."""

    # Token bucket for rate limiting
    tokens = float(rate_bps)
    last_fill = time.monotonic()
    total_s2c = 0
    total_c2s = 0
    drops = 0

    while True:
        now = time.monotonic()
        elapsed = now - last_fill
        last_fill = now
        tokens = min(float(rate_bps), tokens + elapsed * rate_bps)

        fds_to_poll = []

        # Always listen for client input (to forward to server)
        fds_to_poll.append(client)

        # Only read from server if we have tokens to send to client.
        # This is the key: when we DON'T read, the server's TCP send
        # buffer fills up, TCP_NOTSENT_LOWAT triggers, and the server
        # stops sending raw pty data.
        if tokens >= 1:
            fds_to_poll.append(server)

        readable, _, errored = select.select(fds_to_poll, [], [client, server], 0.01)

        if errored:
            break

        # Client → Server (input, always forwarded immediately)
        if client in readable:
            try:
                data = client.recv(4096)
            except OSError:
                break
            if not data:
                break
            try:
                server.sendall(data)
                total_c2s += len(data)
            except OSError:
                break

        # Server → Client (rate-limited, with backpressure)
        if server in readable:
            # Only read as much as we can send
            max_read = min(int(tokens), 4096)
            if max_read < 1:
                continue

            try:
                data = server.recv(max_read)
            except OSError:
                break
            if not data:
                break

            try:
                client.sendall(data)
                tokens -= len(data)
                total_s2c += len(data)
            except OSError:
                break

    return total_s2c, total_c2s


def main():
    parser = argparse.ArgumentParser(description="Rate-limiting TCP proxy with backpressure")
    parser.add_argument("--rate", type=int, default=2048,
                        help="Max bytes/sec server→client (default: 2048)")
    parser.add_argument("--listen", type=int, default=7682,
                        help="Port to listen on (default: 7682)")
    parser.add_argument("--target", type=int, default=7681,
                        help="Target server port (default: 7681)")
    parser.add_argument("--target-host", default="127.0.0.1")
    args = parser.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.listen))
    srv.listen(5)

    print(f"[proxy] Listening on 0.0.0.0:{args.listen} → {args.target_host}:{args.target}", file=sys.stderr)
    print(f"[proxy] Rate: {args.rate:,} B/s | Backpressure: ON", file=sys.stderr)

    while True:
        client, addr = srv.accept()
        print(f"[proxy] Client {addr[0]}:{addr[1]}", file=sys.stderr)

        try:
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            # Small receive buffer so backpressure propagates to the server.
            # Without this, the kernel buffers 256KB+ from the server even
            # when we stop reading.
            server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            server.connect((args.target_host, args.target))
        except ConnectionError as e:
            print(f"[proxy] Cannot connect to target: {e}", file=sys.stderr)
            client.close()
            continue

        s2c, c2s = proxy_loop(client, server, args.rate)
        client.close()
        server.close()
        print(f"[proxy] Done. s→c: {s2c:,} B, c→s: {c2s:,} B", file=sys.stderr)


if __name__ == "__main__":
    main()
