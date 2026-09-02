#!/usr/bin/env python3
"""
YTWatch Download Server
Run this on your Mac while syncing music to the iPhone app.
Both Mac and iPhone must be on the same Wi-Fi network.

Usage:
    pip3 install yt-dlp flask
    python3 server.py

Then in the YTWatch iPhone app → Settings, enter:
    http://<your-mac-ip>:8765
"""

import os
import sys
import json
import shutil
import tempfile
import threading
import subprocess
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── Config ──────────────────────────────────────────────────────────────────

PORT = 8765
CACHE_DIR = Path.home() / ".ytwatch_cache"
CACHE_DIR.mkdir(exist_ok=True)

# ── Helpers ──────────────────────────────────────────────────────────────────

def check_yt_dlp():
    """Ensure yt-dlp is available."""
    if shutil.which("yt-dlp"):
        return True
    # Try pip install location
    pip_bin = Path.home() / "Library/Python/3.11/bin/yt-dlp"
    if pip_bin.exists():
        return True
    print("ERROR: yt-dlp not found.")
    print("Install with:  pip3 install yt-dlp")
    return False

def get_yt_dlp_path():
    if shutil.which("yt-dlp"):
        return "yt-dlp"
    fallbacks = [
        Path.home() / "Library/Python/3.11/bin/yt-dlp",
        Path.home() / "Library/Python/3.12/bin/yt-dlp",
        Path("/opt/homebrew/bin/yt-dlp"),
        Path("/usr/local/bin/yt-dlp"),
    ]
    for p in fallbacks:
        if p.exists():
            return str(p)
    return "yt-dlp"

def download_track(video_id: str) -> Path | None:
    """Download audio for a YouTube video ID, return path to M4A file."""
    cached = CACHE_DIR / f"{video_id}.m4a"
    if cached.exists():
        print(f"  [cache] {video_id}")
        return cached

    url = f"https://www.youtube.com/watch?v={video_id}"
    out_template = str(CACHE_DIR / f"{video_id}.%(ext)s")

    cmd = [
        get_yt_dlp_path(),
        "--format", "bestaudio[ext=m4a]/bestaudio/best",
        "--extract-audio",
        "--audio-format", "m4a",
        "--audio-quality", "128K",
        "--output", out_template,
        "--no-playlist",
        "--quiet",
        url,
    ]

    print(f"  [download] {video_id}")
    result = subprocess.run(cmd, capture_output=True, text=True)

    if result.returncode != 0:
        print(f"  [error] yt-dlp: {result.stderr[:200]}")
        return None

    # yt-dlp may output as .m4a or convert — find the file
    for ext in ["m4a", "mp4", "webm", "opus"]:
        candidate = CACHE_DIR / f"{video_id}.{ext}"
        if candidate.exists():
            if ext != "m4a":
                candidate.rename(cached)
            return cached

    return None

def get_local_ip() -> str:
    """Get the Mac's local network IP."""
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

# ── HTTP Handler ─────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/ping":
            self._respond(200, b"pong", "text/plain")

        elif path.startswith("/download/"):
            video_id = path.split("/download/")[-1].strip("/")
            if not video_id or not self._valid_video_id(video_id):
                self._respond(400, b"Invalid video ID", "text/plain")
                return

            file_path = download_track(video_id)
            if file_path is None:
                self._respond(500, b"Download failed", "text/plain")
                return

            data = file_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Disposition", f'attachment; filename="{video_id}.m4a"')
            self.end_headers()
            self.wfile.write(data)

        elif path == "/cache":
            files = list(CACHE_DIR.glob("*.m4a"))
            info = [{"videoId": f.stem, "sizeBytes": f.stat().st_size} for f in files]
            body = json.dumps(info).encode()
            self._respond(200, body, "application/json")

        elif path.startswith("/delete/"):
            video_id = path.split("/delete/")[-1].strip("/")
            target = CACHE_DIR / f"{video_id}.m4a"
            if target.exists():
                target.unlink()
                self._respond(200, b"deleted", "text/plain")
            else:
                self._respond(404, b"not found", "text/plain")

        else:
            self._respond(404, b"Not found", "text/plain")

    def _respond(self, code: int, body: bytes, content_type: str):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _valid_video_id(self, vid: str) -> bool:
        return len(vid) == 11 and all(c.isalnum() or c in "-_" for c in vid)

    def log_message(self, fmt, *args):
        print(f"  [{self.address_string()}] {fmt % args}")

# ── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if not check_yt_dlp():
        sys.exit(1)

    ip = get_local_ip()
    print(f"\n YTWatch Download Server")
    print(f" ─────────────────────────────")
    print(f" Listening on  http://0.0.0.0:{PORT}")
    print(f" Your Mac IP:  http://{ip}:{PORT}")
    print(f" Cache dir:    {CACHE_DIR}")
    print(f"\n In the iPhone app → Settings, enter:")
    print(f"   http://{ip}:{PORT}")
    print(f"\n Press Ctrl+C to stop.\n")

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
