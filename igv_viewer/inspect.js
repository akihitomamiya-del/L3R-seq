#!/usr/bin/env node
/**
 * Headless IGV viewer inspector using Puppeteer + DOM queries.
 * Loads a dataset and returns a detailed text report of the viewer state,
 * track properties, and alignment data — no screenshot needed.
 *
 * Usage:
 *   node igv_viewer/inspect.js <dataset> [region]
 *
 * Examples:
 *   node igv_viewer/inspect.js tests/output/pipeline_SLAM
 *   node igv_viewer/inspect.js tests/output/pipeline_splice test_gene_with_intron:200-600
 *
 * Requires: IGV viewer server running, Puppeteer + Chrome deps installed.
 */

const puppeteer = require("puppeteer");

const PORT = process.env.IGV_PORT || 8080;
const BASE_URL = `http://localhost:${PORT}`;

async function main() {
  const dataset = process.argv[2];
  const region = process.argv[3] || "";

  if (!dataset) {
    console.error("Usage: node inspect.js <dataset> [region]");
    process.exit(1);
  }

  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-gpu"],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });

    await page.goto(BASE_URL, { waitUntil: "networkidle0", timeout: 15000 });
    await page.select("#dataset", dataset);
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: 15000 }
    );
    await new Promise(r => setTimeout(r, 2000));

    // Navigate to region if specified
    if (region) {
      await page.evaluate(locus => window.browser?.search(locus), region);
      await new Promise(r => setTimeout(r, 2000));
    }

    // Extract comprehensive DOM state
    const report = await page.evaluate(() => {
      const b = window.browser;
      if (!b) return { error: "IGV browser not loaded" };

      const result = {
        // Page-level UI
        ui: {
          dataset: document.getElementById("dataset")?.value,
          reference: document.getElementById("ref-select")?.options[
            document.getElementById("ref-select")?.selectedIndex
          ]?.textContent,
          status: document.getElementById("status")?.textContent,
          showAllReads: document.getElementById("show-all")?.checked,
          controlsPanelOpen: document.getElementById("controls-panel")?.classList.contains("open"),
          displayMode: document.getElementById("btn-squished")?.classList.contains("active")
            ? "SQUISHED" : "EXPANDED",
        },
        // IGV.js browser state
        igv: {
          locus: b.referenceFrameList?.[0]?.getLocusString?.() || null,
          referenceId: b.genome?.id || null,
          referenceLength: b.genome?.getChromosome?.(b.genome?.chromosomeNames?.[0])?.bpLength || null,
          trackCount: b.trackViews?.length || 0,
        },
        // Per-track details
        tracks: [],
      };

      for (const tv of (b.trackViews || [])) {
        const t = tv.track;
        if (!t) continue;
        const at = t.alignmentTrack;
        const info = {
          name: t.name || t.config?.name || "unnamed",
          type: t.type || "unknown",
          height: tv.trackDiv?.offsetHeight || 0,
          visible: tv.trackDiv?.style.display !== "none",
        };

        if (at) {
          info.displayMode = at.displayMode;
          info.showSoftClips = at.showSoftClips;
          info.showMismatches = at.showMismatches;
          info.showInsertions = at.showInsertions;
          info.color = t.config?.color || at.color || null;

          // Count visible reads from the alignment container
          const featureSource = t.featureSource;
          if (featureSource?.alignmentContainer) {
            const container = featureSource.alignmentContainer;
            let readCount = 0;
            if (container.packedAlignmentRows) {
              for (const row of container.packedAlignmentRows) {
                readCount += row.alignments?.length || 0;
              }
            }
            info.visibleReads = readCount;
          }
        }

        result.tracks.push(info);
      }

      return result;
    });

    // Format output
    console.log("IGV Viewer Inspection Report");
    console.log("============================");
    console.log("");
    console.log("UI State:");
    console.log(`  Dataset:        ${report.ui.dataset}`);
    console.log(`  Reference:      ${report.ui.reference}`);
    console.log(`  Status:         ${report.ui.status}`);
    console.log(`  Display mode:   ${report.ui.displayMode}`);
    console.log(`  Show all reads: ${report.ui.showAllReads}`);
    console.log(`  Controls open:  ${report.ui.controlsPanelOpen}`);
    console.log("");
    console.log("IGV Browser:");
    console.log(`  Locus:          ${report.igv.locus}`);
    console.log(`  Reference:      ${report.igv.referenceId} (${report.igv.referenceLength}bp)`);
    console.log(`  Total tracks:   ${report.igv.trackCount}`);
    console.log("");
    console.log("Tracks:");
    for (const t of report.tracks) {
      console.log(`  ${t.name}`);
      console.log(`    type=${t.type} height=${t.height}px visible=${t.visible}`);
      if (t.displayMode !== undefined) {
        console.log(`    mode=${t.displayMode} softClips=${t.showSoftClips} mismatches=${t.showMismatches}`);
        console.log(`    color=${t.color} visibleReads=${t.visibleReads ?? "n/a"}`);
      }
    }

  } finally {
    await browser.close();
  }
}

main().catch(e => {
  console.error("Error:", e.message);
  process.exit(1);
});
