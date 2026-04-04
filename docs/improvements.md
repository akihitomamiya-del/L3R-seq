# Codebase Improvement Plan

Prioritized list of improvements identified from a full audit of the L3Rseq
codebase (April 2026). Organized by impact — start from the top.

## Maintenance priority

The items below are ordered by general impact, but for **ongoing
maintainability** specifically, this is the recommended attack order:

| Priority | Item | Why it's a maintenance gate |
|----------|------|---------------------------|
| **Do now** | [#6 Fix version skew](#6-fix-version-skew) | Three files already out of sync — takes 5 minutes to fix, prevents wrong citations |
| **Do now** | [#1 CI test pipeline](#1-add-ci-test-pipeline) | Without CI, every other improvement risks silent regressions |
| **Do now** | [#17 Dispatcher tests](#17-add-dispatcher-tests) | Main entry point has almost no tests — fast to write, high value |
| **Week 1** | [#2 Shared shell library](#2-extract-shared-shell-library) | Every pipeline bug fix currently requires patching 8+ scripts |
| **Week 1** | [#9 Stop swallowing summary errors](#9-stop-swallowing-summary-reporting-errors) | Silent failures in summary reporting hide data issues from users |
| **Week 1** | [#16 Test selectability](#16-add-test-selectability) | Can't iterate on one test without running full 45s suite |
| **Week 2** | [#3 Step 09 error handling](#3-fix-step-09-error-handling) | The most complex script has the weakest error handling |
| **Week 2** | [#13 Pre-commit hooks](#13-add-pre-commit-hooks) | Shellcheck catches bugs before they land; pairs with CI |
| **Ongoing** | [#10 Step 08 test coverage](#10-validate-step-08-variant-output-in-tests) | Test gaps make refactoring risky |
| **Week 1** | [#11 Viewer maintainability](#11-viewer-maintainability-overhaul) | 460 duplicated lines across 3 pages — every viewer fix is 3x work |

See also: [docs/development.md § Maintenance](development.md#maintenance) for
release checklist, version management, linting, and test workflow details.

---

## High Impact

### 1. Add CI test pipeline

**Problem:** 156 deterministic tests exist but only run manually. No automated
validation on PRs or pushes.

**What to do:**
- Create `.github/workflows/test.yml` that runs `tests/run_tests.sh --quick`
  on pull requests and pushes to `main`
- Add shellcheck linting for all scripts (`scripts/*.sh`, `L3Rseq`)
- Consider a slower nightly job that runs the full suite (without `--quick`)

**Why it matters:** This is the single highest-leverage improvement. Every other
change on this list is safer to make once CI catches regressions automatically.

**Files involved:**
- New: `.github/workflows/test.yml`
- Existing: `tests/run_tests.sh`

---

### 2. Extract shared shell library

**Problem:** Five distinct patterns are duplicated across the pipeline scripts,
totaling 300-400 lines of redundant code. Detailed inventory below.

#### Pattern A: Barcode/RPI nested loop (9 scripts)

The same nested directory traversal is copy-pasted with minor variations:

```bash
for barcode_dir in "$input_dir"/*/; do
    [ -d "$barcode_dir" ] || continue
    local bname
    bname=$(basename "$barcode_dir")
    for rpi_dir in "$barcode_dir"/*/; do
        [ -d "$rpi_dir" ] || continue
        local rpi_name
        rpi_name=$(basename "$rpi_dir")
        # ... step-specific work ...
    done
done
```

| Script | Outer loop | Inner loop | Body lines |
|--------|-----------|-----------|------------|
| `05_consensus.sh` | 33-86 | 39-85 | 47 |
| `06_extract.sh` | 20-84 | 26-83 | 58 |
| `07_map.sh` | 59-108 | 65-107 | 43 |
| `08_variants.sh` | 32-69 | 38-68 | 31 |
| `09_tail_correct.sh` | 209-435 | 215-434 | 220 |
| `10_export_csv.sh` | 176-220 | 182-219 | 38 |
| `11_count.sh` | 157-225 | 162-224 | 63 |
| `discover_introns.sh` | 23-200 | 29-199 | 171 |

Note: `03_demultiplex.sh` uses only the outer barcode loop (no RPI nesting).
`01_concat.sh` and `02_trim.sh` iterate differently (flat file lists).

#### Pattern B: Conda activate/deactivate (22 blocks in `L3Rseq`)

The dispatcher repeats this 4-line block for every step — once in each
`cmd_*` function and again in `cmd_run`:

```bash
source "$SCRIPT_DIR/scripts/NN_step.sh"
conda activate "$ENV_NAME"
run_step_NN "$input_dir" "$output_dir" ...
conda deactivate
```

Locations in individual `cmd_*` functions:
- Lines 220-223 (step 02), 250-253 (step 03), 278-281 (filter),
  331-342 (step 04, conditional), 369-372 (step 05), 401-404 (step 06),
  429-432 (step 07), 459-462 (step 08), 501-505 (step 09),
  598+614 (regions), 658-661 (step 11), 689-691 (discover-introns)

Duplicated again in `cmd_run` pipeline execution:
- Lines 874-878 (step 02), 892-896 (step 03), 906-909 (filter),
  925-935 (step 04), 940-944 (step 05), 957-961 (step 06),
  967-971 (step 07), 986-988 (step 08), 997-1002 (step 09)

Total: 22 nearly identical blocks.

#### Pattern C: Input file existence check (8 scripts)

Each step checks for its predecessor's output and warns if missing:

```bash
if [ ! -f "$input_file" ]; then
    echo "  WARNING: No $filename in $bname/$rpi_name, skipping (run step XX first)"
    continue
fi
```

| Script | Line | Checks for | Prerequisite |
|--------|------|-----------|-------------|
| `05_consensus.sh` | 57 | `UMIclusterfull/` directory | step 04 |
| `06_extract.sh` | 42 | consensus fasta | step 05 |
| `07_map.sh` | 73 | `*_extracted_trimmed.fa` | step 06 |
| `08_variants.sh` | 46 | `*_aligned.sort.bam` | step 07 |
| `09_tail_correct.sh` | 223 | `*_mapped_only.sam` | step 07 |
| `10_export_csv.sh` | 190 | `*_corrected.sam` | step 09 |
| `11_count.sh` | 170 | `*_primary.sort.bam` | step 07 |
| `discover_introns.sh` | 37 | `*_mapped_only.sam` | step 07 |

#### Pattern D: Summary statistics blocks (17 `_summary_append` calls)

Every step ends with a summary loop that gathers metrics and calls:

```bash
_summary_append "$output_dir" "$_bname" "$_rname" "NN" "metric" "$value" 2>/dev/null || true
```

Found in: `01_concat.sh` (line 48), `02_trim.sh` (65-66), `03_demultiplex.sh`
(81-82), `04_umi.sh` (113-114, 198), `05_consensus.sh` (104), `06_extract.sh`
(97), `07_map.sh` (122), `08_variants.sh` (82), `10_export_csv.sh` (233,
245-247). All 17 calls use `2>/dev/null || true` which silences write errors.

#### Pattern E: Step logging (11 scripts, 22 echo pairs)

Every step function starts with `echo "[Step NN] Doing X ..."` and ends with
`echo "[Step NN] Done."`. The step number is hardcoded in each script.

---

**What to do:**

Create `scripts/lib.sh` with shared utility functions:

```bash
# Pattern A: iterate barcode/RPI directories, calling a callback for each
iterate_samples() {
    local input_dir="$1"; shift
    local callback="$1"; shift
    for barcode_dir in "$input_dir"/*/; do
        [ -d "$barcode_dir" ] || continue
        local bname; bname=$(basename "$barcode_dir")
        for rpi_dir in "$barcode_dir"/*/; do
            [ -d "$rpi_dir" ] || continue
            local rpi_name; rpi_name=$(basename "$rpi_dir")
            "$callback" "$bname" "$rpi_name" "$rpi_dir" "$@"
        done
    done
}

# Pattern B: source a step script, activate conda, run, deactivate
conda_run() {
    local env="$1" script="$2" func="$3"; shift 3
    source "$SCRIPT_DIR/scripts/$script"
    conda activate "$env"
    "$func" "$@"
    conda deactivate
}

# Pattern C: check a prerequisite file exists, warn and return 1 if not
require_input() {
    local file="$1" bname="$2" rpi="$3" step_hint="$4"
    if [ ! -f "$file" ] && [ ! -d "$file" ]; then
        echo "  WARNING: Missing $(basename "$file") in $bname/$rpi, skipping (run step $step_hint first)"
        return 1
    fi
}

# Pattern D: summary append with error reporting
summary_metric() {
    _summary_append "$@" || echo "  WARNING: Failed to write summary metric" >&2
}

# Pattern E: step logging
log_step() { echo "[Step $1] $2"; }
```

Source from each step script: `source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"`

**Why it matters:** Eliminates ~300-400 lines of duplicated code. More
importantly, when the traversal logic needs to change (e.g., adding a
`.done` marker check, changing the skip condition, adding logging), it
only needs to change in one place instead of 9. The conda wrapper in the
dispatcher alone would cut ~90 lines.

**Files involved:**
- New: `scripts/lib.sh`
- Modified: `L3Rseq` (replace 22 conda blocks with `conda_run` calls)
- Modified: `scripts/05_consensus.sh` through `scripts/11_count.sh`,
  `scripts/discover_introns.sh` (replace nested loops with `iterate_samples`)

---

### 3. Fix step 09 error handling

**Problem:** `09_tail_correct.sh` disables `set -e` on line 16 for 400+ lines
and never fully restores safe error handling. Specific issues:

- `set +e` spans the entire function — any unguarded command failure is silent
- The trap on line 235 uses quoting that won't expand `$tmp_dir` correctly at
  signal time (single quotes inside double quotes)
- The trap only fires on INT/TERM, not on normal `set -e` failures
- `set -e` is restored on line 437 but trap is not reset for normal errors

**What to do:**
- Isolate the `set +e` regions to the smallest possible scope (wrap only the
  specific commands that need it, not the entire function)
- Fix the trap to use a cleanup function instead of inline string:
  ```bash
  _cleanup_09() { rm -rf "$tmp_dir"; }
  trap _cleanup_09 EXIT
  ```
- Add explicit error checks (`if ! command; then ...`) for critical operations
  instead of relying on `set +e`
- Consider splitting the function into smaller sub-functions with clear error
  contracts

**Why it matters:** This is the most complex script in the pipeline and the most
likely to silently produce wrong results. A corrupted intermediate file won't
be caught.

**Files involved:**
- `scripts/09_tail_correct.sh`

---

### 4. Fix XSS in viewer HTML

**Problem:** `genes.html` uses `innerHTML` with unsanitized data in ~5 places:

- Line 808: gene name in section header
- Line 816: isoform label in legend
- Line 869: gene name in coverage header
- Line 894: similar injection point
- `index.html` line 626-627: track label in legend

While the data is currently server-controlled, gene names from GFF/BED files
could contain angle brackets or special characters.

**What to do:**
- Replace `innerHTML` with `textContent` for plain text (gene names, labels)
- Use DOM methods (`createElement`, `appendChild`) for structured content
- Example fix:
  ```javascript
  // Before
  div.innerHTML = `<h3>${gene} — Isoform composition</h3>`;
  // After
  const h3 = document.createElement('h3');
  h3.textContent = gene + ' — Isoform composition';
  div.appendChild(h3);
  ```

**Why it matters:** Trivial to fix, eliminates an entire class of vulnerability.

**Files involved:**
- `igv_viewer/genes.html`
- `igv_viewer/index.html`

---

## Medium Impact

### 5. Add timeouts to `execSync` calls in viewer

**Problem:** `server.js` line 624 and multiple places in `pileup.js` call
`execSync` for samtools without a `timeout` parameter. A corrupted or
truncated BAM file could hang the server indefinitely.

**What to do:**
- Add `{ timeout: 10000 }` (10 seconds) to all `execSync` calls
- Wrap in try/catch to handle timeout errors gracefully

**Files involved:**
- `igv_viewer/server.js` (line 624)
- `igv_viewer/pileup.js` (lines 55, 76, 83, 92, 101, 114)

---

### 6. Fix version skew

**Problem:** Version numbers are maintained manually in three places and have
drifted apart:

- `CITATION.cff` — says v1.0.10
- `L3Rseq` script `VERSION=` — says 1.0.11
- `CHANGELOG.md` — says 1.0.12

**What to do:**
- Immediately fix all three to match the current version
- Create a `scripts/bump-version.sh` that updates all version strings
  atomically (grep + sed across the three files)
- Document the release process: `bump-version.sh 1.0.13 && git tag v1.0.13`

**Files involved:**
- `CITATION.cff`
- `L3Rseq` (VERSION variable)
- `CHANGELOG.md`
- New: `scripts/bump-version.sh`

---

### 7. Add graceful shutdown to viewer

**Problem:** The Node server ignores SIGHUP (line 15) but has no SIGTERM/SIGINT
handler. Container orchestration will force-kill the process, potentially
corrupting in-flight responses.

**What to do:**
```javascript
function shutdown(signal) {
  console.log(`${signal} received, shutting down...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000); // force after 5s
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
```

**Files involved:**
- `igv_viewer/server.js`

---

### 8. Replace silent `catch {}` blocks in viewer

**Problem:** Multiple empty catch blocks in `server.js` silently swallow errors:

- Line 46: `readdirSync` failure returns `[]`
- Line 91: returns `null`
- Line 630: samtools tag discovery silently fails

**What to do:**
- Add `console.warn` with context to each catch block
- Example: `catch (e) { console.warn(\`[warn] readdir ${dir}: ${e.message}\`); return []; }`

**Files involved:**
- `igv_viewer/server.js`

---

### 9. Stop swallowing summary reporting errors

**Problem:** Every step script does:
```bash
_summary_append "$output_dir" ... 2>/dev/null || true
```
If `pipeline_summary.tsv` can't be written (disk full, permission issue), the
user gets no warning.

**What to do:**
- Remove `2>/dev/null || true` from `_summary_append` calls
- Let failures propagate, or at minimum emit a warning on first failure and
  suppress subsequent ones

**Files involved:**
- `scripts/01_concat.sh` through `scripts/11_count.sh` (all step scripts)

---

### 10. Validate step 08 variant output in tests

**Problem:** The test suite checks that variant files from step 08 exist but
never validates their content. A regression that produces empty or malformed
VCF files would pass tests.

**What to do:**
- Add assertions for VCF row counts or specific expected variant positions
- At minimum: `wc -l` on the VCF and check it's above a threshold

**Files involved:**
- `tests/run_tests.sh` (around line 411-416)
- `tests/expected/` (add expected VCF metrics)

---

## Lower Priority

### 11. Viewer maintainability overhaul

**Problem:** The viewer has grown to ~3,900 lines across 4 main files. 83% of
page code is inline JavaScript with **400–500 lines duplicated** across the
three HTML pages. This is the root cause of the recurring "fix one page, forget
the others" pattern.

#### Duplication inventory

| Duplicated pattern | Lines per page | Pages | Total waste |
|--------------------|---------------|-------|-------------|
| `syncNavLinks()` | 4–8 | 3 | ~20 lines |
| Dataset dropdown init | 15–20 | 3 | ~45 lines |
| Color palette (`BARCODE_HUES` + `barcodeHue()`) | ~32 | 3 | ~64 lines |
| Checkbox/toggle logic (toggleAll, toggleBarcode, syncAllCheckbox) | 70–100 | 3 | ~180 lines |
| State save/restore (saveState, restoreState) | 90–115 | 2 | ~100 lines |
| `togglePanel()` | 6 | 2 | ~6 lines |
| URL parameter handling (`?name=`, sessionStorage) | 15–20 | 3 | ~45 lines |
| **Subtotal** | | | **~460 lines** |

#### Page breakdown

| Page | Total lines | Inline JS (%) | Unique logic |
|------|------------|---------------|--------------|
| index.html | 972 | 762 (78%) | IGV.js browser init, track toggles, pileup |
| genes.html | 1,022 | 892 (87%) | Table/chart/isoform/coverage views, gene click |
| umi.html | 687 | 585 (85%) | Overlay/grid/table views, bin-size histograms |
| **Total** | **2,681** | **2,239** | |

#### Additional concerns

- **Inline CSS duplication**: ~50 lines of header, panel, and button styles
  repeated in each `<style>` block
- **No browser caching**: Inline JS means the browser re-downloads shared logic
  on every page navigation
- **server.js** (779 lines): Hidden dataset list hardcoded on line 525;
  `discoverTracks()` (60 lines) has deep nested loops; unused `compression`
  dependency imported but never called
- **Test gap**: `test_buttons.js` has 12 test cases but no runner — must be
  invoked manually, no `npm test` script

#### Phase 1: Extract shared JS — `igv_viewer/js/shared.js` (~200 lines)

**Effort: ~4 hours. Highest ROI.**

```
shared.js
├── syncNavLinks(currentPage, datasetName)
├── buildDatasetDropdown(selectEl, onChange)
├── BARCODE_HUES + HUE_POOL + barcodeHue(barcode)
├── CheckboxManager(container, items, onChange)
│   ├── toggleAll() / toggleBarcode() / toggleSample()
│   ├── syncAllCheckbox()
│   └── updateCount()
├── saveState(key, obj) / restoreState(key)
└── togglePanel(panelId)
```

Import via `<script src="/js/shared.js"></script>` before page-specific JS.
Each page's inline JS shrinks to unique logic only. The CLAUDE.md rule about
"apply fixes across all 3 pages" largely goes away for shared behavior.

#### Phase 2: Extract shared CSS — `igv_viewer/css/shared.css` (~50 lines)

**Effort: ~1 hour.**

Header, panel collapse, button, and base reset styles into one file.
Page-specific styles remain inline (avoids extra HTTP request for small amounts).

#### Phase 3: Config and cleanup

**Effort: ~1 hour.**

- Move hidden dataset list from `server.js:525` to `config.js`
- Remove unused `compression` dependency
- Add `npm test` script that runs `test_buttons.js` with exit codes

#### Phase 4: `npm test` integration

**Effort: ~2 hours.**

Wrap `test_buttons.js` with proper exit codes so `tests/run_tests.sh` can
invoke it. No need for Jest/Mocha — the existing Puppeteer assertions are
sufficient; they just need a runner.

#### What NOT to do

- **Don't migrate to React/Vue/Svelte.** Server-rendered pages with progressive
  enhancement is the right fit — simple deployment, no build step, works in
  VS Code Simple Browser.
- **Don't add webpack/vite.** `<script src>` is fine at this scale (~200 lines
  shared). A bundler adds complexity without proportional benefit.
- **Don't split server.js yet.** At 779 lines with 7 endpoints, it's manageable.
  Revisit if it crosses ~1,200 lines.

**Files involved:**
- New: `igv_viewer/js/shared.js`, `igv_viewer/css/shared.css`
- Modified: `igv_viewer/index.html`, `igv_viewer/umi.html`, `igv_viewer/genes.html`
- Modified: `igv_viewer/config.js`, `igv_viewer/server.js`, `igv_viewer/package.json`

---

### 12. Add health check endpoint

**Problem:** No `/healthz` endpoint for container orchestration or monitoring.

**What to do:**
```javascript
if (urlPath === "/healthz") {
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ status: "ok" }));
  return;
}
```

**Files involved:**
- `igv_viewer/server.js`

---

### 13. Add pre-commit hooks

**Problem:** No automated linting on commit. Style inconsistencies and shell
scripting errors can land without review.

**What to do:**
- Add `.pre-commit-config.yaml` with:
  - `shellcheck` for shell scripts
  - `shfmt` for shell formatting (optional)
  - `prettier` for HTML/JS (optional)
- Document in `CONTRIBUTING.md` (if/when created)

**Files involved:**
- New: `.pre-commit-config.yaml`

---

### 14. Fill documentation gaps

**Problem:** Several useful docs are missing:

- **`CONTRIBUTING.md`** — no fork/branch/PR workflow, no code style guide
- **API documentation** — viewer endpoints (`/api/umi-stats`,
  `/api/gene-counts`, `/api/gene-coverage`) are undocumented
- **Troubleshooting/FAQ** — common errors (conda activation, BLAST DB setup,
  primer design) have no reference
- **Primer design guide** — no tutorial for designing primers for new organisms

**What to do:**
- Create `CONTRIBUTING.md` with development workflow and code conventions
- Add API section to `docs/advanced.md` or create `docs/api.md`
- Create `docs/troubleshooting.md`

---

### 15. Optimize CIGAR parsing

**Problem:** `09a_parse_cigar.sh` runs 3 separate `grep | grep | awk` chains
on the same CIGAR string (lines 19-21), spawning 9 processes per read:

```bash
RESULT_Rightclip_N=$(echo "$RESULT_Aln_CIGAR" | grep -Eo '[0-9]+S$' | grep -Eo '^[0-9]+' | awk '...')
RESULT_Total_M=$(echo "$RESULT_Aln_CIGAR" | grep -Eo '[0-9]+M' | grep -Eo '[0-9]+' | awk '...')
RESULT_Total_D=$(echo "$RESULT_Aln_CIGAR" | grep -Eo '[0-9]+D' | grep -Eo '[0-9]+' | awk '...')
```

**What to do:**
- Replace with a single `awk` call that parses all CIGAR operations in one
  pass and outputs all three values
- This is ~3x faster per read and matters at scale (thousands of reads)

**Files involved:**
- `scripts/09a_parse_cigar.sh`

---

### 16. Add test selectability

**Problem:** The test suite runs all-or-nothing (with only `--quick` and
`--skip-preprocess` as coarse filters). During development, you often want to
iterate on a single test group — e.g., only the SLAM-seq tests or only the
viewer API tests — without waiting 45 seconds for the full suite.

Tests are organized as numbered blocks (TEST 1 through TEST 8) but there's
no `--test N` flag to run a specific one.

**What to do:**
- Add a `--test N` flag to `tests/run_tests.sh` that runs only block N
- Alternatively, extract each test block into a function and allow calling by
  name: `--test slam`, `--test viewer`, `--test blast`
- Keep `--quick` and `--skip-preprocess` as they are (they're useful shortcuts)

**Files involved:**
- `tests/run_tests.sh` (refactor test blocks into selectable functions)

---

### 17. Add dispatcher tests

**Problem:** The `L3Rseq` dispatcher handles 14+ subcommands with argument
parsing, validation, and environment setup, but is only tested for `--help`
and `--version` (in `tests/test_docker_image.sh`, Docker-only). No tests for:

- Unknown subcommand error handling
- Invalid argument combinations (`--ref` without a file, missing required args)
- `--start-at` / `--stop-at` range validation
- Individual subcommand help (`L3Rseq map --help`)

**What to do:**
- Create `tests/test_dispatcher.sh` (or add a block to `run_tests.sh`) that
  tests argument parsing without running the actual pipeline:
  ```bash
  # Should succeed (help/version)
  L3Rseq --help >/dev/null && pass "--help exits 0"
  L3Rseq --version | grep -q "^L3Rseq " && pass "--version format"

  # Should fail gracefully
  ! L3Rseq unknown-cmd 2>/dev/null && pass "unknown subcommand exits non-zero"
  ! L3Rseq run 2>/dev/null && pass "run without --ref exits non-zero"
  ```
- These tests are fast (no data processing) and can always run

**Files involved:**
- New: `tests/test_dispatcher.sh` (or new block in `tests/run_tests.sh`)
