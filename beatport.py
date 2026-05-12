#!/usr/bin/env python3
"""
Beatport proxy for MP3Tag Tag Sources.

Intercepts MP3Tag's requests to www.beatport.com and bypasses Cloudflare
by using a persistent real Chrome session (via nodriver) to fetch pages.

Setup:
  /etc/hosts:  10.254.254.254 www.beatport.com
  ifconfig:    sudo ifconfig lo0 alias 10.254.254.254
  pf rules:    rdr pass on lo0 proto tcp from any to 10.254.254.254 port 80  -> 127.0.0.1 port 8080
               rdr pass on lo0 proto tcp from any to 10.254.254.254 port 443 -> 127.0.0.1 port 8443
"""

import http.server
import socketserver
import urllib.parse
import asyncio
import subprocess
import threading
import time
import queue
import ssl
import os
import json
import sys
import socket

PROXY_PORT = int(os.environ.get("PORT", 8080))
PROXY_PORT_HTTPS = int(os.environ.get("PORT_HTTPS", 8443))

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CERT_FILE = os.path.join(_SCRIPT_DIR, "proxy-cert.pem")
KEY_FILE  = os.path.join(_SCRIPT_DIR, "proxy-key.pem")

CLOUDFLARE_DOMAINS = ["beatport.com", "www.beatport.com"]


def _get_real_beatport_ip():
    result = subprocess.run(
        ["dig", "+short", "www.beatport.com", "@8.8.8.8"],
        capture_output=True, text=True, timeout=10,
    )
    ips = [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
    return ips[0] if ips else "104.20.7.63"


# ---------------------------------------------------------------------------
# Chrome browser session — runs on a dedicated thread with its own event loop
# ---------------------------------------------------------------------------

class BrowserSession:
    """Manages a persistent nodriver Chrome browser for Beatport fetching."""

    def __init__(self):
        self._loop = None
        self._browser = None
        self._tab = None
        self._lock = threading.Lock()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True, name="chrome-session")
        self._thread.start()
        print("Waiting for Chrome to solve Cloudflare challenge...", flush=True)
        self._ready.wait(timeout=90)
        if not self._ready.is_set():
            raise RuntimeError("Chrome session failed to start within 90s")

    def _run(self):
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        for attempt in range(20):
            try:
                self._loop.run_until_complete(self._start_browser())
                break
            except Exception as e:
                print(f"Chrome start attempt {attempt + 1} failed: {e} — retrying in 15s", flush=True)
                time.sleep(15)
        else:
            print("Chrome failed to start after 20 attempts", flush=True)
            return
        self._loop.run_forever()

    async def _start_browser(self):
        import nodriver as uc
        real_ip = _get_real_beatport_ip()
        print(f"  Real beatport IP: {real_ip}", flush=True)

        self._browser = await uc.start(
            headless=False,
            browser_args=[
                "--no-sandbox",
                "--start-minimized",
                f"--host-resolver-rules=MAP www.beatport.com {real_ip}",
            ],
        )
        self._tab = await self._browser.get("https://www.beatport.com")
        print("  Chrome loaded beatport, waiting for CF challenge...", flush=True)

        import nodriver.cdp.network as cdp_network
        for attempt in range(45):
            try:
                cookies = await asyncio.wait_for(
                    self._tab.send(cdp_network.get_all_cookies()), timeout=5
                )
                names = [c.name for c in cookies]
                if "cf_clearance" in names:
                    print(f"  CF challenge solved (attempt {attempt})", flush=True)
                    self._ready.set()
                    await self._minimize_window()
                    return
            except Exception:
                pass
            await asyncio.sleep(1)

        print("  Warning: cf_clearance not obtained — proceeding anyway", flush=True)
        self._ready.set()
        await self._minimize_window()

    async def _minimize_window(self):
        try:
            import nodriver.cdp.browser as cdp_browser
            window_id, *_ = await self._tab.send(cdp_browser.get_window_for_target())
            await self._tab.send(cdp_browser.set_window_bounds(
                window_id=window_id,
                bounds=cdp_browser.Bounds(window_state=cdp_browser.WindowState.MINIMIZED),
            ))
        except Exception:
            pass

    def fetch(self, url):
        """Fetch via JavaScript fetch() in the browser — no navigation, window stays hidden."""
        with self._lock:
            result_queue = queue.Queue()

            async def _do_fetch():
                real_url = url.replace("http://www.beatport.com", "https://www.beatport.com", 1)
                js = (
                    "(async()=>{"
                    f"const r=await fetch({json.dumps(real_url)},{{credentials:'include'}});"
                    "return await r.text();"
                    "})()"
                )
                try:
                    html = await self._tab.evaluate(js, await_promise=True)
                    result_queue.put(("ok", html))
                except Exception as e:
                    result_queue.put(("err", str(e)))

            asyncio.run_coroutine_threadsafe(_do_fetch(), self._loop)
            kind, value = result_queue.get(timeout=45)
            if kind == "err":
                raise RuntimeError(value)
            return value


