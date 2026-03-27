#!/bin/bash
# test_docker_image.sh — Verify the default Docker image works for new users
#
# Run this from your HOST machine (not inside a container).
# Requires: Docker (rootful), internet access for image build.
#
# Usage:
#   bash tests/test_docker_image.sh                    # build + test
#   bash tests/test_docker_image.sh --skip-build       # test existing image
#   bash tests/test_docker_image.sh --image ghcr.io/akihitomamiya-del/l3rseq:latest  # test pulled image
#
# What it tests:
#   1. Docker image builds from Dockerfile
#   2. L3Rseq --version works
#   3. All conda environments and key tools are present
#   4. Synthetic test suite passes inside the container
#   5. --user UID:GID file ownership works correctly

set -euo pipefail

IMAGE="l3rseq:test"
SKIP_BUILD=0
CONTEXT_DIR="."

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --image)      IMAGE="$2"; SKIP_BUILD=1; shift 2 ;;
        --context)    CONTEXT_DIR="$2"; shift 2 ;;
        --help)
            echo "Usage: bash tests/test_docker_image.sh [--skip-build] [--image <name>] [--context <dir>]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "========================================"
echo "L3Rseq Docker Image Test"
echo "========================================"
echo "  Image: $IMAGE"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Build
# ---------------------------------------------------------------------------

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "[1/5] Building Docker image ..."
    if docker build -f .devcontainer/build/Dockerfile -t "$IMAGE" "$CONTEXT_DIR" > /tmp/docker_build.log 2>&1; then
        pass "Docker build succeeded"
    else
        fail "Docker build failed (see /tmp/docker_build.log)"
        tail -20 /tmp/docker_build.log | sed 's/^/    /'
        echo ""
        echo "Results: $PASS passed, $FAIL failed"
        exit 1
    fi
else
    echo "[1/5] Skipping build (using existing image: $IMAGE)"
    if docker image inspect "$IMAGE" > /dev/null 2>&1; then
        pass "Image exists: $IMAGE"
    else
        fail "Image not found: $IMAGE"
        echo "  Try: docker pull $IMAGE"
        exit 1
    fi
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Version + basic commands
# ---------------------------------------------------------------------------

echo "[2/5] Checking L3Rseq version and help ..."

VERSION=$(docker run --rm "$IMAGE" L3Rseq --version 2>&1)
if echo "$VERSION" | grep -q "L3Rseq"; then
    pass "L3Rseq --version: $VERSION"
else
    fail "L3Rseq --version failed: $VERSION"
fi

if docker run --rm "$IMAGE" L3Rseq --help > /dev/null 2>&1; then
    pass "L3Rseq --help works"
else
    fail "L3Rseq --help failed"
fi

# Check pipeline code is present
for f in L3Rseq config.sh scripts/09_tail_correct.sh scripts/plot_umi_bins.py UMIC-seq_L3Rseq/UMIC-seq_fastq_v2.py resources/references/test_gene.fasta; do
    if docker run --rm "$IMAGE" test -f "/workspace/$f"; then
        pass "File present: $f"
    else
        fail "File missing: $f"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 3: Conda environments and tools
# ---------------------------------------------------------------------------

echo "[3/5] Checking conda environments and tools ..."

# Check each conda env exists
for env in longread_umi cutadaptenv NanoporeMap LoFreq UMIC-seq; do
    if docker run --rm "$IMAGE" bash -c "eval \"\$(conda shell.bash hook)\" && conda activate $env" 2>/dev/null; then
        pass "Conda env: $env"
    else
        fail "Conda env missing: $env"
    fi
done

# Check key tools
TOOL_CHECKS=(
    "NanoporeMap:minimap2 --version"
    "NanoporeMap:samtools --version | head -1"
    "longread_umi:vsearch --version 2>&1 | head -1"
    "longread_umi:racon --version"
    "cutadaptenv:cutadapt --version"
    "LoFreq:lofreq version"
    "NanoporeMap:blastn -version | head -1"
)

for check in "${TOOL_CHECKS[@]}"; do
    env="${check%%:*}"
    cmd="${check#*:}"
    tool="${cmd%% *}"
    result=$(docker run --rm "$IMAGE" bash -c "eval \"\$(conda shell.bash hook)\" && conda activate $env && $cmd" 2>&1 | head -1)
    if [ -n "$result" ]; then
        pass "$tool ($env): $result"
    else
        fail "$tool ($env): not found or failed"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# Step 4: Synthetic test suite
# ---------------------------------------------------------------------------

echo "[4/5] Running synthetic test suite inside container ..."
echo "  (this takes ~30 seconds)"
echo ""

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rm -rf "$REPO_ROOT/tests/output"
if docker run --rm --user "$(id -u):$(id -g)" -v "$REPO_ROOT/tests:/workspace/tests" "$IMAGE" bash -c \
    "cd /workspace && bash tests/run_tests.sh --skip-preprocess --no-viewer" 2>&1 | \
    tee /tmp/docker_test.log | tail -5; then
    pass "Synthetic test suite passed"
else
    fail "Synthetic test suite failed (see /tmp/docker_test.log)"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 5: File ownership with --user
# ---------------------------------------------------------------------------

echo "[5/5] Checking --user file ownership ..."

TMPOUT=$(mktemp -d)
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$TMPOUT:/data/output" \
    "$IMAGE" \
    bash -c "echo test > /data/output/ownership_test.txt" 2>&1

if [ -f "$TMPOUT/ownership_test.txt" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        OWNER=$(stat -f '%u' "$TMPOUT/ownership_test.txt")
    else
        OWNER=$(stat -c '%u' "$TMPOUT/ownership_test.txt")
    fi
    if [ "$OWNER" = "$(id -u)" ]; then
        pass "Output file owned by host user (UID=$OWNER)"
    else
        fail "Output file owned by UID=$OWNER (expected $(id -u))"
    fi
else
    fail "Output file not created"
fi
rm -rf "$TMPOUT"
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

echo "All checks passed. Image is ready for publication."
