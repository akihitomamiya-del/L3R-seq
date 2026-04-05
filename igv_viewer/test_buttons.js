#!/usr/bin/env node
/**
 * Automated IGV viewer test using Puppeteer + DOM assertions.
 * Verifies that buttons, dataset switching, and track rendering work
 * by inspecting the actual DOM state — no screenshot comparison needed.
 *
 * Usage:
 *   node igv_viewer/test_buttons.js [dataset]
 *
 * Requires: IGV viewer server running, Puppeteer + Chrome deps installed.
 */

const puppeteer = require("puppeteer");

const PORT = process.env.IGV_PORT || 8080;
const BASE_URL = `http://localhost:${PORT}`;
const TIMEOUT = Number(process.env.PUPPETEER_TIMEOUT) || 15000;

let pass = 0, fail = 0;

function check(label, got, expected) {
  if (got === expected) {
    console.log(`  [PASS] ${label}: ${got}`);
    pass++;
  } else {
    console.log(`  [FAIL] ${label}: got ${JSON.stringify(got)}, expected ${JSON.stringify(expected)}`);
    fail++;
  }
}

function checkTrue(label, value) {
  if (value) {
    console.log(`  [PASS] ${label}`);
    pass++;
  } else {
    console.log(`  [FAIL] ${label}`);
    fail++;
  }
}

// Read IGV.js internal state from the browser
async function getIGVState(page) {
  return page.evaluate(() => {
    if (!window.browser) return null;
    const trackViews = window.browser.trackViews || [];
    const alignmentTracks = [];
    for (const tv of trackViews) {
      const at = tv.track?.alignmentTrack;
      if (!at) continue;
      alignmentTracks.push({
        name: tv.track.name || tv.track.config?.name || "unnamed",
        displayMode: at.displayMode,
        showSoftClips: at.showSoftClips,
        showMismatches: at.showMismatches,
        height: tv.trackDiv?.offsetHeight || 0,
        colorBy: at.colorBy || null,
        sortObject: tv.track.sortObject || null,
      });
    }
    const locus = window.browser.referenceFrameList?.[0]?.getLocusString?.() || null;
    return {
      trackCount: trackViews.length,
      alignmentTracks,
      locus,
      referenceId: window.browser.genome?.id || null,
    };
  });
}

// Read UI element states
async function getUIState(page) {
  return page.evaluate(() => {
    const ds = document.getElementById("dataset");
    const ref = document.getElementById("ref-select");
    const status = document.getElementById("status");
    const showAll = document.getElementById("show-all");
    const panel = document.getElementById("controls-panel");
    const btnSquished = document.getElementById("btn-squished");
    const btnExpanded = document.getElementById("btn-expanded");
    const sortBy = document.getElementById("sort-by");
    const colorBy = document.getElementById("color-by");
    const btnSortAsc = document.getElementById("btn-sort-asc");
    const btnSortDesc = document.getElementById("btn-sort-desc");
    const legend = document.getElementById("color-legend");
    return {
      dataset: ds?.value || "",
      datasetOptions: Array.from(ds?.options || []).map(o => o.value).filter(v => v),
      reference: ref?.options[ref.selectedIndex]?.textContent || "",
      status: status?.textContent || "",
      showAllChecked: showAll?.checked || false,
      controlsPanelOpen: panel?.classList.contains("open") || false,
      squishedActive: btnSquished?.classList.contains("active") || false,
      expandedActive: btnExpanded?.classList.contains("active") || false,
      sortByValue: sortBy?.value || "",
      sortByOptions: Array.from(sortBy?.options || []).map(o => o.value),
      colorByValue: colorBy?.value || "",
      sortAscActive: btnSortAsc?.classList.contains("active") || false,
      sortDescActive: btnSortDesc?.classList.contains("active") || false,
      colorLegendVisible: (legend?.innerHTML || "").length > 0,
    };
  });
}

