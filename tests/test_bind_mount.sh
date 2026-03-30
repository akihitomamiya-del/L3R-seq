#!/bin/bash
# test_bind_mount.sh — Verify bind-mount I/O works for the production workflow
#
# Run this from the repo root on your HOST machine (not inside a container).
# Complements test_docker_image.sh: that script tests the image internals,
# this one tests the host↔container data path.
#
# Usage:
#   bash tests/test_bind_mount.sh                    # build + test
#   bash tests/test_bind_mount.sh --skip-build       # test existing image
#   bash tests/test_bind_mount.sh --image <name>     # test a pulled image
#
# What it tests:
#   1. Input mount is read-only (:ro prevents writes)
#   2. Output mount is writable and files appear on the host
#   3. Output files are owned by the host user (--user UID:GID)
#   4. Conda envs work under --user (non-root)
#   5. Synthetic pipeline completes through bind-mounted I/O
#   6. Paths with spaces in mount source work

set -euo pipefail

IMAGE="l3rseq:test"
SKIP_BUILD=0

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --image)      IMAGE="$2"; SKIP_BUILD=1; shift 2 ;;
        --help)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "========================================"
echo "L3Rseq Bind Mount Test"
echo "========================================"
echo "  Image: $IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Build (optional)
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "[0/6] Building Docker image ..."
    if docker build -f .devcontainer/build/Dockerfile -t "$IMAGE" "$REPO_ROOT" \
         > /tmp/docker_bind_mount_build.log 2>&1; then
        pass "Docker build succeeded"
    else
        fail "Docker build failed (see /tmp/docker_bind_mount_build.log)"
        tail -20 /tmp/docker_bind_mount_build.log | sed 's/^/    /'
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
else
    echo "[0/6] Skipping build (using existing image: $IMAGE)"
    if docker image inspect "$IMAGE" > /dev/null 2>&1; then
        pass "Image exists"
    else
        fail "Image not found: $IMAGE (try: docker pull $IMAGE)"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Set up temp directories (cleaned up on exit)
# ---------------------------------------------------------------------------

INPUT_DIR=$(mktemp -d)
OUTPUT_DIR=$(mktemp -d)
cleanup() { rm -rf "$INPUT_DIR" "$OUTPUT_DIR"; }
trap cleanup EXIT

# Populate input dir with the repo's synthetic test data
cp -r "$REPO_ROOT/tests/data/"* "$INPUT_DIR/" 2>/dev/null || true
cp "$REPO_ROOT/resources/references"/test_gene*.fasta "$INPUT_DIR/" 2>/dev/null || true
cp "$REPO_ROOT/resources/references"/test_gene*.fasta.fai "$INPUT_DIR/" 2>/dev/null || true

echo "  Input dir:  $INPUT_DIR"
echo "  Output dir: $OUTPUT_DIR"
echo ""

# Common docker run flags
RUN="docker run --rm --user $(id -u):$(id -g)"

# ---------------------------------------------------------------------------
# Step 1: Read-only input enforcement
# ---------------------------------------------------------------------------

echo "[1/6] Read-only input mount ..."

if $RUN \
    -v "$INPUT_DIR:/data/input:ro" \
    "$IMAGE" \
    bash -c "touch /data/input/should_fail 2>/dev/null"; then
    fail "Input mount is writable — :ro not enforced"
else
    pass "Input mount is read-only"
fi

# Verify data is readable
FILE_COUNT=$($RUN \
    -v "$INPUT_DIR:/data/input:ro" \
    "$IMAGE" \
    bash -c "ls /data/input/ 2>/dev/null | wc -l" | tr -d ' ')
if [ "$FILE_COUNT" -gt 0 ]; then
    pass "Input data readable ($FILE_COUNT files)"
else
    fail "Input data not readable"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Writable output mount
# ---------------------------------------------------------------------------

echo "[2/6] Writable output mount ..."

if $RUN \
    -v "$OUTPUT_DIR:/data/output" \
    "$IMAGE" \
    bash -c "echo bind_mount_test > /data/output/probe.txt"; then
    pass "Container can write to output mount"
else
    fail "Container cannot write to output mount"
fi

# Verify file is visible on the host
if [ -f "$OUTPUT_DIR/probe.txt" ] && grep -q "bind_mount_test" "$OUTPUT_DIR/probe.txt"; then
    pass "Output file visible on host with correct contents"
