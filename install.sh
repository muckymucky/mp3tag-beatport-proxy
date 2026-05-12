#!/bin/bash
# Full setup for beatport-proxy.
# Run once after cloning. Re-running is safe — each step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY_IP="10.254.254.254"
CERT="$SCRIPT_DIR/proxy-cert.pem"
KEY="$SCRIPT_DIR/proxy-key.pem"
DAEMON_PLIST="/Library/LaunchDaemons/com.beatport.setup.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/com.beatport.proxy.plist"

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "  $*"; }
ok()    { echo "✓ $*"; }
die()   { echo "✗ $*" >&2; exit 1; }

# ── prerequisites ─────────────────────────────────────────────────────────────

echo
echo "── Prerequisites ──────────────────────────────────────────────────────"

PYTHON=$(which python3.12 2>/dev/null) || die "python3.12 not found. Install with: brew install python@3.12"
ok "Python 3.12: $PYTHON"

VENV="$SCRIPT_DIR/.venv"
if [[ ! -x "$VENV/bin/python" ]]; then
    info "Creating virtual environment at $VENV..."
    "$PYTHON" -m venv "$VENV"
fi
PYTHON="$VENV/bin/python"
ok "Virtual environment: $VENV"

info "Installing dependencies..."
"$PYTHON" -m pip install --quiet -r "$SCRIPT_DIR/requirements.txt"
ok "Dependencies installed"

CHROME_PATHS=(
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
)
CHROME=""
for p in "${CHROME_PATHS[@]}"; do
    [[ -x "$p" ]] && CHROME="$p" && break
done
[[ -n "$CHROME" ]] || die "Google Chrome not found. Install from https://www.google.com/chrome/"
ok "Chrome: $CHROME"

# ── TLS certificate ───────────────────────────────────────────────────────────

echo
echo "── TLS Certificate ────────────────────────────────────────────────────"

if [[ ! -f "$CERT" ]]; then
    info "Generating self-signed cert for www.beatport.com..."
    openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
        -days 3650 -nodes \
        -subj "/CN=www.beatport.com" \
        -addext "subjectAltName=DNS:www.beatport.com,IP:$PROXY_IP" 2>/dev/null
    ok "Certificate generated: $CERT"
else
    ok "Certificate already exists: $CERT"
fi

info "Trusting certificate in System Keychain (sudo required)..."
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain "$CERT" 2>/dev/null && \
    ok "Certificate trusted in System Keychain" || \
    info "Certificate may already be trusted (or check Keychain Access manually)"

# ── /etc/hosts ────────────────────────────────────────────────────────────────

echo
echo "── /etc/hosts ─────────────────────────────────────────────────────────"

if grep -q "^$PROXY_IP.*www.beatport.com" /etc/hosts 2>/dev/null; then
    ok "/etc/hosts IPv4 entry already present"
else
    info "Adding www.beatport.com → $PROXY_IP to /etc/hosts (sudo required)..."
    echo "$PROXY_IP www.beatport.com" | sudo tee -a /etc/hosts > /dev/null
    ok "Added IPv4 entry to /etc/hosts"
fi

if grep -q "^::1.*www.beatport.com" /etc/hosts 2>/dev/null; then
    ok "/etc/hosts IPv6 entry already present"
else
    info "Adding www.beatport.com → ::1 to /etc/hosts (blocks IPv6 bypass)..."
    echo "::1 www.beatport.com" | sudo tee -a /etc/hosts > /dev/null
    ok "Added IPv6 entry to /etc/hosts"
fi

# ── LaunchDaemon: pf rules (runs as root at boot) ─────────────────────────────

echo
echo "── LaunchDaemon (pf rules, root) ──────────────────────────────────────"

cat > /tmp/com.beatport.setup.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.beatport.setup</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>$SCRIPT_DIR/setup.sh</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$SCRIPT_DIR/setup.log</string>

    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/setup.log</string>
</dict>
</plist>
PLIST

sudo cp /tmp/com.beatport.setup.plist "$DAEMON_PLIST"
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"

if sudo launchctl list | grep -q "com.beatport.setup"; then
    sudo launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
fi
sudo launchctl load "$DAEMON_PLIST"
ok "LaunchDaemon installed and loaded: $DAEMON_PLIST"

# ── LaunchAgent: proxy (runs as user at login) ────────────────────────────────

echo
echo "── LaunchAgent (proxy, user) ───────────────────────────────────────────"

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.beatport.proxy</string>

    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SCRIPT_DIR/beatport.py</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <false/>

    <key>StandardOutPath</key>
    <string>$SCRIPT_DIR/proxy.log</string>

    <key>StandardErrorPath</key>
    <string>$SCRIPT_DIR/proxy.log</string>
</dict>
</plist>
PLIST

if launchctl list | grep -q "com.beatport.proxy"; then
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
fi
launchctl load "$AGENT_PLIST"
ok "LaunchAgent installed and loaded: $AGENT_PLIST"

# ── Done ──────────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────────────────────────────────────────────"
echo "Setup complete. The proxy is now running and will restart at login."
echo
echo "Chrome will open and solve the Cloudflare challenge (~30s on first run),"
echo "then minimize itself. Logs: $SCRIPT_DIR/proxy.log"
echo
echo "To verify it's working:"
echo
echo "  curl -s -o /dev/null -w '%{http_code}\\n' https://www.beatport.com"
echo
