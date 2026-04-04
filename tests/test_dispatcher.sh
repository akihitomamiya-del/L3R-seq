#!/bin/bash
# test_dispatcher.sh — Tests for L3Rseq dispatcher argument parsing.
# Validates help, version, subcommand routing, and error handling
# without running any actual data processing.
#
# Usage: bash tests/test_dispatcher.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L3RSEQ="$SCRIPT_DIR/../L3Rseq"
PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "[Dispatcher Tests] Argument parsing and error handling"
echo ""

# ---------------------------------------------------------------------------
# Success cases: --help, --version
# ---------------------------------------------------------------------------
echo "--- Help & version ---"

if "$L3RSEQ" --help >/dev/null 2>&1; then
    pass "--help exits 0"
else
    fail "--help exits 0"
fi

if "$L3RSEQ" -h >/dev/null 2>&1; then
    pass "-h exits 0"
else
    fail "-h exits 0"
fi

_ver=$("$L3RSEQ" --version 2>&1)
if echo "$_ver" | grep -qE '^L3Rseq [0-9]+\.[0-9]+\.[0-9]+'; then
    pass "--version format: $_ver"
else
    fail "--version format: got '$_ver'"
fi

if "$L3RSEQ" -v 2>&1 | grep -qE '^L3Rseq [0-9]+'; then
    pass "-v shorthand works"
else
    fail "-v shorthand works"
fi

# ---------------------------------------------------------------------------
# Success cases: subcommand --help
# ---------------------------------------------------------------------------
echo ""
echo "--- Subcommand help ---"

for cmd in concat trim demux map variants correct export regions count run; do
    if "$L3RSEQ" "$cmd" --help >/dev/null 2>&1; then
        pass "$cmd --help exits 0"
    else
        fail "$cmd --help exits 0"
    fi
done

# ---------------------------------------------------------------------------
# Failure cases: unknown subcommand
# ---------------------------------------------------------------------------
echo ""
echo "--- Error handling ---"

_unknown_out=$("$L3RSEQ" unknown-cmd 2>&1 || true)
_unknown_rc=$("$L3RSEQ" unknown-cmd >/dev/null 2>&1 && echo 0 || echo 1)
if [ "$_unknown_rc" = "1" ]; then
    pass "unknown subcommand exits non-zero"
else
    fail "unknown subcommand exits non-zero"
fi

if echo "$_unknown_out" | grep -q 'Unknown subcommand'; then
    pass "unknown subcommand shows error message"
else
    fail "unknown subcommand shows error message (got: $_unknown_out)"
fi

# ---------------------------------------------------------------------------
# Failure cases: missing required arguments
# ---------------------------------------------------------------------------
echo ""
echo "--- Missing arguments ---"

# run without --input/--outdir
if ! "$L3RSEQ" run --input /nonexistent --outdir /tmp/l3rseq_test_$$ 2>/dev/null; then
    pass "run with missing input dir exits non-zero"
else
    fail "run with missing input dir exits non-zero"
    rm -rf /tmp/l3rseq_test_$$
fi

# concat without --input
if ! "$L3RSEQ" concat 2>/dev/null; then
    pass "concat without --input exits non-zero"
else
    fail "concat without --input exits non-zero"
fi

# map without --ref
if ! "$L3RSEQ" map --input /tmp --outdir /tmp 2>/dev/null; then
    pass "map without --ref exits non-zero"
else
    fail "map without --ref exits non-zero"
fi

# ---------------------------------------------------------------------------
# Failure cases: --ref requires a value
# ---------------------------------------------------------------------------
if ! "$L3RSEQ" run --ref 2>/dev/null; then
    pass "--ref without value exits non-zero"
else
    fail "--ref without value exits non-zero"
fi

# ---------------------------------------------------------------------------
# Failure cases: unknown option in subcommand
# ---------------------------------------------------------------------------
if ! "$L3RSEQ" concat --bogus-flag 2>/dev/null; then
    pass "unknown option in subcommand exits non-zero"
else
    fail "unknown option in subcommand exits non-zero"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo "Dispatcher tests: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
