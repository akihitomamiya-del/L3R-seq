#!/bin/sh
# firewall-warning.sh -- Print a visible banner if the network firewall
# failed to initialize during container start. Sourced from ~/.zshrc so
# every new shell sees the warning (otherwise a silent fail-open is too
# easy to miss, and the whole point of the claude-code sandbox is to run
# with --dangerously-skip-permissions behind a working firewall).

_fw_status_file="/tmp/firewall-status"
if [ -f "$_fw_status_file" ] && [ "$(cat "$_fw_status_file" 2>/dev/null)" = "failed" ]; then
    printf '\n\033[1;31m═══════════════════════════════════════════════════════════════\033[0m\n'
    printf '\033[1;31m⚠  WARNING: Network firewall failed to initialize.\033[0m\n'
    printf '\033[1;31m   Container is running WITHOUT network restrictions.\033[0m\n'
    printf '\033[1;31m   Do NOT use --dangerously-skip-permissions until resolved.\033[0m\n'
    printf '\033[1;31m   Logs: /tmp/firewall-init.log\033[0m\n'
    printf '\033[1;31m   Retry: sudo /usr/local/bin/start-firewall.sh\033[0m\n'
    printf '\033[1;31m═══════════════════════════════════════════════════════════════\033[0m\n\n'
fi
unset _fw_status_file
