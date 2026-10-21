#!/usr/bin/env python3
"""Proxy rosbridge and drop mutating messages from signed-out clients.

Guests may subscribe and receive telemetry. Publish, advertise, and service
calls are forwarded only when nginx sets X-Robot-Writer: 1 from the dashboard
session. The upstream handshake uses Host: 127.0.0.1:9001 so Autobahn accepts it.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading

LISTEN = ("127.0.0.1", 9002)
UPSTREAM = ("127.0.0.1", 9001)
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 16 * 1024 * 1024
GUEST_OPS = {"subscribe", "unsubscribe", "png", "set_level"}


class ConnectionClosed(Exception):
    pass


class FrameReader:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.buf = b""

    def _read_exact(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionClosed()
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_frame(self):
        b0 = self._read_exact(1)[0]
        b1 = self._read_exact(1)[0]
        fin = bool(b0 & 0x80)
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        length = b1 & 0x7F
        if length == 126:
            length = struct.unpack("!H", self._read_exact(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self._read_exact(8))[0]
        if length > MAX_FRAME:
            raise ConnectionClosed()
        mask = self._read_exact(4) if masked else None
        payload = self._read_exact(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return fin, opcode, payload


def encode_frame(opcode: int, payload: bytes, mask: bool, fin: bool = True) -> bytes:
    first = (0x80 if fin else 0) | (opcode & 0x0F)
    length = len(payload)
    mask_bit = 0x80 if mask else 0
    header = bytearray([first])
    if length < 126:
        header.append(mask_bit | length)
    elif length < 65536:
        header.append(mask_bit | 126)
        header += struct.pack("!H", length)
    else:
        header.append(mask_bit | 127)
        header += struct.pack("!Q", length)
    if mask:
        key = os.urandom(4)
        header += key
        payload = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    return bytes(header) + payload


class MessageAssembler:
    """Reassemble websocket data messages. Control frames are returned immediately."""

    def __init__(self):
        self.opcode = None
        self.parts = []

    def push(self, fin: bool, opcode: int, payload: bytes):
        if opcode in (8, 9, 10):
            return ("control", opcode, payload, fin)
        if opcode == 0:
            if self.opcode is None:
                return ("drop", 0, b"", True)
            self.parts.append(payload)
        elif opcode in (1, 2):
            self.opcode = opcode
            self.parts = [payload]
        else:
            return ("drop", opcode, payload, fin)
        if not fin:
            return None
        data = b"".join(self.parts)
        op = self.opcode
        self.opcode = None
        self.parts = []
        return ("data", op, data, True)


def guest_allows(payload: bytes):
    try:
        msg = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return False, None
    if not isinstance(msg, dict):
        return False, None
    if msg.get("op") in GUEST_OPS:
        return True, msg
    return False, msg


def denial(msg) -> bytes:
    body = {"op": "status", "level": "error", "msg": "Sign in to control the robot"}
    if isinstance(msg, dict) and msg.get("id") not in (None, ""):
        body["id"] = msg["id"]
    return json.dumps(body).encode("utf-8")


def read_http_headers(sock: socket.socket):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionClosed()
        data += chunk
        if len(data) > 65536:
            raise ConnectionClosed()
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.decode("iso-8859-1", "replace").split("\r\n")
    headers = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return lines[0] if lines else "", headers, rest


def accept_client(sock: socket.socket, headers: dict, protocol: str) -> None:
    key = headers.get("sec-websocket-key", "")
    accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
    extra = f"Sec-WebSocket-Protocol: {protocol}\r\n" if protocol else ""
    sock.sendall(
        (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            f"{extra}\r\n"
        ).encode("ascii")
    )


def connect_upstream(protocol: str) -> socket.socket:
    sock = socket.create_connection(UPSTREAM, timeout=5)
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    extra = f"Sec-WebSocket-Protocol: {protocol}\r\n" if protocol else ""
    sock.sendall(
        (
            "GET / HTTP/1.1\r\n"
            "Host: 127.0.0.1:9001\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"{extra}\r\n"
        ).encode("ascii")
    )
    _, headers, rest = read_http_headers(sock)
    if rest:
        sock = _PrefixedSocket(sock, rest)
    if "websocket" not in headers.get("upgrade", "").lower():
        sock.close()
        raise ConnectionClosed()
    return sock


class _PrefixedSocket:
    def __init__(self, sock: socket.socket, prefix: bytes):
        self._sock = sock
        self._prefix = prefix

    def recv(self, n: int) -> bytes:
        if self._prefix:
            out, self._prefix = self._prefix[:n], self._prefix[n:]
            return out
        return self._sock.recv(n)

    def sendall(self, data: bytes) -> None:
        self._sock.sendall(data)

    def close(self) -> None:
        self._sock.close()

    def settimeout(self, value) -> None:
        self._sock.settimeout(value)


def send_frame(sock, lock, opcode, payload, mask, fin=True) -> None:
    frame = encode_frame(opcode, payload, mask=mask, fin=fin)
    with lock:
        sock.sendall(frame)


def _close_pair(client, upstream) -> None:
    for sock in (client, upstream):
        try:
            sock.close()
        except OSError:
            pass


def pump_client_to_upstream(client, upstream, can_write, client_lock, upstream_lock) -> None:
    reader = FrameReader(client)
    assembler = MessageAssembler()
    try:
        while True:
            fin, opcode, payload = reader.read_frame()
            if can_write or opcode in (8, 9, 10):
                send_frame(upstream, upstream_lock, opcode, payload, mask=True, fin=fin)
                if opcode == 8:
                    return
                continue
            item = assembler.push(fin, opcode, payload)
            if item is None:
                continue
            kind, op, data, _fin = item
            if kind == "control":
                send_frame(upstream, upstream_lock, op, data, mask=True, fin=True)
                if op == 8:
                    return
                continue
            if kind != "data" or op != 1:
                send_frame(client, client_lock, 1, denial(None), mask=False)
                continue
            allowed, msg = guest_allows(data)
            if allowed:
                send_frame(upstream, upstream_lock, 1, data, mask=True)
            else:
                send_frame(client, client_lock, 1, denial(msg), mask=False)
    except (ConnectionClosed, OSError):
        return
    finally:
        _close_pair(client, upstream)


def pump_upstream_to_client(upstream, client, client_lock) -> None:
    reader = FrameReader(upstream)
    try:
        while True:
            fin, opcode, payload = reader.read_frame()
            send_frame(client, client_lock, opcode, payload, mask=False, fin=fin)
            if opcode == 8:
                return
    except (ConnectionClosed, OSError):
        return
    finally:
        _close_pair(client, upstream)


def handle(conn: socket.socket) -> None:
    upstream = None
    try:
        conn.settimeout(15)
        request, headers, rest = read_http_headers(conn)
        if rest:
            conn = _PrefixedSocket(conn, rest)
        if not request.startswith("GET "):
            conn.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            return
        if headers.get("upgrade", "").lower() != "websocket":
            conn.sendall(b"HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
            return
        can_write = headers.get("x-robot-writer", "") == "1"
        protocol = headers.get("sec-websocket-protocol", "")
        upstream = connect_upstream(protocol)
        upstream.settimeout(None)
        conn.settimeout(None)
        accept_client(conn, headers, protocol)
        client_lock = threading.Lock()
        upstream_lock = threading.Lock()
        threads = [
            threading.Thread(
                target=pump_client_to_upstream,
                args=(conn, upstream, can_write, client_lock, upstream_lock),
                daemon=True,
            ),
            threading.Thread(
                target=pump_upstream_to_client,
                args=(upstream, conn, client_lock),
                daemon=True,
            ),
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    except ConnectionClosed:
        pass
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except OSError:
                pass


def serve() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(LISTEN)
    sock.listen(64)
    print(f"rosbridge guest filter listening on {LISTEN[0]}:{LISTEN[1]}", flush=True)
    while True:
        conn, _addr = sock.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


def _self_test() -> None:
    payload = b'{"op":"subscribe","topic":"/x"}'
    frame = encode_frame(1, payload, mask=True)
    pair = socket.socketpair()
    pair[0].sendall(frame)
    pair[0].shutdown(socket.SHUT_WR)
    reader = FrameReader(pair[1])
    fin, opcode, decoded = reader.read_frame()
    assert fin and opcode == 1 and decoded == payload

    allowed, _msg = guest_allows(payload)
    assert allowed
    denied, msg = guest_allows(b'{"op":"publish","topic":"/led","id":"abc"}')
    assert not denied and msg["id"] == "abc"
    assert b"abc" in denial(msg)

    assembler = MessageAssembler()
    assert assembler.push(False, 1, b'{"op":') is None
    kind, opcode, data, _fin = assembler.push(True, 0, b'"subscribe"}')
    assert kind == "data" and opcode == 1
    assert guest_allows(data)[0]
    print("rosbridge guest filter self-test ok")


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _self_test()
    else:
        serve()
