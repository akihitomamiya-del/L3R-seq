[README](../README.md) | [Advanced](advanced.md) | [Requirements](requirements.md) | [Code Overview](code-overview.md) | **Development**

---

# Development

## Viewer development

The IGV viewer is a multi-page web app (`/` alignment, `/umi` UMI analysis, `/genes` gene counts).

**File structure:**

| Directory | Contents |
|---|---|
| `igv_viewer/server.js` | Thin HTTP adapter (~350 lines): routing, file serving, gzip, byte-range |
| `igv_viewer/lib/` | Server domain logic: `helpers.js`, `bam.js`, `discovery.js`, `pipeline-stats.js`, `fasta.js` |
| `igv_viewer/js/` | Client JS: `alignment.js`, `umi.js`, `genes.js`, `shared.js`, `dev-overlay.js` |
| `igv_viewer/css/` | `shared.css` — common styles |
| `igv_viewer/*.html` | Slim HTML shells (~50-230 lines) — structure only, no inline JS |

**Server lib modules** (`lib/`): domain logic is split by concern so it can be tested and reused independently. Modules that need environment config (`WORKSPACE`, `DATA_DIR`) expose an `init(config)` function called at startup. `pileup.js` uses dependency injection (receives a `deps` object).

**Client JS**: each page has its own JS file. `shared.js` provides common utilities (`buildSampleSelector`, `syncNavLinks`, `initDatasetPage`, etc.). Pages that share the dataset-selection pattern (UMI, Genes) call `initDatasetPage(opts)` from shared.js with page-specific callbacks, rather than duplicating the init boilerplate.

Follow this cycle for every change:

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

### Common pitfalls

- **Stale browser cache** — always restart viewer after edits. Server sets `no-cache` on HTML/JS/CSS.
- **Cross-page state** — pages share dataset via `?name=`. Genes page stores view state in URL hash (`#v=table&sel=GENE`). Always test all three pages after changing shared code.
- **VS Code Simple Browser** — `target="_blank"` and clipboard API don't work. Gene clicks update the header link instead; dev overlay uses `execCommand("copy")`.
- **IGV.js** — uses Shadow DOM (external CSS can't reach it). Empty BAMs filtered via BAI content check. `loadDefaultGenomes: false` prevents blocked fetches to igv.org.

### Dev overlay

Click the grey **DEV** button (bottom-right) to inspect element names and CSS selectors. Right-click copies the label.

## Claude Code (AI-assisted development)

For running and customizing the pipeline with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Claude can execute the pipeline for you, explain results, and help you adapt the code to your own gene and organism — useful if you're less comfortable with shell scripting. If you want to modify the pipeline itself, fork the repo first so Claude can commit and push changes to your copy. This devcontainer extends the pre-built L3Rseq image with the Claude CLI, a network firewall (for safe `--dangerously-skip-permissions` use), and developer tooling (zsh, git-delta, fzf).

1. Fork this repo (if you plan to make changes), then clone your fork
2. Set your API key as an environment variable on your host: `export ANTHROPIC_API_KEY=sk-ant-...`
3. Open the repo in VS Code
4. Select **Reopen in Container** > **Claude Code Sandbox**
5. Run `claude` in the terminal to start an AI-assisted session

The firewall restricts outbound network access to GitHub, Anthropic API, npm, and VS Code services only. The devcontainer setup is based on Anthropic's [Claude Code DevContainer reference](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

---

[README](../README.md) | [Advanced](advanced.md) | [Requirements](requirements.md) | [Code Overview](code-overview.md) | **Development**
