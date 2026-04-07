#!/usr/bin/env python3
"""
Debug TCP proxy that logs every byte at every point in the pipeline.

Writes hex dumps to /tmp/ghostty-debug/ with timestamps.
Files:
  server-to-proxy.bin   — raw bytes from server
  proxy-to-client.bin   — raw bytes to client (same, but after rate limiting)
  client-to-proxy.bin   — raw bytes from client
  proxy-to-server.bin   — raw bytes to server (same)
  frames.log            — decoded frame log with timestamps

Usage:
    python3 debug-proxy.py [--rate BYTES/S] [--listen PORT] [--target PORT]
"""

import argparse
import os
import select
import socket
import struct
import sys
import time


LOG_DIR = "/tmp/ghostty-debug"


class FrameLogger:
    """Logs raw bytes and decoded frames."""

    def __init__(self):
        os.makedirs(LOG_DIR, exist_ok=True)
        self.s2p = open(f"{LOG_DIR}/server-to-proxy.bin", "wb")
        self.p2c = open(f"{LOG_DIR}/proxy-to-client.bin", "wb")
        self.c2p = open(f"{LOG_DIR}/client-to-proxy.bin", "wb")
        self.p2s = open(f"{LOG_DIR}/proxy-to-server.bin", "wb")
        self.log = open(f"{LOG_DIR}/frames.log", "w")
        self.s2c_parser = FrameParser("S→C")
        self.c2s_parser = FrameParser("C→S")
        self.start = time.monotonic()

    def ts(self):
        return f"{time.monotonic() - self.start:10.3f}"

    def server_to_proxy(self, data):
        self.s2p.write(data)
        self.s2p.flush()
        self.log.write(f"[{self.ts()}] server→proxy: {len(data)} bytes\n")
        self.s2c_parser.feed(data, self.log, self.ts())

    def proxy_to_client(self, data):
        self.p2c.write(data)
        self.p2c.flush()

    def client_to_proxy(self, data):
        self.c2p.write(data)
        self.c2p.flush()
        self.log.write(f"[{self.ts()}] client→proxy: {len(data)} bytes\n")
        self.c2s_parser.feed(data, self.log, self.ts())

    def proxy_to_server(self, data):
        self.p2s.write(data)
        self.p2s.flush()

    def close(self):
        self.s2p.close()
        self.p2c.close()
        self.c2p.close()
        self.p2s.close()
        self.log.write(f"[{self.ts()}] === CONNECTION CLOSED ===\n")
        self.log.flush()
        self.log.close()


MSG_NAMES = {
    0x01: "PTY_DATA",
    0x02: "SNAPSHOT",
    0x03: "SCROLLBACK",
    0x04: "RESIZE_ACK",
    0x81: "INPUT",
    0x82: "RESIZE",
}


