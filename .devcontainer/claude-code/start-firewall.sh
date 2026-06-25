#!/bin/bash
# start-firewall.sh -- Initialize the network firewall with retries.
# Called by devcontainer postStartCommand. Wraps init-firewall.sh to
# handle transient failures (DNS not ready, network not yet available)
# that can occur during early container startup.
#
# Writes the final status ("ok" or "failed") to /run/firewall/status so
# that firewall-warning.sh (sourced from ~/.zshrc) can display a visible
# banner in every new shell if the firewall never came up.

set -euo pipefail
# Pin PATH (defense-in-depth; don't depend on caller env / sudoers secure_path).
# Mirrors the sudoers secure_path exactly so no tool resolution changes.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# Keep runtime state under /run (root-owned 0755 — NOT world-writable like
# /tmp). This stops the unprivileged vscode user from pre-planting a symlink at
# these paths to trick this root-run script into writing or chmod-ing an
# arbitrary file (a /tmp TOCTOU primitive).
STATE_DIR="/run/firewall"
LOG="$STATE_DIR/init.log"
STATUS_FILE="$STATE_DIR/status"
MAX_RETRIES=3
RETRY_DELAY=5

mkdir -p "$STATE_DIR"
chmod 0755 "$STATE_DIR"

echo "=== Firewall init starting at $(date -Iseconds) ===" | tee "$LOG"

# Mark status as "failed" up-front so partial runs don't look healthy.
echo "failed" > "$STATUS_FILE"
chmod 644 "$STATUS_FILE"

for attempt in $(seq 1 "$MAX_RETRIES"); do
    echo "[Attempt $attempt/$MAX_RETRIES]" | tee -a "$LOG"
    if /usr/local/bin/init-firewall.sh >> "$LOG" 2>&1; then
        echo "Firewall active (attempt $attempt)" | tee -a "$LOG"
        echo "ok" > "$STATUS_FILE"
        exit 0
    fi
    echo "Attempt $attempt failed" | tee -a "$LOG"
    [ "$attempt" -lt "$MAX_RETRIES" ] && sleep "$RETRY_DELAY"
done

echo "ERROR: Firewall failed after $MAX_RETRIES attempts. See $LOG" >&2
# init-firewall.sh fails CLOSED (its EXIT trap sets default-DROP), so after a
# failed run egress is BLOCKED rather than open.
echo "WARNING: Firewall did not initialize — egress is BLOCKED (fail-closed)." | tee -a "$LOG"
# Exit 0 so postStartCommand does not abort the container rebuild; the "failed"
# status file + firewall-warning.sh banner in every new shell surface the state.
exit 0
