# beatport-proxy

Lets [MP3Tag](https://www.mp3tag.de/en/)'s "Tag Sources" feature search Beatport for track metadata, bypassing the Cloudflare bot protection Beatport added in May 2026.

## How it works

MP3Tag's HTTP/HTTPS requests to `www.beatport.com` are intercepted by a local proxy that uses a real Chrome browser (via [nodriver](https://github.com/ultrafunkamsterdam/nodriver)) to fetch pages with valid Cloudflare cookies. Chrome solves the JS challenge once on startup; subsequent requests use `fetch()` in the browser context so cookies are preserved.

```
MP3Tag → www.beatport.com (intercepted by /etc/hosts)
  → loopback alias 10.254.254.254
  → pf redirect → localhost:8080/8443
  → beatport.py proxy
  → nodriver Chrome (with cf_clearance cookie)
  → real Beatport
```

## Requirements

- macOS (uses `pf` and loopback aliases)
- [Python 3.12](https://www.python.org/downloads/): `brew install python@3.12`
- [Google Chrome](https://www.google.com/chrome/)
- [MP3Tag for Mac](https://www.mp3tag.de/en/mac.html)

## Install

```bash
git clone https://github.com/muckymucky/mp3tag-beatport-proxy beatport-proxy
cd beatport-proxy
bash install.sh
```

`install.sh` does everything:
1. Generates a self-signed TLS cert and trusts it in the System Keychain
2. Adds `www.beatport.com → 10.254.254.254` (and `::1`) to `/etc/hosts`
3. Installs a **LaunchDaemon** (root) that writes a `pf` anchor and activates the redirect rules at boot
4. Installs a **LaunchAgent** (user) that starts the proxy at login

The LaunchAgent starts the proxy immediately at the end of install — no reboot needed.

## Verify

```bash
curl -sv https://www.beatport.com 2>&1 | grep "< HTTP"
# expect: < HTTP/1.1 200 OK
```

## Files

| File | Purpose |
|------|---------|
| `beatport.py` | Proxy server (HTTP :8080, HTTPS :8443) |
| `install.sh` | One-shot setup script |
| `start.sh` | Manual start (activates pf + launches proxy) |
| `setup.sh` | pf rule activation (called by LaunchDaemon) |
| `requirements.txt` | Python dependencies (`nodriver`) |

## Uninstall

Run these to fully reverse the install. Each command is safe if the corresponding step never ran.

```bash
# 1. Stop and remove the LaunchAgent (proxy) and LaunchDaemon (pf setup)
launchctl unload ~/Library/LaunchAgents/com.beatport.proxy.plist 2>/dev/null
sudo launchctl unload /Library/LaunchDaemons/com.beatport.setup.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.beatport.proxy.plist
sudo rm -f /Library/LaunchDaemons/com.beatport.setup.plist

# 2. Remove pf anchor file and unhook it from /etc/pf.conf, then reload pf
sudo rm -f /etc/pf.anchors/beatport
sudo sed -i '' '/beatport/d' /etc/pf.conf
sudo pfctl -f /etc/pf.conf 2>/dev/null

# 3. Remove the loopback alias
sudo ifconfig lo0 -alias 10.254.254.254 2>/dev/null

# 4. Remove /etc/hosts entries (both IPv4 and IPv6)
sudo sed -i '' '/[[:space:]]www\.beatport\.com$/d' /etc/hosts

# 5. Remove the trusted certificate from the System Keychain
sudo security delete-certificate -c www.beatport.com /Library/Keychains/System.keychain 2>/dev/null

# 6. Delete the project directory (cert, key, venv, logs)
cd .. && rm -rf beatport-proxy
```

After uninstall, `curl -v https://www.beatport.com` should hit real Cloudflare IPs again instead of `10.254.254.254`.

## Troubleshooting

**Chrome window appears on startup** — it minimizes automatically once the Cloudflare challenge is solved (within ~10 seconds). If it stays open, the challenge is still running; wait up to 90 seconds.

**403 errors after a while** — the `cf_clearance` cookie expired. Restart the proxy: `launchctl unload ~/Library/LaunchAgents/com.beatport.proxy.plist && launchctl load ~/Library/LaunchAgents/com.beatport.proxy.plist`

**curl returns connection refused** — pf rules may not be active. Run `bash start.sh` or reboot.

**Certificate errors in curl** — make sure the cert was trusted: `bash install.sh` re-runs the trust step safely.

See `proxy.log` and `setup.log` in the project directory for detailed logs.