_browser_session = None
_session_lock = threading.Lock()


def get_browser_session():
    global _browser_session
    if _browser_session is None:
        with _session_lock:
            if _browser_session is None:
                _browser_session = BrowserSession()
    return _browser_session


# ---------------------------------------------------------------------------
# HTTP proxy server
# ---------------------------------------------------------------------------

class BeatportProxy(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        print(f"[{self.command}] {self.path}", flush=True)

    def do_GET(self):
        self._handle_request()

    def do_POST(self):
        self._handle_request()

    def _handle_request(self):
        if self.path.startswith("http"):
            url = self.path
        else:
            host = self.headers.get("Host", "localhost")
            url = f"http://{host}{self.path}"

        parsed = urllib.parse.urlparse(url)
        if any(domain in parsed.netloc for domain in CLOUDFLARE_DOMAINS):
            print(f"  Chrome -> {url}", flush=True)
            self._fetch_via_chrome(url)
        else:
            self.send_error(502, "Non-beatport request not supported")

    def _fetch_via_chrome(self, url):
        try:
            session = get_browser_session()
            html = session.fetch(url)
        except Exception as e:
            print(f"  Chrome fetch error: {e}", flush=True)
            self.send_error(502, str(e))
            return

        body = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
            print(f"  -> 200 ({len(body)} bytes)", flush=True)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass


class ReusableThreadingTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


class HTTPSProxyServer(ReusableThreadingTCPServer):
    def __init__(self, addr, handler):
        super().__init__(addr, handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        self.socket = ctx.wrap_socket(self.socket, server_side=True)


if __name__ == "__main__":
    # Reserve ports before starting Chrome so concurrent instances fail fast.
    # Use SO_EXCLUSIVEADDRUSE-equivalent: bind without SO_REUSEADDR to get a
    # definitive answer, then release and let the real servers rebind with REUSEADDR.
    for _port in (PROXY_PORT, PROXY_PORT_HTTPS):
        with socket.socket() as _s:
            try:
                _s.bind(('', _port))
            except OSError:
                print(f"Port {_port} already in use — another instance running, exiting.", flush=True)
                sys.exit(0)

    print(f"Beatport proxy starting (HTTP:{PROXY_PORT} HTTPS:{PROXY_PORT_HTTPS})", flush=True)
    get_browser_session()

    https_server = HTTPSProxyServer(("", PROXY_PORT_HTTPS), BeatportProxy)
    https_thread = threading.Thread(target=https_server.serve_forever, daemon=True)
    https_thread.start()

    print(f"Ready — HTTP on :{PROXY_PORT}, HTTPS on :{PROXY_PORT_HTTPS}", flush=True)
    with ReusableThreadingTCPServer(("", PROXY_PORT), BeatportProxy) as httpd:
        httpd.serve_forever()
