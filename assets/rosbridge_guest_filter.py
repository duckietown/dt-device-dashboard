#!/usr/bin/env python3
"""Proxy rosbridge and drop mutating messages from signed-out clients.

The filter listens on the port browsers already use. Rosbridge listens on a
localhost port only this process connects to, so same-origin /rosbridge and
ws://host:9001 share one gate. Pages under /dashboard/ stay on ws://host:9001
because device-proxy does not forward a websocket upgrade.

The handshake records whether the socket opened as a writer. Subscribe traffic
keeps that decision. Publish, advertise, and call_service call rosbridge_auth.php
again with the Cookie from the handshake and are dropped when X-Robot-Writer is
no longer 1.
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

LISTEN_PORT = int(os.environ.get("ROSBRIDGE_LISTEN_PORT", "9001"))
UPSTREAM_PORT = int(os.environ.get("ROSBRIDGE_UPSTREAM_PORT", "9002"))
UPSTREAM = ("127.0.0.1", UPSTREAM_PORT)
AUTH_SCRIPT = os.environ.get("ROSBRIDGE_AUTH_SCRIPT", "")
AUTH_SOCK = os.environ.get("ROSBRIDGE_AUTH_SOCK", "/run/php/php7.4-fpm.sock")
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 16 * 1024 * 1024
GUEST_OPS = {"subscribe", "unsubscribe", "png", "set_level"}
MUTATING_OPS = {"publish", "advertise", "call_service"}
FCGI_BEGIN_REQUEST = 1
FCGI_END_REQUEST = 3
FCGI_PARAMS = 4
FCGI_STDIN = 5
FCGI_STDOUT = 6
FCGI_RESPONDER = 1


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


def message_op(opcode: int, payload: bytes):
    if opcode != 1:
        return None, None
    try:
        msg = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None, None
    if not isinstance(msg, dict):
        return None, None
    op = msg.get("op")
    if not isinstance(op, str):
        return None, msg
    return op, msg


def allow_client_message(opcode: int, payload: bytes, handshake_writer: bool, still_writer) -> bool:
    """Subscribe stays on the handshake. Mutating ops ask rosbridge_auth.php again."""
    op, _msg = message_op(opcode, payload)
    if op in GUEST_OPS:
        return True
    if op in MUTATING_OPS or opcode != 1:
        return bool(still_writer())
    return bool(handshake_writer)


def _fcgi_record(rtype: int, content: bytes, request_id: int = 1) -> bytes:
    pad = (8 - (len(content) % 8)) % 8
    header = struct.pack("!BBHHBB", 1, rtype, request_id, len(content), pad, 0)
    return header + content + (b"\x00" * pad)


def _fcgi_len(n: int) -> bytes:
    if n < 128:
        return bytes([n])
    return struct.pack("!I", n | 0x80000000)


def _fcgi_nv(name: str, value: str) -> bytes:
    raw_name = name.encode("ascii")
    raw_value = value.encode("iso-8859-1", "replace")
    return _fcgi_len(len(raw_name)) + _fcgi_len(len(raw_value)) + raw_name + raw_value


def writer_flag_from_cgi(stdout: bytes) -> bool:
    head = stdout.split(b"\r\n\r\n", 1)[0]
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"x-robot-writer:"):
            return line.split(b":", 1)[1].strip() == b"1"
    return False


def _fcgi_stdout(blob: bytes) -> bytes:
    stdout = bytearray()
    buf = blob
    while len(buf) >= 8:
        _ver, rtype, _rid, clen, plen, _res = struct.unpack("!BBHHBB", buf[:8])
        total = 8 + clen + plen
        if len(buf) < total:
            break
        content = buf[8 : 8 + clen]
        buf = buf[total:]
        if rtype == FCGI_STDOUT:
            stdout += content
        elif rtype == FCGI_END_REQUEST:
            break
    return bytes(stdout)


def session_still_writer(cookie: str) -> bool:
    """Call rosbridge_auth.php with the handshake Cookie. Fail closed."""
    if not cookie.strip() or not AUTH_SCRIPT:
        return False
    params = {
        "SCRIPT_FILENAME": AUTH_SCRIPT,
        "SCRIPT_NAME": "/internal/rosbridge-auth",
        "REQUEST_METHOD": "GET",
        "QUERY_STRING": "",
        "REQUEST_URI": "/internal/rosbridge-auth",
        "SERVER_SOFTWARE": "rosbridge-guest-filter",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "GATEWAY_INTERFACE": "CGI/1.1",
        "CONTENT_LENGTH": "0",
        "HTTP_COOKIE": cookie,
    }
    body = b"".join(_fcgi_nv(key, value) for key, value in params.items())
    payload = b"".join(
        [
            _fcgi_record(FCGI_BEGIN_REQUEST, struct.pack("!HB5s", FCGI_RESPONDER, 0, b"")),
            _fcgi_record(FCGI_PARAMS, body),
            _fcgi_record(FCGI_PARAMS, b""),
            _fcgi_record(FCGI_STDIN, b""),
        ]
    )
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(2)
        sock.connect(AUTH_SOCK)
        sock.sendall(payload)
        blob = b""
        while not _fcgi_complete(blob):
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            blob += chunk
            if len(blob) > 1024 * 1024:
                break
        return writer_flag_from_cgi(_fcgi_stdout(blob))
    except OSError:
        return False
    finally:
        try:
            sock.close()
        except OSError:
            pass


def _fcgi_complete(blob: bytes) -> bool:
    buf = blob
    while len(buf) >= 8:
        _ver, rtype, _rid, clen, plen, _res = struct.unpack("!BBHHBB", buf[:8])
        total = 8 + clen + plen
        if len(buf) < total:
            return False
        buf = buf[total:]
        if rtype == FCGI_END_REQUEST:
            return True
    return False


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
            f"Host: 127.0.0.1:{UPSTREAM[1]}\r\n"
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


def pump_client_to_upstream(client, upstream, handshake_writer, cookie, client_lock, upstream_lock) -> None:
    reader = FrameReader(client)
    assembler = MessageAssembler()

    def still_writer() -> bool:
        return session_still_writer(cookie)

    try:
        while True:
            fin, opcode, payload = reader.read_frame()
            if opcode in (8, 9, 10):
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
            if kind != "data":
                send_frame(client, client_lock, 1, denial(None), mask=False)
                continue
            if allow_client_message(op, data, handshake_writer, still_writer):
                send_frame(upstream, upstream_lock, op, data, mask=True)
                continue
            _op_name, msg = message_op(op, data)
            # Do not forward the frame. Tell the client so a service call does not hang.
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
        cookie = headers.get("cookie", "")
        if "x-robot-writer" in headers:
            handshake_writer = headers.get("x-robot-writer", "") == "1"
        else:
            handshake_writer = session_still_writer(cookie)
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
                args=(conn, upstream, handshake_writer, cookie, client_lock, upstream_lock),
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


def open_listen_socket() -> socket.socket:
    """Bind the port clients already use, on every interface."""
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        sock.bind(("::", LISTEN_PORT))
        return sock
    except OSError:
        try:
            sock.close()
        except OSError:
            pass
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", LISTEN_PORT))
    except OSError as exc:
        print(
            f"ERROR: rosbridge guest filter could not listen on port {LISTEN_PORT} ({exc}). "
            f"Rosbridge must listen on 127.0.0.1:{UPSTREAM_PORT} so this filter can take the client port.",
            flush=True,
        )
        raise SystemExit(1) from exc
    return sock


def serve() -> None:
    sock = open_listen_socket()
    sock.listen(64)
    print(f"rosbridge guest filter listening on port {LISTEN_PORT}, upstream 127.0.0.1:{UPSTREAM_PORT}", flush=True)
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

    calls = {"n": 0}

    def still_false():
        calls["n"] += 1
        return False

    assert allow_client_message(1, payload, False, still_false)
    assert calls["n"] == 0
    assert allow_client_message(1, payload, True, still_false)
    assert calls["n"] == 0
    assert not allow_client_message(1, b'{"op":"publish","topic":"/led","id":"abc"}', True, still_false)
    assert calls["n"] == 1
    assert not allow_client_message(1, b'{"op":"advertise","topic":"/led"}', True, still_false)
    assert not allow_client_message(1, b'{"op":"call_service","service":"/led"}', True, still_false)
    assert allow_client_message(1, b'{"op":"publish"}', False, lambda: True)
    assert allow_client_message(1, b'{"op":"fragment"}', True, still_false)
    assert calls["n"] == 3
    assert not allow_client_message(1, b'{"op":"fragment"}', False, still_false)
    assert calls["n"] == 3
    assert not allow_client_message(2, b"\x00\x01", True, still_false)
    _op, msg = message_op(1, b'{"op":"publish","topic":"/led","id":"abc"}')
    assert msg["id"] == "abc"
    assert b"abc" in denial(msg)
    assert writer_flag_from_cgi(b"X-Robot-Writer: 1\r\nContent-Length: 0\r\n\r\n")
    assert not writer_flag_from_cgi(b"X-Robot-Writer: 0\r\n\r\n")
    assert not writer_flag_from_cgi(b"Status: 500\r\n\r\n")
    stdout_only = _fcgi_record(FCGI_STDOUT, b"X-Robot-Writer: 1\r\n\r\n") + _fcgi_record(
        FCGI_END_REQUEST, struct.pack("!IB3x", 0, 0)
    )
    assert writer_flag_from_cgi(_fcgi_stdout(stdout_only))

    assembler = MessageAssembler()
    assert assembler.push(False, 1, b'{"op":') is None
    kind, opcode, data, _fin = assembler.push(True, 0, b'"subscribe"}')
    assert kind == "data" and opcode == 1
    assert allow_client_message(opcode, data, False, still_false)
    if not os.environ.get("ROSBRIDGE_AUTH_SCRIPT"):
        assert session_still_writer("") is False
        assert session_still_writer("PHPSESSID=abc") is False
    _fcgi_roundtrip()
    print("rosbridge guest filter self-test ok")


def _fcgi_roundtrip() -> None:
    global AUTH_SCRIPT, AUTH_SOCK
    import tempfile

    directory = tempfile.mkdtemp(prefix="rosbridge-auth-")
    path = os.path.join(directory, "php.sock")
    previous = (AUTH_SCRIPT, AUTH_SOCK)
    AUTH_SCRIPT = "/user-data/packages/duckietown_duckiebot/tools/../assets/rosbridge_auth.php"
    AUTH_SOCK = path
    seen = {}

    def serve_once():
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        server.settimeout(2)
        conn, _addr = server.accept()
        blob = b""
        while True:
            if _request_finished(blob):
                break
            chunk = conn.recv(65536)
            if not chunk:
                break
            blob += chunk
        seen["cookie"] = b"PHPSESSID=logged-in" in blob
        seen["script"] = AUTH_SCRIPT.encode() in blob
        body = b"X-Robot-Writer: 0\r\nContent-Length: 0\r\n\r\n"
        conn.sendall(
            _fcgi_record(FCGI_STDOUT, body) + _fcgi_record(FCGI_END_REQUEST, struct.pack("!IB3x", 0, 0))
        )
        conn.close()
        server.close()

    thread = threading.Thread(target=serve_once)
    thread.start()
    try:
        assert session_still_writer("PHPSESSID=logged-in") is False
    finally:
        thread.join(3)
        AUTH_SCRIPT, AUTH_SOCK = previous
        try:
            os.remove(path)
            os.rmdir(directory)
        except OSError:
            pass
    assert seen.get("cookie") and seen.get("script")


def _request_finished(blob: bytes) -> bool:
    buf = blob
    while len(buf) >= 8:
        _ver, rtype, _rid, clen, plen, _res = struct.unpack("!BBHHBB", buf[:8])
        total = 8 + clen + plen
        if len(buf) < total:
            return False
        buf = buf[total:]
        if rtype == FCGI_STDIN and clen == 0:
            return True
    return False


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        _self_test()
    else:
        serve()
