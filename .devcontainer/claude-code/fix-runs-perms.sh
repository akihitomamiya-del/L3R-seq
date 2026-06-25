#!/bin/bash
# fix-runs-perms.sh -- Hand the vscode user ownership of the /runs volume.
#
# The /runs Docker named volume (l3rseq-runs) is created root-owned, so the
# unprivileged vscode user cannot write to it until it is chowned once at
# container creation (see postCreateCommand in devcontainer.json).
#
# This wrapper exists so that the ownership fix can be granted via a NARROW
# sudoers entry (see .devcontainer/claude-code/Dockerfile) rather than blanket
# passwordless sudo: vscode may run this exact script as root and nothing else.
# It only ever touches /runs, so it grants no privilege-escalation foothold.
set -euo pipefail

RUNS_DIR="/runs"

mkdir -p "$RUNS_DIR"
chown -R vscode:vscode "$RUNS_DIR"