async function main() {
  const targetDataset = process.argv[2] || "";

  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-gpu"],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });

    // ── Load viewer ──
    console.log("Loading viewer...");
    await page.goto(BASE_URL, { waitUntil: "networkidle0", timeout: TIMEOUT });

    // ── Test 1: Initial page load ──
    console.log("\n[Test 1] Initial page load");
    let ui = await getUIState(page);
    checkTrue("Dataset dropdown populated", ui.datasetOptions.length > 0);
    checkTrue("Reference dropdown populated", ui.reference !== "");
    check("No dataset selected initially", ui.dataset, "");
    console.log(`  Datasets available: ${ui.datasetOptions.join(", ")}`);

    // ── Test 2: Load a dataset ──
    const dataset = targetDataset || ui.datasetOptions[0];
    console.log(`\n[Test 2] Load dataset: ${dataset}`);
    await page.select("#dataset", dataset);
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: TIMEOUT }
    );
    await new Promise(r => setTimeout(r, 1500));

    ui = await getUIState(page);
    check("Dataset selected", ui.dataset, dataset);
    checkTrue("Status shows Ready", ui.status.includes("Ready"));

    let igv = await getIGVState(page);
    checkTrue("IGV browser created", igv !== null);
    checkTrue("Tracks loaded", igv.trackCount > 0);
    checkTrue("Alignment tracks found", igv.alignmentTracks.length > 0);
    console.log(`  Tracks: ${igv.trackCount}, alignment tracks: ${igv.alignmentTracks.length}`);
    console.log(`  Reference: ${igv.referenceId}, locus: ${igv.locus}`);
    for (const t of igv.alignmentTracks) {
      console.log(`    ${t.name}: mode=${t.displayMode} softClips=${t.showSoftClips} h=${t.height}px`);
    }

    // ── Test 3: Controls panel toggle ──
    console.log("\n[Test 3] Controls panel toggle");
    check("Panel initially closed", ui.controlsPanelOpen, false);

    await page.evaluate(() => toggleControlsPanel());
    await new Promise(r => setTimeout(r, 300));
    ui = await getUIState(page);
    check("Panel opened", ui.controlsPanelOpen, true);

    await page.evaluate(() => toggleControlsPanel());
    await new Promise(r => setTimeout(r, 300));
    ui = await getUIState(page);
    check("Panel closed again", ui.controlsPanelOpen, false);

    // Open panel for the button tests that follow
    await page.evaluate(() => toggleControlsPanel());
    await new Promise(r => setTimeout(r, 300));

    // ── Test 4: Display mode SQUISHED → EXPANDED ──
    console.log("\n[Test 4] Display mode: SQUISHED → EXPANDED");
    check("Initially SQUISHED", igv.alignmentTracks[0].displayMode, "SQUISHED");
    check("Squished button active", ui.squishedActive, true);
    check("Expanded button inactive", ui.expandedActive, false);

    await page.click("#btn-expanded");
    await new Promise(r => setTimeout(r, 500));

    igv = await getIGVState(page);
    ui = await getUIState(page);
    check("Mode changed to EXPANDED", igv.alignmentTracks[0].displayMode, "EXPANDED");
    check("Expanded button now active", ui.expandedActive, true);
    check("Squished button now inactive", ui.squishedActive, false);

    // ── Test 5: Display mode EXPANDED → SQUISHED ──
    console.log("\n[Test 5] Display mode: EXPANDED → SQUISHED");
    await page.click("#btn-squished");
    await new Promise(r => setTimeout(r, 500));

    igv = await getIGVState(page);
    ui = await getUIState(page);
    check("Mode back to SQUISHED", igv.alignmentTracks[0].displayMode, "SQUISHED");
    check("Squished button active again", ui.squishedActive, true);

    // ── Test 6: Show all reads toggle ──
    console.log("\n[Test 6] Show all reads toggle");
    check("Show-all initially unchecked", ui.showAllChecked, false);

    await page.click("#show-all");
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: TIMEOUT }
    );
    await new Promise(r => setTimeout(r, 1500));

    ui = await getUIState(page);
    igv = await getIGVState(page);
    check("Show-all now checked", ui.showAllChecked, true);
    checkTrue("Tracks still loaded after toggle", igv.trackCount > 0);

    // Toggle back
    await page.click("#show-all");
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: TIMEOUT }
    );
    await new Promise(r => setTimeout(r, 1500));

    // ── Test 7: Sort controls ──
    console.log("\n[Test 7] Sort controls");
    // Re-open controls panel if needed
    ui = await getUIState(page);
    if (!ui.controlsPanelOpen) {
      await page.evaluate(() => toggleControlsPanel());
      await new Promise(r => setTimeout(r, 300));
    }

    check("Sort default is None", ui.sortByValue, "none");
    check("ASC button active by default", ui.sortAscActive, true);
    check("DESC button inactive by default", ui.sortDescActive, false);
    checkTrue("Sort dropdown has SAM tag options", ui.sortByOptions.includes("tag:EC"));
    checkTrue("Sort dropdown has alignment options", ui.sortByOptions.includes("ALIGNED_READ_LENGTH"));

    // Sort by EC tag
    await page.select("#sort-by", "tag:EC");
    await new Promise(r => setTimeout(r, 1500));
    ui = await getUIState(page);
    igv = await getIGVState(page);
    check("Sort set to tag:EC", ui.sortByValue, "tag:EC");
    checkTrue("Status shows sort info", ui.status.includes("Sorted"));
    checkTrue("sortObject set on track", igv.alignmentTracks[0].sortObject !== null);

    // Toggle to DESC
    await page.click("#btn-sort-desc");
    await new Promise(r => setTimeout(r, 1500));
    ui = await getUIState(page);
    check("DESC button now active", ui.sortDescActive, true);
    check("ASC button now inactive", ui.sortAscActive, false);

    // Reset sort to None (triggers dataset reload)
    await page.select("#sort-by", "none");
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: TIMEOUT }
    );
    await new Promise(r => setTimeout(r, 1500));

    // ── Test 8: Color controls ──
    console.log("\n[Test 8] Color controls");
    // Re-open controls panel after reload
    await page.evaluate(() => {
      const p = document.getElementById("controls-panel");
      if (!p.classList.contains("open")) toggleControlsPanel();
    });
    await new Promise(r => setTimeout(r, 300));

    ui = await getUIState(page);
    check("Color default is None", ui.colorByValue, "none");
    check("No color legend initially", ui.colorLegendVisible, false);

    // Color by SJ
    await page.select("#color-by", "tag:SJ");
    await new Promise(r => setTimeout(r, 500));
    ui = await getUIState(page);
    igv = await getIGVState(page);
    check("Color set to tag:SJ", ui.colorByValue, "tag:SJ");
    checkTrue("Color legend visible", ui.colorLegendVisible);
    check("colorBy set on track", igv.alignmentTracks[0].colorBy, "tag:SJ");

    // Reset color
    await page.select("#color-by", "none");
    await new Promise(r => setTimeout(r, 500));
    igv = await getIGVState(page);
    ui = await getUIState(page);
    check("colorBy cleared", igv.alignmentTracks[0].colorBy, "none");
    check("Legend hidden", ui.colorLegendVisible, false);

    // ── Test 9: Dataset switching ──
    if (ui.datasetOptions.length >= 2) {
      const otherDs = ui.datasetOptions.find(d => d !== dataset);
      console.log(`\n[Test 9] Switch dataset: ${dataset} → ${otherDs}`);

      const refBefore = igv.referenceId;
      await page.select("#dataset", otherDs);
      await page.waitForFunction(
        () => document.getElementById("status")?.textContent.includes("Ready"),
        { timeout: TIMEOUT }
      );
      await new Promise(r => setTimeout(r, 1500));

      ui = await getUIState(page);
      igv = await getIGVState(page);
      check("Dataset switched", ui.dataset, otherDs);
      checkTrue("New tracks loaded", igv.trackCount > 0);
      console.log(`  Reference: ${refBefore} → ${igv.referenceId}`);
      console.log(`  Tracks: ${igv.alignmentTracks.map(t => t.name).join(", ")}`);
    }

    // ── Test 10: All datasets load without error ──
    console.log("\n[Test 10] Load all datasets");
    for (const ds of ui.datasetOptions) {
      await page.select("#dataset", ds);
      try {
        await page.waitForFunction(
          () => document.getElementById("status")?.textContent.includes("Ready"),
          { timeout: TIMEOUT }
        );
        await new Promise(r => setTimeout(r, 500));
        const state = await getIGVState(page);
        checkTrue(`${ds}: loaded (${state.alignmentTracks.length} tracks, ref=${state.referenceId})`, state.trackCount > 0);
      } catch {
        checkTrue(`${ds}: loaded`, false);
      }
    }

    // ── Summary ──
    console.log(`\n========================================`);
    console.log(`Results: ${pass} passed, ${fail} failed`);
    console.log(`========================================`);

  } finally {
    await browser.close();
  }

  process.exit(fail > 0 ? 1 : 0);
}

main().catch(e => {
  console.error("Error:", e.message);
  process.exit(1);
});
