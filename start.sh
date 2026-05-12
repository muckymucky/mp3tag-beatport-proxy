#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── pf redirect rules ────────────────────────────────────────────────────────
echo "Enabling pf redirects (requires sudo)..."
sudo -v  # cache credentials before stdin is consumed by the pipe
sudo ifconfig lo0 alias 10.254.254.254 2>/dev/null || true
if ! sudo pfctl -s info | grep -q "Status: Enabled"; then
    sudo pfctl -e >/dev/null
fi
printf '\nrdr pass on lo0 proto tcp from any to 10.254.254.254 port 80  -> 127.0.0.1 port 8080
rdr pass on lo0 proto tcp from any to 10.254.254.254 port 443 -> 127.0.0.1 port 8443
' | sudo pfctl -f - >/dev/null
echo "pf rules active."

# ── proxy ────────────────────────────────────────────────────────────────────
echo "Starting Beatport proxy..."
PYTHON="$SCRIPT_DIR/.venv/bin/python"
if [[ ! -x "$PYTHON" ]]; then
    echo "Virtual environment not found. Run bash install.sh first."
    exit 1
fi
exec "$PYTHON" "$SCRIPT_DIR/beatport.py"
