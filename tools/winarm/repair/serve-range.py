#!/usr/bin/env python3
"""Static file server with HTTP Range support (resumable downloads).

  serve-range.py <dir> [port]

http.server lacks Range, so `curl -C -` cannot resume a multi-GB file
after a Wi-Fi drop. Threaded, read-only, serves only regular files in <dir>.
"""
import http.server
import os
import re
import shutil
import socketserver
import sys

ROOT = os.path.realpath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8765


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            self.send_error(404)
            return None
        size = os.path.getsize(path)
        start, end = 0, size - 1
        rng = self.headers.get("Range")
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip()) if rng else None
        f = open(path, "rb")
        if m and (m.group(1) or m.group(2)):
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:
                start = max(size - int(m.group(2)), 0)
            if start >= size or start > end:
                f.close()
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.end_headers()
                return None
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        f.seek(start)
        self._left = end - start + 1
        return f

    def copyfile(self, src, dst):
        left = self._left
        while left > 0:
            buf = src.read(min(1 << 20, left))
            if not buf:
                break
            dst.write(buf)
            left -= len(buf)

    # PUT /up/<name>: lets the tablet send logs back with `curl -T file`.
    # Flat names only, written under <dir>/up, at most 512 MB.
    def do_PUT(self):
        m = re.fullmatch(r"/up/([A-Za-z0-9._-]{1,80})", self.path)
        n = int(self.headers.get("Content-Length", "-1"))
        if not m or m.group(1).startswith(".") or not 0 <= n <= (512 << 20):
            self.send_error(400)
            return
        os.makedirs(os.path.join(ROOT, "up"), exist_ok=True)
        dst = os.path.join(ROOT, "up", m.group(1))
        with open(dst, "wb") as f:
            left = n
            while left > 0:
                buf = self.rfile.read(min(1 << 20, left))
                if not buf:
                    break
                f.write(buf)
                left -= len(buf)
        self.send_response(201 if left == 0 else 400)
        self.send_header("Content-Length", "0")
        self.end_headers()
        print("upload %s %d bytes%s" % (dst, n - left, "" if left == 0 else " (short)"), flush=True)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print("serving %s on :%d" % (ROOT, PORT), flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
