"""Talking to a running Yab through its bench socket, shared by the harnesses.

The app listens on `bench.sock` in its support folder,
`~/Library/Application Support/Pane (WORLD)/bench.sock` for a probe world
(Sources/Fast/Bench.swift). One connection carries one request: a JSON object
on one line out, one JSON object on one line back, then the app closes the
connection. Everything here is that round trip, plus the small things nearly
every harness wrote for itself around it.

    sys.path.insert(0, EVALS)
    import yab_socket

    SOCK = yab_socket.socket_path(WORLD)
    ask = yab_socket.asker(SOCK)                # ask({"do": "tabs"}), retries until the app listens
    bench = yab_socket.bencher(support / "bench.sock")   # bench("winshot", path=...)
    wait_for = yab_socket.wait_for              # wait_for(lambda: ..., 20)

A socket can be a path or a function that returns one, read at each call, for
a harness whose world (and so its socket) is chosen after the helpers are made.
Standard library only.
"""
import functools
import http.server
import json
import os
import socket
import threading
import time
from pathlib import Path

__all__ = ["support", "socket_path", "first_existing", "exchange", "ask", "asker", "bench", "bencher",
           "kwasker", "wait_for", "shot", "serve", "serve_folder", "url"]


# MARK: - where the socket is

def support(world, home=None):
    """A probe world's support folder: `~/Library/Application Support/Pane (WORLD)`."""
    return Path(home or Path.home()) / "Library/Application Support" / ("Pane (" + world + ")")


def socket_path(world, home=None):
    """A probe world's bench socket."""
    return support(world, home) / "bench.sock"


def first_existing(paths):
    """The first socket that exists, or the first one named (a fake HOME and the real one)."""
    paths = list(paths)
    return next((p for p in paths if Path(p).exists()), paths[0])


def _where(sock):
    return str(sock() if callable(sock) else sock)


# MARK: - one round trip

def exchange(sock, request, timeout=30, strict=False):
    """One request, one answer.

    Sends `request` as one JSON line and reads until the answer's newline (or
    the app closing the connection, which it does right after answering).
    The first line is the answer; an empty one is `{}`, or with `strict` the
    JSONDecodeError it always was in harnesses that never expected one.
    `timeout` is the socket's (None waits for good). Connection errors are
    the caller's.
    """
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(_where(sock))
        s.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while b"\n" not in data:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            data += chunk
    line = data.split(b"\n", 1)[0]
    return json.loads(line if strict else (line or b"{}"))


def ask(sock, request, tries=60, timeout=30):
    """A request, retried every half second while the app isn't listening yet.

    Gives up with SystemExit("yab isn't listening") after `tries` refusals.
    """
    for _ in range(tries):
        try:
            return exchange(sock, request, timeout)
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.5)
    raise SystemExit("yab isn't listening")


def asker(sock, tries=60, timeout=30):
    """`ask(request, tries=..., timeout=...)` bound to one socket, the defaults given here."""
    def ask_(request, tries=tries, timeout=timeout):
        return ask(sock, request, tries, timeout)
    ask_.__name__ = "ask"
    return ask_


def bench(sock, verb, timeout=30, strict=True, **fields):
    """`{"do": verb, **fields}` once, no retry: the app is expected to be up."""
    return exchange(sock, {"do": verb, **fields}, timeout, strict)


def bencher(sock, timeout=30, strict=True, takes_timeout=False):
    """`bench(verb, **fields)` bound to one socket. `verb` is positional
    only, so a request's own `verb` field (`research`'s) is a field.

    With `takes_timeout` the bound function also takes `timeout=` for its
    socket; without it a `timeout=` is a field of the request, as in the
    harnesses whose bench never had one.
    """
    if takes_timeout:
        def bench_(verb, /, timeout=timeout, **fields):
            return exchange(sock, {"do": verb, **fields}, timeout, strict)
    else:
        def bench_(verb, /, **fields):
            return exchange(sock, {"do": verb, **fields}, timeout, strict)
    bench_.__name__ = "bench"
    return bench_


def kwasker(sock, timeout=30, strict=False, fail=None, takes_timeout=False):
    """`ask(**request)` bound to one socket, no retry.

    `fail(request, answer)` makes the exception raised when the answer has an
    `error` key; without it the answer is returned as it is. `takes_timeout`
    as for `bencher`.
    """
    def check(request, answer):
        if fail is not None and "error" in answer:
            raise fail(request, answer)
        return answer
    if takes_timeout:
        def ask_(timeout=timeout, **request):
            return check(request, exchange(sock, request, timeout, strict))
    else:
        def ask_(**request):
            return check(request, exchange(sock, request, timeout, strict))
    ask_.__name__ = "ask"
    return ask_


# MARK: - waiting and pictures

def wait_for(test, seconds=10, every=0.3):
    """`test()` until it's truthy or `seconds` pass; then its last value, truthy or not."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        got = test()
        if got:
            return got
        time.sleep(every)
    return test()


def shot(sock, path, tries=40, timeout=30, **extra):
    """The window drawn from the app's own layers (`winshot`), no Screen Recording needed.

    Waits up to `tries` tenths of a second for the file to be written and
    returns `path`. `extra` goes with the request (`window=`, `print=`).
    """
    bench(sock, "winshot", timeout, True, path=str(path), **extra)
    for _ in range(tries):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            break
        time.sleep(.1)
    return path


# MARK: - pages to load

def serve(handler, port=0, host="127.0.0.1"):
    """A ThreadingHTTPServer for `handler`, serving from a daemon thread; port 0 picks a free one."""
    server = http.server.ThreadingHTTPServer((host, port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class _QuietFiles(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve_folder(folder):
    """A folder's files over HTTP on a free port, without a log line per request."""
    return serve(functools.partial(_QuietFiles, directory=str(folder)))


def url(server, path="/"):
    """`http://127.0.0.1:PORT/` for a server from `serve`."""
    host, port = server.server_address[:2]
    return f"http://{host}:{port}{path}"
