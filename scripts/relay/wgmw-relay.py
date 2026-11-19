#!/usr/bin/env python3
"""wgmw-relay - carry the client-facing WireGuard socket over a tcp connection.

Normally clients reach the middle's wg0 directly on udp/51820 and the router
forwards that port. When the home line cannot accept inbound packets (carrier
grade NAT, a router that drops inbound udp, no port forward at all) the middle
can instead keep an outbound connection to the exit, and the exit accepts the
clients' datagrams and hands them over that connection.

    clients --udp/51820--> exit (server mode) <--tcp/7000-- middle (client mode) --> 127.0.0.1:51820 (wg0)

Two details make this work with WireGuard, which addresses peers by source
address and port:

* every remote client gets its own id, and on the middle every id gets its own
  socket towards wg0, so two phones never share a source port and therefore
  never share a handshake state;
* the connection is authenticated with HMAC-SHA256 over a random nonce, so an
  open control port on the exit cannot be used by anybody else.

The payload is always WireGuard ciphertext; this relay never inspects it.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import logging
import os
import selectors
import socket
import struct
import sys
import time

HEAD = struct.Struct("!BHH")  # type, client id, payload length
T_DATA = 1
T_KEEPALIVE = 2
T_CLOSE = 3

OK_BYTES = b"OK\n"
MAX_PAYLOAD = 65535
IDLE_TIMEOUT = 120.0  # seconds without traffic before a client mapping is freed
KEEPALIVE = 20.0
DEAD_PEER = 90.0
BACKOFF_MAX = 30.0

log = logging.getLogger("wgmw-relay")


# ---------------------------------------------------------------- helpers


def parse_addr(text: str, default_port: int | None = None) -> tuple[str, int]:
    """Accept host:port, [v6]:port and a bare port number."""
    text = text.strip()
    if text.startswith("["):
        host, _, rest = text[1:].partition("]")
        port = rest.lstrip(":") or default_port
        return host, int(port)
    if text.isdigit() and default_port is not None:
        return "0.0.0.0", int(text)
    if text.count(":") == 1:
        host, _, port = text.partition(":")
        return host, int(port)
    if text.count(":") > 1:  # bare ipv6 literal, no port
        return text, int(default_port or 0)
    return text, int(default_port or 0)


def load_secret(args) -> bytes:
    if args.secret:
        return args.secret.encode()
    if args.secret_file:
        try:
            with open(args.secret_file, "rb") as fh:
                data = fh.read().strip()
        except OSError as exc:
            sys.exit(f"wgmw-relay: cannot read {args.secret_file}: {exc}")
        if not data:
            sys.exit(f"wgmw-relay: {args.secret_file} is empty")
        return data
    sys.exit("wgmw-relay: --secret or --secret-file is required")


def recv_exactly(sock: socket.socket, count: int, what: str) -> bytes:
    """Read exactly count bytes; anything less is a broken peer."""
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError(what)
        buf += chunk
    return buf


def frame(kind: int, client_id: int, payload: bytes = b"") -> bytes:
    return HEAD.pack(kind, client_id, len(payload)) + payload


class FrameReader:
    """Reassembles frames from a stream socket."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> list[tuple[int, int, bytes]]:
        self._buf.extend(data)
        out = []
        while len(self._buf) >= HEAD.size:
            kind, client_id, length = HEAD.unpack_from(self._buf, 0)
            if length > MAX_PAYLOAD:
                raise ValueError(f"frame of {length} bytes is too large")
            total = HEAD.size + length
            if len(self._buf) < total:
                break
            payload = bytes(self._buf[HEAD.size:total])
            del self._buf[:total]
            out.append((kind, client_id, payload))
        return out


# ---------------------------------------------------------------- server


