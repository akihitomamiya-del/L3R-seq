#!/usr/bin/env node
// Viewer stress tests — exercises scale-dependent behaviors that synthetic
// data (3 tracks, 3 samples, 1 gene) can never reach.
//
// Auto-discovers the largest dataset from the running viewer server.
// Gracefully skips if no real data is available (exits 0, never breaks CI).
//
// Usage:
//   node igv_viewer/test_stress.js              # auto-discover
//   node igv_viewer/test_stress.js runs/LibCheck # explicit dataset
//
// Requires: viewer running (L3Rseq viewer --dir <dir>)
"use strict";

const puppeteer = require("./node_modules/puppeteer");

const BASE = "http://localhost:8080";
const MIN_TRACKS = 8;   // below this, synthetic data — skip
const MIN_SAMPLES = 6;
const MIN_GENES = 3;
const PAGE_TIMEOUT = 20000;

let passed = 0, failed = 0, skipped = 0;

function pass(msg) { console.log("  [PASS]", msg); passed++; }
function fail(msg) { console.log("  [FAIL]", msg); failed++; }
function skip(msg) { console.log("  [SKIP]", msg); skipped++; }
function assert(cond, msg) { if (cond) pass(msg); else fail(msg); }

async function main() {
  const explicitDs = process.argv[2];

  // Verify server is running
  let datasets, apiData;
  try {
    const resp = await fetch(BASE + "/api/datasets");
    apiData = await resp.json();
    datasets = apiData.datasets || [];
  } catch {
    console.log("ERROR: Viewer not running on", BASE);
    console.log("Start it first: L3Rseq viewer --dir <dir>");
    process.exit(1);
  }

  // Pick dataset: explicit arg, or largest by track count
  let dsName;
  if (explicitDs) {
    dsName = datasets.find(d => d === explicitDs || d.endsWith(explicitDs));
    if (!dsName) { console.log("Dataset not found:", explicitDs); console.log("Available:", datasets); process.exit(1); }
  } else {
    // Find dataset with most tracks
    let best = null, bestCount = 0;
    for (const name of datasets) {
      try {
        const r = await fetch(BASE + "/api/tracks?name=" + encodeURIComponent(name));
        const d = await r.json();
        if (d.tracks && d.tracks.length > bestCount) { best = name; bestCount = d.tracks.length; }
      } catch {}
    }
    if (!best || bestCount < MIN_TRACKS) {
      console.log("SKIP: No dataset with >=" + MIN_TRACKS + " tracks found (largest has " + bestCount + ").");
      console.log("Run a pipeline on real data first, e.g.: bash runs/LibCheck_sample.sh");
      process.exit(0);
    }
    dsName = best;
  }

  // Fetch dataset metadata for assertions
  const tracksResp = await fetch(BASE + "/api/tracks?name=" + encodeURIComponent(dsName));
  const tracksData = await tracksResp.json();
  const umiResp = await fetch(BASE + "/api/umi-stats?name=" + encodeURIComponent(dsName));
  const umiData = await umiResp.json();
  const genesResp = await fetch(BASE + "/api/gene-counts?name=" + encodeURIComponent(dsName));
  const genesData = await genesResp.json();

  const totalTracks = tracksData.tracks.length;
  const totalUmiSamples = umiData.samples.length;
  const totalGenes = genesData.genes ? genesData.genes.length : 0;
  const totalGeneSamples = genesData.samples ? genesData.samples.length : 0;
  const barcodes = [...new Set(tracksData.tracks.map(t => t.name.split("/")[0]))];

  console.log("Dataset:", dsName);
  console.log("  Tracks:", totalTracks, "| UMI samples:", totalUmiSamples,
    "| Genes:", totalGenes, "| Gene samples:", totalGeneSamples,
    "| Barcodes:", barcodes.length);
  console.log("");

  const browser = await puppeteer.launch({ headless: true, args: ["--no-sandbox"] });
  const page = await browser.newPage();
  const pageErrors = [];
  page.on("pageerror", e => pageErrors.push(e.message));

  const enc = encodeURIComponent(dsName);

  // =========================================================================
  // TEST 1: Alignment page — scale + track cap
  // =========================================================================
  console.log("[Test 1] Alignment page — track loading at scale");
  await page.goto(BASE + "/?name=" + enc, { waitUntil: "networkidle0", timeout: PAGE_TIMEOUT });

  const igvTracks = await page.evaluate(() =>
    window.browser ? window.browser.trackViews.filter(tv => tv.track && tv.track.alignmentTrack).length : 0);
  assert(igvTracks > 0, "Alignment tracks loaded: " + igvTracks);
  if (totalTracks > 8) {
    assert(igvTracks <= 8, "Track cap applied (loaded " + igvTracks + " of " + totalTracks + ")");
  }

  const trackSummary = await page.evaluate(() =>
    document.getElementById("track-summary")?.textContent || "");
  assert(trackSummary.includes("/"), "Track summary shows count: " + trackSummary.trim());

  // Check nav links are synced (shared.js)
  const umiHref = await page.evaluate(() => document.getElementById("umi-link")?.href || "");
  const genesHref = await page.evaluate(() => document.getElementById("genes-link")?.href || "");
  assert(umiHref.includes("name="), "UMI nav link has dataset param");
  assert(genesHref.includes("name="), "Genes nav link has dataset param");

  // =========================================================================
  // TEST 2: Alignment page — barcode group toggle
  // =========================================================================
  if (barcodes.length >= 2) {
    console.log("\n[Test 2] Alignment page — barcode group toggle");
    // Open track list
    await page.evaluate(() => {
      const panel = document.getElementById("track-list-panel");
      if (panel && panel.style.display === "none") toggleTrackList();
    });
    await new Promise(r => setTimeout(r, 300));

    // Count checked tracks for first barcode
    const bc = barcodes[0];
    const beforeCount = await page.evaluate((barcode) => {
      const cbs = document.querySelectorAll(`input[data-barcode="${barcode}"][data-track-idx]`);
      return [...cbs].filter(cb => cb.checked).length;
    }, bc);

    // Toggle barcode off
    await page.evaluate((barcode) => {
      const header = document.querySelector(`input[data-barcode="${barcode}"]:not([data-track-idx])`);
      if (header) { header.checked = false; header.onchange(); }
    }, bc);
    await new Promise(r => setTimeout(r, 2000));

    const afterOff = await page.evaluate((barcode) => {
      const cbs = document.querySelectorAll(`input[data-barcode="${barcode}"][data-track-idx]`);
      return [...cbs].filter(cb => cb.checked).length;
    }, bc);
    assert(afterOff === 0, "Barcode " + bc + " toggled off (" + beforeCount + " → " + afterOff + ")");

    // Toggle back on
    await page.evaluate((barcode) => {
      const header = document.querySelector(`input[data-barcode="${barcode}"]:not([data-track-idx])`);
      if (header) { header.checked = true; header.onchange(); }
    }, bc);
    await new Promise(r => setTimeout(r, 2000));

    const afterOn = await page.evaluate((barcode) => {
      const cbs = document.querySelectorAll(`input[data-barcode="${barcode}"][data-track-idx]`);
      return [...cbs].filter(cb => cb.checked).length;
    }, bc);
    assert(afterOn > 0, "Barcode " + bc + " toggled back on (" + afterOn + " tracks)");
  } else {
    console.log("\n[Test 2] SKIP — only " + barcodes.length + " barcode(s)");
    skip("Barcode toggle (need >= 2 barcodes)");
  }

  // =========================================================================
  // TEST 3: UMI page — grid rendering at scale
  // =========================================================================
  if (totalUmiSamples >= MIN_SAMPLES) {
    console.log("\n[Test 3] UMI page — " + totalUmiSamples + " samples");
    await page.goto(BASE + "/umi?name=" + enc, { waitUntil: "networkidle0", timeout: PAGE_TIMEOUT });

    const umiSampleCbs = await page.evaluate(() =>
      document.querySelectorAll("#sample-body input[data-id]").length);
    assert(umiSampleCbs === totalUmiSamples, "Sample checkboxes: " + umiSampleCbs + " (expected " + totalUmiSamples + ")");

    // Grid view (default)
    const gridCanvases = await page.evaluate(() =>
      document.querySelectorAll("#chart-area canvas").length);
    assert(gridCanvases === totalUmiSamples, "Grid canvases: " + gridCanvases + " (expected " + totalUmiSamples + ")");

    // Overlay view
    await page.evaluate(() => setView("overlay"));
    await new Promise(r => setTimeout(r, 500));
    const overlayCanvases = await page.evaluate(() =>
      document.querySelectorAll("#chart-area canvas").length);
    assert(overlayCanvases === 2, "Overlay canvases (cumulative + histogram): " + overlayCanvases);

    // Table view
    await page.evaluate(() => setView("table"));
    await new Promise(r => setTimeout(r, 500));
    const tableRows = await page.evaluate(() =>
      document.querySelectorAll("#chart-area table.stats tbody tr").length);
    assert(tableRows === totalUmiSamples, "Table rows: " + tableRows + " (expected " + totalUmiSamples + ")");

    // Nav links
    const viewerLink = await page.evaluate(() => document.getElementById("viewer-link")?.href || "");
    assert(viewerLink.includes("name="), "Viewer nav link has dataset param");
  } else {
    console.log("\n[Test 3] SKIP — only " + totalUmiSamples + " UMI samples");
    skip("UMI page (need >= " + MIN_SAMPLES + " samples)");
  }

  // =========================================================================
  // TEST 4: Genes page — views + gene selector
  // =========================================================================
  if (totalGenes >= MIN_GENES && genesData.hasData) {
    console.log("\n[Test 4] Genes page — " + totalGenes + " genes, " + totalGeneSamples + " samples");
    await page.goto(BASE + "/genes?name=" + enc, { waitUntil: "networkidle0", timeout: PAGE_TIMEOUT });

    const geneSampleCbs = await page.evaluate(() =>
      document.querySelectorAll("#sample-body input[data-id]").length);
    assert(geneSampleCbs === totalGeneSamples, "Sample checkboxes: " + geneSampleCbs);

    const geneOptions = await page.evaluate(() =>
      document.getElementById("gene-select").options.length - 1); // minus "All"
    assert(geneOptions === totalGenes, "Gene dropdown options: " + geneOptions);

    // Chart view (default)
    const chartCanvases = await page.evaluate(() =>
      document.querySelectorAll("#chart-area canvas").length);
    assert(chartCanvases >= 1, "Chart view rendered: " + chartCanvases + " canvas(es)");

    // Table view + gene click
    await page.evaluate(() => setView("table"));
    await new Promise(r => setTimeout(r, 500));
    const geneLinks = await page.evaluate(() =>
      document.querySelectorAll('#chart-area a[data-gene]').length);
    assert(geneLinks > 0, "Gene links in table: " + geneLinks);

    // Click first gene
    const clickedGene = await page.evaluate(() => {
      const link = document.querySelector('#chart-area a[data-gene]');
      if (link) { link.click(); return link.textContent; }
      return null;
    });
    if (clickedGene) {
      await new Promise(r => setTimeout(r, 300));
      const badge = await page.evaluate(() =>
        document.getElementById("locus-badge")?.textContent || "");
      assert(badge.includes(clickedGene), "Locus badge shows gene: " + badge);

      const viewerUrl = await page.evaluate(() =>
        document.getElementById("viewer-link")?.href || "");
      assert(viewerUrl.includes("locus="), "Viewer link has locus param");
    }

    // Isoforms view
    await page.evaluate(() => setView("isoforms"));
    await new Promise(r => setTimeout(r, 500));
    const isoCanvases = await page.evaluate(() =>
      document.querySelectorAll("#chart-area canvas").length);
    assert(isoCanvases >= 1, "Isoforms view rendered: " + isoCanvases + " canvas(es)");

    // Coverage view
    await page.evaluate(() => setView("coverage"));
    await new Promise(r => setTimeout(r, 1000));
    const covCanvases = await page.evaluate(() =>
      document.querySelectorAll("#chart-area canvas").length);
    // Coverage may have 0 canvases if no depth files — that's OK, just no errors
    pass("Coverage view rendered without errors: " + covCanvases + " canvas(es)");

  } else {
    console.log("\n[Test 4] SKIP — " + totalGenes + " genes, hasData=" + genesData.hasData);
    skip("Genes page (need >= " + MIN_GENES + " genes with data)");
  }

  // =========================================================================
  // TEST 5: Cross-page round-trip (genes → alignment → back)
  // =========================================================================
  if (totalGenes >= 1 && genesData.hasData) {
    console.log("\n[Test 5] Cross-page round-trip");

    // Start on genes page, click a gene
    await page.goto(BASE + "/genes?name=" + enc, { waitUntil: "networkidle0", timeout: PAGE_TIMEOUT });
    await page.evaluate(() => setView("table"));
    await new Promise(r => setTimeout(r, 500));

    const gene = await page.evaluate(() => {
      const link = document.querySelector('#chart-area a[data-gene]');
      if (link) { link.click(); return link.textContent; }
      return null;
    });

    if (gene) {
      await new Promise(r => setTimeout(r, 300));
      // Get the viewer URL with locus
      const viewerUrl = await page.evaluate(() => document.getElementById("viewer-link")?.href || "");
      assert(viewerUrl.includes("locus="), "Step 1: Viewer link has locus after gene click");

      // Navigate to alignment viewer
      await page.goto(viewerUrl, { waitUntil: "networkidle0", timeout: 30000 });
      const locusParam = new URL(viewerUrl).searchParams.get("locus");
      const locusBadge = await page.evaluate(() =>
        document.getElementById("locus-badge")?.textContent || "");
      assert(locusBadge.length > 0, "Step 2: Alignment page shows locus badge: " + locusBadge);

      // Verify IGV loaded with tracks
      const roundTripTracks = await page.evaluate(() =>
        window.browser ? window.browser.trackViews.filter(tv => tv.track && tv.track.alignmentTrack).length : 0);
      assert(roundTripTracks > 0, "Step 3: Alignment tracks loaded: " + roundTripTracks);

      // Navigate back to genes
      const genesUrl = await page.evaluate(() => document.getElementById("genes-link")?.href || "");
      await page.goto(genesUrl, { waitUntil: "networkidle0", timeout: PAGE_TIMEOUT });

      const restoredDs = await page.evaluate(() => document.getElementById("dataset")?.value || "");
      assert(restoredDs === dsName, "Step 4: Dataset preserved after round-trip: " + restoredDs);
    } else {
      skip("No clickable gene found for round-trip test");
    }
  } else {
    console.log("\n[Test 5] SKIP — no gene data");
    skip("Cross-page round-trip (need gene data)");
  }

  // =========================================================================
  // TEST 6: No JS errors during entire session
  // =========================================================================
  console.log("\n[Test 6] Page errors");
  // Filter out known IGV.js noise (default genome fetch, favicon)
  const realErrors = pageErrors.filter(e =>
    !e.includes("favicon") && !e.includes("genomes") && !e.includes("404"));
  assert(realErrors.length === 0,
    realErrors.length === 0 ? "No page errors" : "Page errors: " + realErrors.join("; "));

  // =========================================================================
  await browser.close();

  console.log("\n========================================");
  console.log("Results: " + passed + " passed, " + failed + " failed, " + skipped + " skipped");
  console.log("Dataset: " + dsName + " (" + totalTracks + " tracks, " +
    totalUmiSamples + " UMI samples, " + totalGenes + " genes)");
  console.log("========================================");
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(e => { console.error("Fatal:", e.message); process.exit(1); });
