#!/usr/bin/env python3
"""Static file server with HTTP Range support for the codec test page.

python3 -m http.server answers every request with the whole file and no
Accept-Ranges, so Chromium treats media as non-seekable streams and a
seek can land on 0 or stall. Real web servers honour Range.

  serve.py PORT DIRECTORY
"""
import http.server
import os
import re
import sys


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or "Range" not in self.headers:
            return super().send_head()
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", self.headers["Range"].strip())
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404)
            return None
        size = os.fstat(f.fileno()).st_size
        if not m or (m[1] == "" and m[2] == ""):
            f.close()
            self.send_error(416)
            return None
        if m[1] == "":
            start, end = max(0, size - int(m[2])), size - 1
        else:
            start = int(m[1])
            end = min(int(m[2]), size - 1) if m[2] else size - 1
        if start >= size or start > end:
            f.close()
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        f.seek(start)
        self._remaining = end - start + 1
        return f

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def copyfile(self, source, outputfile):
        left = getattr(self, "_remaining", None)
        if left is None:
            return super().copyfile(source, outputfile)
        self._remaining = None
        while left > 0:
            buf = source.read(min(left, 1 << 20))
            if not buf:
                break
            outputfile.write(buf)
            left -= len(buf)


if __name__ == "__main__":
    port, root = int(sys.argv[1]), sys.argv[2]
    handler = lambda *a, **k: RangeHandler(*a, directory=root, **k)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
