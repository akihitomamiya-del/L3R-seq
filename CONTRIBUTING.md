# Contributing to L3Rseq

Thank you for considering contributing to L3Rseq. This guide covers the
development setup, workflow, and conventions.

## Development setup

L3Rseq uses a **devcontainer** for a fully reproducible environment. All conda
environments and bioinformatics tools are pre-built in the Docker image.

1. Clone the repository and open it in VS Code (or GitHub Codespaces).
2. Reopen in the devcontainer when prompted, or run:
   ```bash
   docker-compose up
   ```
3. The container starts with all conda environments ready. **Do not** create or
   modify conda environments -- they are read-only. Pipeline tools are not on
   the default PATH; the `L3Rseq` dispatcher activates the correct environment
   for each step automatically.

Available conda environments: `longread_umi`, `cutadaptenv`, `NanoporeMap`,
`LoFreq`, `UMIC-seq`, `Entrez`, `analysis`.

The IGV viewer auto-starts on port 8080 via `postStartCommand`. Use the VS Code
Ports tab (or Codespaces URL) to open it in a browser.

## Branch and PR workflow

1. Fork the repository (external contributors) or create a feature branch.
2. Branch from `main`. Use descriptive branch names (e.g., `fix/step09-cigar`,
   `feat/gene-coverage-api`).
3. Open a pull request against `main`.
4. Squash merge is preferred to keep the history clean.
5. Always `git fetch --all && git pull` before starting work -- upstream fixes
   may already address the issue.

### Inverted .gitignore

The repo uses an inverted `.gitignore`: everything is ignored (`*`) and specific
paths are allowlisted with `!` prefixes. New files will not be staged unless
their path is added to `.gitignore` with a `!` prefix.

## Code conventions

### Shell scripts

- Use `set -euo pipefail` at the top of every script (exception: `09_tail_correct.sh`
  uses `set +e` due to complex control flow).
- Pipeline progress messages use `[Step NN]` and `[script_name]` prefixes.
- Log files are auto-generated as `l3rseq_YYYYMMDD_HHMMSS.log` in the output
  directory.

### Output file naming

Output files in steps 05-10 include the RPI name as a prefix for identification
outside their directory context: `${rpi_name}_<suffix>`.

Examples:
- Step 05: `consensus_barcode01_RPI_1.fa`
- Step 07: `barcode01_RPI_1_primary.sort.bam`
- Step 09: `barcode01_RPI_1_corrected.sort.bam`
- Step 10: `barcode01_barcode01_RPI_1.csv`

### Viewer (JavaScript)

- Changes to the IGV viewer must be applied to **all three pages**: `index.html`,
  `umi.html`, and `genes.html`.
- Follow the strict cycle: edit, restart viewer, screenshot-verify with Puppeteer,
  test the user scenario end-to-end, read screenshots before declaring done.
- Shared logic lives in `igv_viewer/js/shared.js`.

## Testing

### Quick smoke test (CI)

```bash
bash tests/run_tests.sh --quick        # ~26 seconds
```

### Full synthetic test suite

```bash
bash tests/run_tests.sh                # All steps, ~90 seconds
bash tests/run_tests.sh --skip-preprocess  # Steps 04-10 only
bash tests/run_tests.sh --test N       # Individual block (1, 1b, 1c, 2, 3, 4, 5, 6, 7, 8, 9)
```

Block aliases: `preprocess`, `negative`, `pipeline`, `slam`, `splice`, `blast`,
`viewer`, `plots`, `counting`, `shell`, `dispatcher`.

### Dispatcher argument parsing

```bash
bash tests/test_dispatcher.sh
```

### Shell function unit tests

```bash
bash tests/test_shell_functions.sh     # CIGAR, splice, BLAST helpers
```

### Viewer tests

```bash
cd igv_viewer && npm test              # Puppeteer DOM tests (46 checks)
cd igv_viewer && npm run test:stress   # Stress tests (real data)
```

## Releasing

1. Bump the version across all files atomically:
   ```bash
   bash scripts/bump-version.sh X.Y.Z
   ```
   This updates `CITATION.cff`, `L3Rseq` (the `VERSION` variable), and
   `CHANGELOG.md`.

2. Commit the version bump and tag:
   ```bash
   git add -A && git commit -m "Release vX.Y.Z"
   git tag vX.Y.Z
   git push origin main --tags
   ```

3. The pushed tag triggers `.github/workflows/docker-publish.yml`, which builds
   and publishes the Docker image to `ghcr.io/akihitomamiya-del/l3rseq`.

4. After CI finishes, rebuild the devcontainer to pick up the new base image.

## Pre-commit hooks

Optional but recommended for local development. CI already provides shellcheck
coverage.

```bash
pip install pre-commit
pre-commit install
```

This runs linters (shellcheck, etc.) automatically before each commit.
