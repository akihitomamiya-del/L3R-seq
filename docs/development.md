[README](../README.md) | [Adaptation](adaptation.md) | [Requirements](requirements.md) | [Code Overview](code-overview.md) | **Development**

---

# Development

## Claude Code (AI-assisted development)

For running and customizing the pipeline with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Claude can execute the pipeline for you, explain results, and help you adapt the code to your own gene and organism — useful if you're less comfortable with shell scripting. If you want to modify the pipeline itself, fork the repo first so Claude can commit and push changes to your copy.

A dedicated devcontainer configuration (**L3Rseq Pipeline (Claude Code Sandbox)**) is provided for sandboxed use. It extends the pre-built L3Rseq image with the Claude CLI, a network firewall (for safe `--dangerously-skip-permissions` use), and developer tooling (zsh, git-delta, fzf). The firewall restricts outbound network access to GitHub, Anthropic API, npm, and VS Code services only. The devcontainer setup is based on Anthropic's [Claude Code DevContainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

**Getting started:**

1. Fork this repo (if you plan to make changes), then clone your fork
2. Open the repo in VS Code
3. Select **Reopen in Container** > **L3Rseq Pipeline (Claude Code Sandbox)**
4. Run `claude` in the terminal — authenticate interactively on first launch (no API key required)

## Viewer development

The IGV viewer (`igv_viewer/`) is a Node.js web app serving three pages that share a common dataset selector and navigation bar:

| Page | Path | Purpose |
|---|---|---|
| Alignment | `/` | IGV.js BAM tracks for steps 07/09, with sort/group/color by SAM tag |
| UMI analysis | `/umi` | Chart.js histograms of UMI bin size distributions from step 04 |
| Gene counts | `/genes` | Molecule counts, isoform breakdown, and coverage from step 11 |

The server (`server.js`) is a thin HTTP adapter; domain logic lives in `lib/` modules. Client JS is split per page (`js/alignment.js`, `js/umi.js`, `js/genes.js`) with shared utilities in `js/shared.js`. HTML files are slim shells with no inline JS. See [code overview](code-overview.md) for full file-by-file details.

### Development tools

Several tools are available for inspecting and verifying the viewer during development:

- **$\color{red}{\textsf{DEV}}$ overlay** — click the button in the bottom-right corner to toggle. Hover over any element to see its component name and CSS selector. Right-click copies the label to clipboard.
- **Puppeteer screenshots** — headless Chrome captures of any page for visual verification. IGV.js canvases appear blank in headless mode, but layout, headers, controls, and non-canvas elements are visible.
- **Puppeteer DOM tests** — `npm test` in `igv_viewer/` runs 46 automated checks (dataset loading, track toggles, display modes, etc.).
- **Stress tests** — `npm run test:stress` exercises scale-dependent behaviors with real data (track caps, barcode toggling, cross-page navigation).
- **API smoke tests** — curl-based checks that all endpoints return valid JSON and correct HTTP status codes.

In the L3Rseq Pipeline (Claude Code Sandbox), Claude can use these tools directly — taking screenshots, running tests, and inspecting DOM state to verify its own changes without manual checking.

## Running the pipeline with Snakemake

L3Rseq has two equivalent execution paths:

- **Bash dispatcher** — `L3Rseq run --input ... --outdir ... [flags]` (the original)
- **Snakefile** — `snakemake --cores N --configfile config.yaml` (Phase 2 addition)

Both produce the same outputs (verified by `tests/benchmarks/diff_step09.sh` and `diff_step11.sh` for the steps that have Python reimplementations). Use whichever fits your workflow — the dispatcher is simpler for one-off CLI runs, while Snakemake gives you resume-from-failure, DAG parallelism across `{barcode, RPI}` samples, and a declarative configuration surface.

### Quick start

```bash
# 1. Edit config.yaml to point at your input/output dirs and reference
$EDITOR config.yaml

# 2. Activate the Python env (Snakemake itself lives here, alongside pysam)
conda activate l3rseq_py

# 3. Dry-run to verify the DAG looks right
snakemake --cores 4 --configfile config.yaml --dry-run

# 4. Execute
snakemake --cores 4 --configfile config.yaml
```

### Useful flags

| Flag | What it does |
|---|---|
| `--cores N` | Max parallel jobs (set to your CPU count) |
| `--dry-run` | Show what would run without executing |
| `--forcerun <rule>` | Re-run a specific rule even if outputs exist |
| `--until <rule>` | Stop after a specific rule (e.g. `--until map`) |
| `--config key=value` | Override any config.yaml value (e.g. `--config pattern=CT,AG`) |
| `--rerun-incomplete` | Restart only the jobs that didn't finish cleanly |

### Resume-from-failure

Snakemake automatically tracks which outputs exist and re-runs only the missing jobs. Killing a run with Ctrl-C and re-launching the same command will pick up where it left off. To force a clean restart, delete the output directory.

### Step 11 (gene counting) requires explicit opt-in

The gene-counting rule is gated on `regions: ""` in `config.yaml` being non-empty. To run the full pipeline including step 11:

```bash
snakemake --cores 4 --configfile config.yaml \
          --config regions=tests/data/test_regions.tsv min_frac=0.3
```

The `min_frac=0.3` override is needed for the synthetic test fixture (whose consensus reads are ~500bp fragments of a 1300bp region); production data should keep the default `min_frac=0.95`.

### config.yaml vs. config.sh

`config.yaml` (Snakefile) and `config.sh` (bash dispatcher) must contain the same default values for the parameters they share. A CI check (`scripts/check_config_sync.py`) enforces this — edit both files in lockstep when changing a default.

---

[README](../README.md) | [Adaptation](adaptation.md) | [Requirements](requirements.md) | [Code Overview](code-overview.md) | **Development**
