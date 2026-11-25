"""yab_socket against a fake bench socket that answers as Bench.swift does.

    python3 -m unittest evals/test_yab_socket.py
"""
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import yab_socket  # noqa: E402


class FakeBench:
    """Reads one line, answers with `reply(request)` and a newline, closes; as the app does.

    `reply` may return bytes to send as they are (an empty answer, say), and
    `close_early` closes without reading or answering.
    """

    def __init__(self, path, reply=lambda request: {"ok": True, "echo": request}, chunks=1):
        self.path, self.reply, self.chunks = str(path), reply, chunks
        self.requests = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(8)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while True:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            with conn:
                data = b""
                while b"\n" not in data:
                    chunk = conn.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                request = json.loads(data.split(b"\n", 1)[0])
                self.requests.append(request)
                answer = self.reply(request)
                out = answer if isinstance(answer, bytes) else (json.dumps(answer) + "\n").encode()
                # Written in pieces, to prove the reader joins them.
                step = max(1, len(out) // self.chunks)
                for i in range(0, len(out), step):
                    conn.sendall(out[i:i + step])
                    time.sleep(0.005)

    def close(self):
        self.listener.close()


class SocketTests(unittest.TestCase):
    def setUp(self):
        # A short folder: a UNIX socket path has room for 104 bytes.
        self.folder = Path(tempfile.mkdtemp(prefix="ys-", dir="/tmp" if os.path.isdir("/tmp") else None))
        self.sock = self.folder / "bench.sock"
        self.servers = []

    def tearDown(self):
        for server in self.servers:
            server.close()
        for item in self.folder.iterdir():
            item.unlink()
        self.folder.rmdir()

    def fake(self, **kwargs):
        server = FakeBench(self.sock, **kwargs)
        self.servers.append(server)
        return server

    def test_paths(self):
        home = Path("/Users/x")
        self.assertEqual(Path("/Users/x/Library/Application Support/Pane (w)/bench.sock"), yab_socket.socket_path("w", home))
        self.assertEqual(Path("/Users/x/Library/Application Support/Pane (w)"), yab_socket.support("w", home))
        missing = self.folder / "nope.sock"
        self.assertEqual(missing, yab_socket.first_existing([missing, self.folder / "other"]))
        self.assertEqual(self.folder, yab_socket.first_existing([missing, self.folder]))

    def test_exchange_sends_one_line_and_reads_the_answer_in_pieces(self):
        server = self.fake(chunks=7)
        answer = yab_socket.exchange(self.sock, {"do": "tabs", "text": "a\nb"})
        self.assertEqual({"ok": True, "echo": {"do": "tabs", "text": "a\nb"}}, answer)
        self.assertEqual([{"do": "tabs", "text": "a\nb"}], server.requests)

    def test_empty_answer_is_empty_unless_strict(self):
        self.fake(reply=lambda request: b"")
        self.assertEqual({}, yab_socket.exchange(self.sock, {"do": "x"}))
        with self.assertRaises(json.JSONDecodeError):
            yab_socket.exchange(self.sock, {"do": "x"}, strict=True)

    def test_socket_may_be_a_function(self):
        self.fake()
        self.assertTrue(yab_socket.exchange(lambda: self.sock, {"do": "x"})["ok"])

    def test_ask_retries_until_the_app_listens(self):
        def later():
            time.sleep(0.7)
            self.fake()
        threading.Thread(target=later, daemon=True).start()
        started = time.monotonic()
        self.assertTrue(yab_socket.ask(self.sock, {"do": "census"})["ok"])
        self.assertGreater(time.monotonic() - started, 0.5)

    def test_ask_gives_up(self):
        with self.assertRaises(SystemExit) as raised:
            yab_socket.ask(self.sock, {"do": "census"}, tries=2)
        self.assertEqual("yab isn't listening", raised.exception.code)

    def test_asker_binds_socket_and_defaults(self):
        self.fake()
        ask = yab_socket.asker(self.sock, tries=3, timeout=5)
        self.assertEqual({"do": "tabs"}, ask({"do": "tabs"})["echo"])
        self.assertEqual({"do": "tabs"}, ask({"do": "tabs"}, tries=1, timeout=None)["echo"])

    def test_bench_wraps_the_verb_and_timeout_may_be_a_field(self):
        server = self.fake()
        bench = yab_socket.bencher(self.sock)
        bench("wait", timeout=5, url="u")
        self.assertEqual({"do": "wait", "timeout": 5, "url": "u"}, server.requests[-1])
        timed = yab_socket.bencher(self.sock, takes_timeout=True)
        timed("wait", timeout=5, url="u")
        self.assertEqual({"do": "wait", "url": "u"}, server.requests[-1])
        self.assertEqual({"do": "ui", "x": 1}, yab_socket.bench(self.sock, "ui", x=1)["echo"])

    def test_kwasker_raises_on_error_only_when_told(self):
        self.fake(reply=lambda request: {"error": "nope"})
        plain = yab_socket.kwasker(self.sock)
        self.assertEqual({"error": "nope"}, plain(do="x"))
        loud = yab_socket.kwasker(self.sock, fail=lambda request, answer: RuntimeError((request, answer)))
        with self.assertRaises(RuntimeError) as raised:
            loud(do="x", n=1)
        self.assertEqual(({"do": "x", "n": 1}, {"error": "nope"}), raised.exception.args[0])

    def test_shot_waits_for_the_file(self):
        picture = self.folder / "a.png"

        def winshot(request):
            def write():
                time.sleep(0.2)
                Path(request["path"]).write_bytes(b"png")
            threading.Thread(target=write, daemon=True).start()
            return {"path": request["path"]}
        server = self.fake(reply=winshot)
        self.assertEqual(picture, yab_socket.shot(self.sock, picture, window=2))
        self.assertTrue(picture.exists())
        self.assertEqual({"do": "winshot", "path": str(picture), "window": 2}, server.requests[-1])


class WaitTests(unittest.TestCase):
    def test_returns_first_truthy(self):
        seen = iter([0, None, "", 7])
        self.assertEqual(7, yab_socket.wait_for(lambda: next(seen), 5, every=0.01))

    def test_returns_last_value_when_time_runs_out(self):
        calls = []
        self.assertEqual([], yab_socket.wait_for(lambda: calls.append(1) or [], 0.05, every=0.01))
        self.assertGreater(len(calls), 1)


class ServeTests(unittest.TestCase):
    def test_serves_a_handler_and_a_folder(self):
        class Page(yab_socket.http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"hi " + self.path.encode())

            def log_message(self, *args):
                pass
        server = yab_socket.serve(Page)
        try:
            self.assertTrue(yab_socket.url(server).startswith("http://127.0.0.1:"))
            with urllib.request.urlopen(yab_socket.url(server, "/x"), timeout=5) as page:
                self.assertEqual(b"hi /x", page.read())
        finally:
            server.shutdown()
            server.server_close()
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "page.html").write_text("<p>page</p>")
            files = yab_socket.serve_folder(folder)
            try:
                with urllib.request.urlopen(yab_socket.url(files, "/page.html"), timeout=5) as page:
                    self.assertEqual(b"<p>page</p>", page.read())
            finally:
                files.shutdown()
                files.server_close()


if __name__ == "__main__":
    unittest.main()