else
    fail "Output file missing or wrong contents on host"
fi
rm -f "$OUTPUT_DIR/probe.txt"
echo ""

# ---------------------------------------------------------------------------
# Step 3: UID/GID file ownership
# ---------------------------------------------------------------------------

echo "[3/6] File ownership (--user UID:GID) ..."

$RUN \
    -v "$OUTPUT_DIR:/data/output" \
    "$IMAGE" \
    bash -c "echo owned > /data/output/owner_test.txt"

if [ -f "$OUTPUT_DIR/owner_test.txt" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        OWNER=$(stat -f '%u' "$OUTPUT_DIR/owner_test.txt")
    else
        OWNER=$(stat -c '%u' "$OUTPUT_DIR/owner_test.txt")
    fi
    if [ "$OWNER" = "$(id -u)" ]; then
        pass "Output owned by host user (UID=$OWNER)"
    else
        fail "Output owned by UID=$OWNER, expected $(id -u)"
    fi
else
    fail "owner_test.txt not created"
fi

# Subdirectory ownership
$RUN \
    -v "$OUTPUT_DIR:/data/output" \
    "$IMAGE" \
    bash -c "mkdir -p /data/output/subdir/nested && echo deep > /data/output/subdir/nested/file.txt"

if [ -f "$OUTPUT_DIR/subdir/nested/file.txt" ]; then
    pass "Nested subdirectories created through mount"
else
    fail "Nested subdirectory creation failed"
fi
rm -rf "$OUTPUT_DIR/owner_test.txt" "$OUTPUT_DIR/subdir"
echo ""

# ---------------------------------------------------------------------------
# Step 4: Conda envs accessible under --user
# ---------------------------------------------------------------------------

echo "[4/6] Conda envs work with --user (non-root) ..."

for env in NanoporeMap longread_umi cutadaptenv LoFreq; do
    if $RUN "$IMAGE" \
        bash -c "eval \"\$(conda shell.bash hook)\" && conda activate $env" 2>/dev/null; then
        pass "conda activate $env"
    else
        fail "conda activate $env"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 5: Synthetic pipeline through bind mounts
# ---------------------------------------------------------------------------

echo "[5/6] Synthetic pipeline via bind mounts ..."
echo "  (this takes ~30 seconds)"
echo ""

rm -rf "$OUTPUT_DIR"/*

# run_tests.sh does `rm -rf $OUTPUT_DIR` at startup, which fails when
# the directory is a mount point ("Device or resource busy").  Instead
# of mounting directly at tests/output, we mount the whole tests dir
# and let run_tests.sh manage its own output directory normally.  We
# then copy results out to verify they appear on the host.
if $RUN \
    -v "$REPO_ROOT/tests:/workspace/tests" \
    "$IMAGE" \
    bash -c "cd /workspace && bash tests/run_tests.sh --skip-preprocess --no-viewer" \
    2>&1 | tee /tmp/docker_bind_mount_test.log | tail -5; then
    pass "Synthetic pipeline completed"
else
    fail "Synthetic pipeline failed (see /tmp/docker_bind_mount_test.log)"
fi

# Verify output files landed on the host (tests/ is bind-mounted)
OUTPUT_COUNT=$(find "$REPO_ROOT/tests/output" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$OUTPUT_COUNT" -gt 0 ]; then
    pass "Pipeline produced $OUTPUT_COUNT files on host"
else
    fail "No pipeline output files on host"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 6: Paths with spaces
# ---------------------------------------------------------------------------

echo "[6/6] Paths with spaces in mount source ..."

SPACE_BASE=$(mktemp -d)
SPACE_DIR="$SPACE_BASE/path with spaces"
mkdir -p "$SPACE_DIR"

if $RUN \
    -v "$SPACE_DIR:/data/output" \
    "$IMAGE" \
    bash -c "echo hello > /data/output/space_test.txt"; then
    if [ -f "$SPACE_DIR/space_test.txt" ]; then
        pass "Mount with spaces works"
    else
        fail "File not written through spaced path"
    fi
else
    fail "Container failed with spaced mount path"
fi
rm -rf "$SPACE_BASE"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo "Some tests FAILED."
    exit 1
fi

echo "All bind mount checks passed."