def bind_udp(host: str, port: int) -> socket.socket:
    """Bind the client entry point.

    host "auto" means: the wildcard address, unless something (the exit's own
    WireGuard socket on 127.0.0.1) already holds that port - then bind the
    machine's primary address, which is the one clients reach anyway.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if host != "auto":
        sock.bind((host, port))
        return sock
    try:
        sock.bind(("0.0.0.0", port))
        return sock
    except OSError:
        sock.close()
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("1.1.1.1", 80))
        primary = probe.getsockname()[0]
    finally:
        probe.close()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((primary, port))
    log.info("port %d is taken on the wildcard address, bound %s instead", port, primary)
    return sock


class Server:
    """Runs on the public machine: udp entry point + one tcp home connection."""

    def __init__(self, secret: bytes, listen: tuple[str, int], control: tuple[str, int]):
        self.secret = secret
        self.udp = bind_udp(listen[0], listen[1])
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(control)
        self.srv.listen(4)
        self.srv.setblocking(False)
        self.conn: socket.socket | None = None
        self.reader = FrameReader()
        self.by_addr: dict[tuple[str, int], int] = {}
        self.by_id: dict[int, list] = {}  # id -> [addr, last_seen]
        self.next_id = 1
        self.last_rx = 0.0

    # -- connection handling -------------------------------------------------

    def _accept(self) -> None:
        try:
            conn, peer = self.srv.accept()
        except OSError as exc:
            log.warning("accept failed: %s", exc)
            return
        conn.setblocking(True)
        conn.settimeout(10.0)
        try:
            nonce = os.urandom(32)
            conn.sendall(nonce)
            answer = recv_exactly(conn, 32, "peer left during the handshake")
            expected = hmac.new(self.secret, nonce, hashlib.sha256).digest()
            if not hmac.compare_digest(answer, expected):
                log.warning("rejected %s: wrong secret", peer[0])
                conn.close()
                return
            conn.sendall(OK_BYTES)
            conn.settimeout(None)
        except (OSError, ConnectionError) as exc:
            log.warning("handshake with %s failed: %s", peer[0], exc)
            try:
                conn.close()
            except OSError:
                pass
            return

        if self.conn is not None:
            log.info("replacing the previous home connection")
            self._drop_connection()
        self.conn = conn
        self.reader = FrameReader()
        self.last_rx = time.monotonic()
        log.info("home side connected from %s:%s", peer[0], peer[1])

    def _drop_connection(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except OSError:
                pass
        self.conn = None
        for client_id in list(self.by_id):
            self._forget(client_id)

    def _send(self, data: bytes) -> None:
        if self.conn is None:
            return
        try:
            self.conn.sendall(data)
        except OSError as exc:
            log.warning("home connection lost: %s", exc)
            self._drop_connection()

    # -- client mappings -----------------------------------------------------

    def _forget(self, client_id: int) -> None:
        entry = self.by_id.pop(client_id, None)
        if entry is not None:
            self.by_addr.pop(entry[0], None)
            self._send(frame(T_CLOSE, client_id))

    def _id_for(self, addr: tuple[str, int]) -> int:
        client_id = self.by_addr.get(addr)
        if client_id is not None:
            self.by_id[client_id][1] = time.monotonic()
            return client_id
        while self.next_id in self.by_id or self.next_id >= 0xFFFF:
            self.next_id = self.next_id % 0xFFFE + 1
        client_id = self.next_id
        self.next_id = self.next_id % 0xFFFE + 1
        self.by_addr[addr] = client_id
        self.by_id[client_id] = [addr, time.monotonic()]
        log.debug("client %s:%s -> id %d", addr[0], addr[1], client_id)
        return client_id

    def _expire(self) -> None:
        now = time.monotonic()
        for client_id, entry in list(self.by_id.items()):
            if now - entry[1] > IDLE_TIMEOUT:
                log.debug("client id %d idle, forgetting it", client_id)
                self._forget(client_id)

    # -- main loop -----------------------------------------------------------

    def run(self) -> None:
        sel = selectors.DefaultSelector()
        sel.register(self.udp, selectors.EVENT_READ, "udp")
        sel.register(self.srv, selectors.EVENT_READ, "accept")
        watched = None
        log.info(
            "listening for clients on udp %s:%s, for the home side on tcp %s:%s",
            *self.udp.getsockname(),
            *self.srv.getsockname(),
        )
        while True:
            if self.conn is not watched:
                if watched is not None:
                    try:
                        sel.unregister(watched)
                    except (KeyError, ValueError):
                        pass
                watched = self.conn
                if watched is not None:
                    sel.register(watched, selectors.EVENT_READ, "control")

            for key, _ in sel.select(timeout=5.0):
                if key.data == "accept":
                    self._accept()
                elif key.data == "udp":
                    self._on_udp()
                elif key.data == "control":
                    self._on_control()
            self._expire()

    def _on_udp(self) -> None:
        try:
            payload, addr = self.udp.recvfrom(MAX_PAYLOAD)
        except OSError:
            return
        if self.conn is None:
            log.debug("client %s:%s sent %d bytes but no home side is connected",
                      addr[0], addr[1], len(payload))
            return
        client_id = self._id_for(addr)
        self._send(frame(T_DATA, client_id, payload))

    def _on_control(self) -> None:
        try:
            chunk = self.conn.recv(65536)
        except OSError as exc:
            log.warning("home connection error: %s", exc)
            self._drop_connection()
            return
        if not chunk:
            log.warning("home side closed the connection")
            self._drop_connection()
            return
        self.last_rx = time.monotonic()
        try:
            frames = self.reader.feed(chunk)
        except ValueError as exc:
            log.warning("bad stream from home side (%s), dropping it", exc)
            self._drop_connection()
            return
        for kind, client_id, payload in frames:
            if kind != T_DATA:
                continue
            entry = self.by_id.get(client_id)
            if entry is None:
                log.debug("reply for unknown id %d dropped", client_id)
                continue
            log.debug("reply of %d bytes for id %d -> %s:%s", len(payload), client_id, *entry[0])
            try:
                self.udp.sendto(payload, entry[0])
            except OSError as exc:
                log.debug("cannot deliver %d bytes to %s: %s", len(payload), entry[0], exc)


# ---------------------------------------------------------------- client


class Client:
    """Runs behind the home line: keeps a tcp connection up, feeds wg0."""

    def __init__(self, secret: bytes, server: tuple[str, int], target: tuple[str, int]):
        self.secret = secret
        self.server = server
        self.target = target
        self.conn: socket.socket | None = None
        self.reader = FrameReader()
        self.sockets: dict[int, socket.socket] = {}
        self.last_tx = 0.0

    def _connect(self) -> bool:
        conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        conn.settimeout(15.0)
        try:
            conn.connect(self.server)
            nonce = recv_exactly(conn, 32, "server closed during the handshake")
            conn.sendall(hmac.new(self.secret, nonce, hashlib.sha256).digest())
            answer = recv_exactly(conn, len(OK_BYTES), "server closed during the handshake")
            if answer != OK_BYTES:
                raise ConnectionError("server rejected the secret")
            conn.settimeout(None)
        except (OSError, ConnectionError) as exc:
            log.warning("cannot reach %s:%s: %s", self.server[0], self.server[1], exc)
            try:
                conn.close()
            except OSError:
                pass
            return False
        self.conn = conn
        self.reader = FrameReader()
        self.last_tx = time.monotonic()
        log.info("connected to %s:%s, forwarding to %s:%s", *self.server, *self.target)
        return True

    def _close_socket(self, client_id: int) -> None:
        sock = self.sockets.pop(client_id, None)
        if sock is not None:
            try:
                sock.close()
            except OSError:
                pass

    def _socket_for(self, client_id: int) -> socket.socket | None:
        sock = self.sockets.get(client_id)
        if sock is not None:
            return sock
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(self.target)
        except OSError as exc:
            log.warning("cannot reach %s:%s: %s", *self.target, exc)
            sock.close()
            return None
        sock.setblocking(False)
        self.sockets[client_id] = sock
        return sock

    def _teardown(self) -> None:
        if self.conn is not None:
            try:
                self.conn.close()
            except OSError:
                pass
        self.conn = None
        for client_id in list(self.sockets):
            self._close_socket(client_id)

    def run(self) -> None:
        delay = 1.0
        while True:
            if not self._connect():
                time.sleep(delay)
                delay = min(delay * 2, BACKOFF_MAX)
                continue
            delay = 1.0
            try:
                self._serve()
            except (OSError, ConnectionError) as exc:
                log.warning("connection lost: %s", exc)
            finally:
                self._teardown()
            time.sleep(1.0)

    def _serve(self) -> None:
        control = self.conn
        if control is None:
            return
        sel = selectors.DefaultSelector()
        sel.register(control, selectors.EVENT_READ, ("control", 0))
        known: dict[int, socket.socket] = {}
        while True:
            if self.conn is None:
                return
            for client_id, sock in self.sockets.items():
                if client_id not in known:
                    sel.register(sock, selectors.EVENT_READ, ("target", client_id))
            for client_id, sock in known.items():
                if client_id not in self.sockets:
                    try:
                        sel.unregister(sock)
                    except (KeyError, ValueError):
                        pass
            known = dict(self.sockets)

            for key, _ in sel.select(timeout=5.0):
                if self.conn is None:
                    return
                tag, client_id = key.data
                if tag == "control":
                    self._on_control(sel)
                else:
                    self._on_target(client_id, key.fileobj)
            if time.monotonic() - self.last_tx > KEEPALIVE:
                self._send(frame(T_KEEPALIVE, 0))

    def _send(self, data: bytes) -> None:
        if self.conn is None:
            raise ConnectionError("not connected")
        try:
            self.conn.sendall(data)
            self.last_tx = time.monotonic()
        except OSError as exc:
            raise ConnectionError(str(exc)) from exc

    def _on_control(self, sel) -> None:
        try:
            chunk = self.conn.recv(65536)
        except OSError as exc:
            raise ConnectionError(str(exc)) from exc
        if not chunk:
            raise ConnectionError("server closed the connection")
        for kind, client_id, payload in self.reader.feed(chunk):
            if kind == T_CLOSE:
                self._close_socket(client_id)
            elif kind == T_DATA:
                sock = self._socket_for(client_id)
                if sock is None:
                    continue
                try:
                    sock.send(payload)
                except OSError as exc:
                    log.debug("cannot deliver to the target: %s", exc)

    def _on_target(self, client_id: int, sock: socket.socket) -> None:
        try:
            payload = sock.recv(MAX_PAYLOAD)
        except OSError:
            return
        log.debug("reply of %d bytes for id %d from the target", len(payload), client_id)
        self._send(frame(T_DATA, client_id, payload))


# ---------------------------------------------------------------- entry


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("mode", choices=("server", "client"))
    ap.add_argument("--listen", default="0.0.0.0:51820",
                    help="server mode: udp address clients connect to")
    ap.add_argument("--control", default="0.0.0.0:7000",
                    help="server mode: tcp address the home side connects to")
    ap.add_argument("--server", default="127.0.0.1:7000",
                    help="client mode: host:port of the relay server")
    ap.add_argument("--target", default="127.0.0.1:51820",
                    help="client mode: local udp socket to forward to (wg0)")
    ap.add_argument("--secret", default=None, help="shared secret (prefer --secret-file)")
    ap.add_argument("--secret-file", default=None)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="wgmw-relay: %(message)s",
        stream=sys.stderr,
    )
    secret = load_secret(args)
    if len(secret) < 16:
        sys.exit("wgmw-relay: the shared secret must be at least 16 bytes")

    try:
        if args.mode == "server":
            Server(secret, parse_addr(args.listen), parse_addr(args.control)).run()
        else:
            Client(secret, parse_addr(args.server), parse_addr(args.target)).run()
    except KeyboardInterrupt:
        log.info("stopping")
    return 0


if __name__ == "__main__":
    sys.exit(main())
