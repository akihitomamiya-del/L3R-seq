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

---

[README](../README.md) | [Adaptation](adaptation.md) | [Requirements](requirements.md) | [Code Overview](code-overview.md) | **Development**
