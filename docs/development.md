[README](../README.md) | [Advanced](advanced.md) | [Testing](testing.md) | **Development** | [Requirements](requirements.md)

---

# Development

## UMI bin size analysis

Consensus quality depends on reads per UMI bin. Analysis on real data (*Arabidopsis* ccmC gene) shows quality plateaus at n>=3:

| Min reads per bin | Error-free consensus | Noise (/1000 bp) | Consensus reads retained |
|---|---|---|---|
| n>=1 | 48-80% | 0.5-4.4 | 4,727 |
| n>=2 | 78-80% | 0.5-0.7 | 4,727 |
| **n>=3** | **89%** | **0.22** | **3,423** |
| n>=4 | 93% | 0.13 | 2,147 |
| n>=5 | 95% | 0.11 | 1,192 |

The current default `min_bin_size=3` balances quality and yield. Generate your own bin analysis plots:

```bash
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --quality
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --quality --pattern CT,AG  # show both patterns
conda run -n analysis python3 scripts/plot_umi_bins.py results/ --compare results_umic/ --quality  # compare methods
```

Plots include conversion-colored editing/noise panels (stacked by nucleotide conversion type), a noise pattern breakdown table, and a parameter header showing the pattern and aggregate EC/NC counts. Output goes to `{run_dir}/figures/` by default.

The [UMI analysis page](advanced.md#alignment-viewer) in the viewer (`/umi`) provides interactive cross-sample comparison of bin size distributions.

## Viewer development

The IGV viewer is a multi-page web app (`/` alignment, `/umi` UMI analysis, `/genes` gene counts). Pages interact via URL parameters, URL hash, sessionStorage, and shared nav links. Follow this cycle for every change:

### Edit → Restart → Screenshot → Confirm

1. Edit the file(s)
2. Restart the viewer: `L3Rseq viewer --stop && L3Rseq viewer --dir <dir>`
3. Take Puppeteer screenshots to verify (see below)
4. Test the exact user-reported scenario end-to-end

**Never skip the screenshot step.** API responses can look correct while the page is broken.

```bash
# Puppeteer screenshot template
LD_LIBRARY_PATH="/opt/miniforge/envs/analysis/lib" node -e "
const puppeteer = require('/workspace/igv_viewer/node_modules/puppeteer');
(async () => {
  const b = await puppeteer.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await b.newPage();
  await page.setViewport({ width: 1400, height: 900 });
  await page.goto('http://localhost:8080/genes?name=runs/LibCheck', { waitUntil: 'networkidle0', timeout: 20000 });
  await new Promise(r => setTimeout(r, 3000));
  await page.screenshot({ path: '/tmp/test.png' });
  await b.close();
})();
"
```

### Common pitfalls and solutions

| Problem | Root cause | Solution |
|---------|-----------|----------|
| Browser shows old HTML | Cache | Server sends `Cache-Control: no-cache` for HTML. Always restart viewer. |
| State lost navigating between pages | sessionStorage unreliable in VS Code Simple Browser | Primary state in URL hash (`#v=table&sel=GENE`). Hash embedded in nav links. sessionStorage as backup. |
| Nav links don't carry state | Async `init()` hasn't updated links yet | Inline `<script>` in `<header>` sets links immediately from URL params. |
| `target="_blank"` doesn't work | VS Code Simple Browser | Gene names use `onclick` to update the Alignment Viewer link; no navigation. |
| Alignment viewer crashes | Empty BAMs or blocked `igv.org` fetch | BAI content check filters empty BAMs. `loadDefaultGenomes: false`. |
| Large FASTA blocks startup | `sanitizeFasta()` reads synchronously | Skip >10MB files. |
| `samtools \| awk` fails with pipefail | samtools non-zero for missing chromosomes | `{ samtools ... \|\| true; } \| awk` |

### Cross-page state architecture

All three pages share dataset via `?name=`. The genes page additionally stores view state in URL hash:

- `#v=table` — view mode
- `&sel=GENE` — selected gene for alignment viewer
- `&g=GENE` — gene filter, `&hk=GENE` — housekeeping, `&iso=1` — isoform rows

Other pages read `sessionStorage["l3rseq_genes_hash_<name>"]` to build Gene Counts nav links with the hash. Each page has an inline `<script>` that sets links immediately, before async init.

**When changing one page, test all three.** A genes.html change can break the alignment viewer (nav links) or UMI page (shared state keys).

## Build the Docker image from source

For developers who want to modify the pipeline or Dockerfile. If you use VS Code, clone the repo and select **Reopen in Container** > **L3Rseq Pipeline (build)** — this builds the image and drops you into a ready-to-edit environment. Otherwise, build manually:

```bash
git clone https://github.com/akihitomamiya-del/L3R-seq.git
cd L3R-seq
docker build -f .devcontainer/build/Dockerfile -t l3rseq .
```

On Apple Silicon Macs, this builds a native arm64 image. Docker Desktop for Mac uses a Linux VM, so expect slower I/O on bind-mounted volumes compared to native Linux. Use VirtioFS (the default file sharing backend in Docker Desktop settings) for best performance.

## Docker image publishing

The base image is `ghcr.io/akihitomamiya-del/l3rseq`. CI publishes it when a version tag is pushed:

```bash
git tag v1.0.XX
git push origin v1.0.XX   # triggers .github/workflows/docker-publish.yml
```

The workflow builds for both amd64 and arm64, then creates a multi-arch manifest tagged as both `:v1.0.XX` and `:latest`.

## Claude Code (AI-assisted development)

For running and customizing the pipeline with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Claude can execute the pipeline for you, explain results, and help you adapt the code to your own gene and organism — useful if you're less comfortable with shell scripting. If you want to modify the pipeline itself, fork the repo first so Claude can commit and push changes to your copy. This devcontainer extends the pre-built L3Rseq image with the Claude CLI, a network firewall (for safe `--dangerously-skip-permissions` use), and developer tooling (zsh, git-delta, fzf).

1. Fork this repo (if you plan to make changes), then clone your fork
2. Set your API key as an environment variable on your host: `export ANTHROPIC_API_KEY=sk-ant-...`
3. Open the repo in VS Code
4. Select **Reopen in Container** > **Claude Code Sandbox**
5. Run `claude` in the terminal to start an AI-assisted session

The firewall restricts outbound network access to GitHub, Anthropic API, npm, and VS Code services only. The devcontainer setup is based on Anthropic's [Claude Code DevContainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

---

[README](../README.md) | [Advanced](advanced.md) | [Testing](testing.md) | **Development** | [Requirements](requirements.md)
