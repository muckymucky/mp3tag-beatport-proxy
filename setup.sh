#!/bin/bash
# Runs as root via LaunchDaemon — sets up network redirects for Beatport proxy

# Loopback alias for IPv4 intercept
ifconfig lo0 alias 10.254.254.254 2>/dev/null || true

# Write the beatport anchor rules. IPv4 only: pf can't redirect across address
# families, so ::1 -> 127.0.0.1 fails to load. The ::1 entry in /etc/hosts is
# enough to block IPv6 bypass — clients fall back to IPv4 when ::1 is refused.
mkdir -p /etc/pf.anchors
cat > /etc/pf.anchors/beatport <<'PF'
rdr pass on lo0 proto tcp from any to 10.254.254.254 port 80  -> 127.0.0.1 port 8080
rdr pass on lo0 proto tcp from any to 10.254.254.254 port 443 -> 127.0.0.1 port 8443
PF

# Insert anchor hooks into /etc/pf.conf in the correct section.
# rdr-anchor is a translation rule and must appear before filter rules
# (`anchor "com.apple/*"`); appending to the end of pf.conf puts it after the
# filter anchor, which makes pf reject the entire config at load time.
PFCONF=/etc/pf.conf
TMP=$(mktemp)
awk '
  /^rdr-anchor "beatport"$/                 { next }
  /^load anchor "beatport"/                 { next }
  /^rdr-anchor "com\.apple\/\*"$/           { print; print "rdr-anchor \"beatport\""; next }
  /^load anchor "com\.apple" from /         { print; print "load anchor \"beatport\" from \"/etc/pf.anchors/beatport\""; next }
  { print }
' "$PFCONF" > "$TMP"
if ! cmp -s "$TMP" "$PFCONF"; then
    cp "$PFCONF" "$PFCONF.bak.$(date +%s)"
    cat "$TMP" > "$PFCONF"
fi
rm -f "$TMP"

# Reload pf with the full config (keeps com.apple/* anchors intact).
# Don't suppress stderr: real syntax errors must surface in setup.log.
pfctl -ef "$PFCONF" || pfctl -f "$PFCONF"

echo "$(date): beatport network setup complete"
