# Viewer Verification Checklist

Last verified: 2026-04-05 (commit `5716b20`)

## Infrastructure

| Check | Status | Notes |
|-------|--------|-------|
| All 3 pages serve (200) | PASS | `/`, `/umi`, `/genes` |
| All pages load `shared.css` | PASS | Single CSS source of truth |
| All pages load `shared.js` | PASS | Shared sample selector, nav sync, chart cleanup |
| JS/CSS served with `no-cache` | PASS | Edits take effect on reload, no viewer restart needed |
| IGV.js library bundles cached (1 day) | PASS | `/igv/`, `/chartjs/` routes |
| Dev overlay loads on all pages | PASS | `dev-overlay.js` included everywhere |

## APIs

| Endpoint | Status | Notes |
|----------|--------|-------|
| `GET /api/datasets` | PASS | Returns 6 datasets with descriptions |
| `GET /api/tracks?name=...` | PASS | All 6 datasets return valid track arrays |
| `GET /api/umi-stats?name=...` | PASS | pipeline: 4 samples; others: 0 (expected) |
| `GET /api/gene-counts?name=...` | PASS | pipeline: 1 gene; pipeline_splice: 3 genes with splice patterns |
| `GET /api/gene-coverage?name=...` | PASS | Returns 1300 positions/depths for test_gene |
| `GET /api/pileup?name=...` | PASS | Returns text pileup with EC/CIGAR summaries |
| Byte-range BAM requests | PASS | 206 Partial Content with correct Content-Range |
| 20 concurrent `/api/datasets` | PASS | All return 200 |

## Error handling

| Input | Status | Response |
|-------|--------|----------|
| Nonexistent dataset name | PASS | 404 |
| Empty `name=` parameter | PASS | 400 |
| Missing `name` parameter | PASS | 400 |
| Path traversal in dataset name (`../../../etc/passwd`) | PASS | 404 (not served) |
| Path traversal in gene param | NOTED | Returns empty data (200). Not a file leak but should validate input. |

## Cross-page navigation

| Flow | Status | Notes |
|------|--------|-------|
| Genes → Alignment Viewer (with dataset) | PASS | `?name=` preserved via `syncNavLinksFromUrl()` |
| Genes → Alignment Viewer (with locus) | PASS | Locus badge shows gene name + coordinates |
| UMI → Gene Counts (with dataset) | PASS | `?name=` preserved, genes hash synced |
| Alignment → UMI → Genes round-trip | PASS | Dataset selection preserved throughout |
| Gene selection → clear (click badge) | PASS | Badge hides, viewer link resets, gene filter clears |

## Header and layout

| Check | Status | Notes |
|-------|--------|-------|
| Header links clickable (full area) | PASS | 8px padding + hover highlight |
| Header stays above scrolled content | PASS | `header ~ * { z-index: 0 }` rule |
| Controls bar below header (alignment page) | PASS | `top: 48px` default, `updateStickyTops()` adjusts |
| Locus badge doesn't overlap viewer link | PASS | Removed `margin-left: -8px` |

## Data availability per dataset

| Dataset | Tracks | UMI samples | Gene counts | Notes |
|---------|--------|-------------|-------------|-------|
| pipeline | 4 | 4 | 1 gene | Full pipeline, symlinked `04_umi` + `11_count` |
| pipeline_dual | 4 | 0 | 0 | CT+AG pattern, `09_correct` only |
| pipeline_splice | 2 | 0 | 3 genes | Splice-aware: exon1(27) > intron(10) |
| pipeline_SLAM | 2 | 0 | 0 | SLAM-seq, steps 07-10 only |
| pipeline_blast | 3 | 0 | 0 | BLAST + walk correction, steps 07-10 |
| demo | 4 | 0 | 0 | Demo walkthrough dataset |

## Code consistency

| Check | Status | Notes |
|-------|--------|-------|
| No function shadowing between pages and shared.js | PASS | `showEmpty`, `destroyCharts`, `clearPage`, `buildSampleSelector` only in shared.js |
| Script load order correct | PASS | shared.js before page scripts on all pages |
| Early inline nav sync (index.html) uses no shared.js functions | PASS | Vanilla JS only, runs before shared.js loads |
| No broken script/CSS references | PASS | All `src=` and `href=` resolve to 200 |