class FrameParser:
    """Incrementally parse framed messages and log them."""

    def __init__(self, direction):
        self.direction = direction
        self.buf = b""
        self.frame_count = 0
        self.total_bytes = 0

    def feed(self, data, log, ts):
        self.buf += data
        self.total_bytes += len(data)

        while len(self.buf) >= 4:
            msg_type = self.buf[0]
            msg_len = (self.buf[1] << 16) | (self.buf[2] << 8) | self.buf[3]
            total = 4 + msg_len

            if len(self.buf) < total:
                # Partial frame — log it
                log.write(f"  [{ts}] {self.direction} PARTIAL frame: "
                          f"type={MSG_NAMES.get(msg_type, f'0x{msg_type:02x}')} "
                          f"declared_len={msg_len} have={len(self.buf)-4} "
                          f"waiting_for={total - len(self.buf)} more bytes\n")
                log.flush()
                return

            self.frame_count += 1
            payload = self.buf[4:total]
            self.buf = self.buf[total:]

            name = MSG_NAMES.get(msg_type, f"UNKNOWN(0x{msg_type:02x})")

            # Log frame
            detail = ""
            if msg_type == 0x82:  # RESIZE
                if len(payload) == 4:
                    cols = (payload[0] << 8) | payload[1]
                    rows = (payload[2] << 8) | payload[3]
                    detail = f" cols={cols} rows={rows}"
            elif msg_type == 0x01:  # PTY_DATA
                # Show first 80 chars of payload as text (escape non-printable)
                preview = ""
                for b in payload[:80]:
                    if b == 0x1b:
                        preview += "^["
                    elif 32 <= b < 127:
                        preview += chr(b)
                    elif b == 10:
                        preview += "\\n"
                    elif b == 13:
                        preview += "\\r"
                    else:
                        preview += f"<{b:02x}>"
                detail = f' "{preview}"'
                if len(payload) > 80:
                    detail += "..."
            elif msg_type == 0x02:  # SNAPSHOT
                detail = f" (VT snapshot)"
            elif msg_type == 0x03:  # SCROLLBACK
                detail = f" (scrollback text)"

            log.write(f"  [{ts}] {self.direction} #{self.frame_count}: "
                      f"{name} {len(payload)}B{detail}\n")
            log.flush()

            # Check for frame alignment issues
            if msg_type not in MSG_NAMES:
                log.write(f"  [{ts}] *** WARNING: unknown frame type 0x{msg_type:02x} — "
                          f"possible frame alignment corruption! ***\n")
                # Dump context
                log.write(f"  [{ts}]     raw header: {self.buf[:20].hex() if len(self.buf) >= 20 else self.buf.hex()}\n")
                log.flush()


def proxy_loop(client, server, rate_bps, logger):
    tokens = float(rate_bps)
    last_fill = time.monotonic()

    while True:
        now = time.monotonic()
        elapsed = now - last_fill
        last_fill = now
        tokens = min(float(rate_bps), tokens + elapsed * rate_bps)

        fds_to_poll = [client]
        if tokens >= 1:
            fds_to_poll.append(server)

        try:
            readable, _, errored = select.select(fds_to_poll, [], [client, server], 0.01)
        except (ValueError, OSError):
            break

        if errored:
            break

        if client in readable:
            try:
                data = client.recv(4096)
            except OSError:
                break
            if not data:
                break
            logger.client_to_proxy(data)
            try:
                server.sendall(data)
                logger.proxy_to_server(data)
            except OSError:
                break

        if server in readable:
            max_read = min(int(tokens), 4096)
            if max_read < 1:
                continue
            try:
                data = server.recv(max_read)
            except OSError:
                break
            if not data:
                break
            logger.server_to_proxy(data)
            try:
                client.sendall(data)
                logger.proxy_to_client(data)
                tokens -= len(data)
            except OSError:
                break


def main():
    parser = argparse.ArgumentParser(description="Debug TCP proxy with full byte logging")
    parser.add_argument("--rate", type=int, default=20480, help="Bytes/sec (default: 20480)")
    parser.add_argument("--listen", type=int, default=7682, help="Listen port (default: 7682)")
    parser.add_argument("--target", type=int, default=7681, help="Target port (default: 7681)")
    args = parser.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.listen))
    srv.listen(5)

    print(f"[debug-proxy] {args.listen} → {args.target} @ {args.rate} B/s", file=sys.stderr)
    print(f"[debug-proxy] Logs: {LOG_DIR}/", file=sys.stderr)

    while True:
        client, addr = srv.accept()
        print(f"[debug-proxy] Client {addr[0]}:{addr[1]}", file=sys.stderr)

        try:
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            server.connect(("127.0.0.1", args.target))
        except ConnectionError as e:
            print(f"[debug-proxy] Can't connect: {e}", file=sys.stderr)
            client.close()
            continue

        logger = FrameLogger()
        proxy_loop(client, server, args.rate, logger)
        logger.close()
        client.close()
        server.close()

        print(f"[debug-proxy] Done. Logs in {LOG_DIR}/", file=sys.stderr)


if __name__ == "__main__":
    main()
