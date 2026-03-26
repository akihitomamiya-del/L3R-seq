#!/usr/bin/env node
/**
 * Headless IGV screenshot tool using Puppeteer.
 * Produces PNG (raster) and/or SVG (vector) output without needing a browser.
 *
 * Usage:
 *   node igv_viewer/screenshot.js <dataset> [options]
 *
 * Options:
 *   --region <ref:start-end>   Navigate to region before capture
 *   --format <svg|png|both>    Output format (default: svg)
 *   --per-track                Also save each track as a separate SVG
 *   --output <filename>        Custom output filename (without extension)
 *
 * Examples:
 *   node igv_viewer/screenshot.js tests/output/pipeline_SLAM
 *   node igv_viewer/screenshot.js tests/output/pipeline_splice --region test_gene_with_intron:200-600
 *   node igv_viewer/screenshot.js tests/output/pipeline_blast --format svg
 *
 * SVG output uses IGV.js built-in browser.toSVG() — true vector, publication quality.
 * PNG output uses Puppeteer page.screenshot() — pixel-perfect browser capture.
 *
 * Requires: IGV viewer server running (L3Rseq viewer), Puppeteer + Chrome deps.
 * Screenshots saved to igv_viewer/screenshots/ by default.
 */

const puppeteer = require("puppeteer");
const path = require("path");
const fs = require("fs");

const PORT = process.env.IGV_PORT || 8080;
const BASE_URL = `http://localhost:${PORT}`;
const SCREENSHOT_DIR = path.join(__dirname, "screenshots");

async function main() {
  // Parse args
  const args = process.argv.slice(2);
  let dataset = "", region = "", format = "svg", outputName = "", perTrack = false;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--region" && args[i + 1]) { region = args[++i]; }
    else if (args[i] === "--format" && args[i + 1]) { format = args[++i]; }
    else if (args[i] === "--output" && args[i + 1]) { outputName = args[++i]; }
    else if (args[i] === "--per-track") { perTrack = true; }
    else if (!args[i].startsWith("--")) { dataset = args[i]; }
  }

  if (!dataset) {
    console.error("Usage: node screenshot.js <dataset> [--region <locus>] [--format png|svg|both] [--output <name>]");
    console.error("");
    try {
      const res = await fetch(`${BASE_URL}/api/datasets`);
      const data = await res.json();
      console.error("Available datasets:");
      for (const ds of data.datasets) console.error(`  ${ds}`);
    } catch {
      console.error("(Could not connect to viewer — is it running?)");
    }
    process.exit(1);
  }

  if (!fs.existsSync(SCREENSHOT_DIR)) fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });

  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-gpu"],
  });

  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 1400, height: 900 });

    console.log(`Loading viewer at ${BASE_URL}...`);
    await page.goto(BASE_URL, { waitUntil: "networkidle0", timeout: 15000 });

    console.log(`Selecting dataset: ${dataset}`);
    await page.select("#dataset", dataset);
    await page.waitForFunction(
      () => document.getElementById("status")?.textContent.includes("Ready"),
      { timeout: 15000 }
    );

    if (region) {
      console.log(`Navigating to: ${region}`);
      await page.evaluate(locus => window.browser?.search(locus), region);
    }
    await new Promise(r => setTimeout(r, 2000));

    const baseName = outputName || `igv_${dataset.replace(/[\/\\]/g, "_")}`;

    // SVG — vector output from IGV.js API
    if (format === "svg" || format === "both") {
      const svg = await page.evaluate(() => {
        if (window.browser?.toSVG) return window.browser.toSVG();
        return null;
      });
      if (svg) {
        const svgPath = path.join(SCREENSHOT_DIR, `${baseName}.svg`);
        fs.writeFileSync(svgPath, svg);
        console.log(`SVG saved: ${svgPath} (${(fs.statSync(svgPath).size / 1024).toFixed(0)}KB)`);
      } else {
        console.log("SVG: browser.toSVG() not available");
      }
    }

    // Per-track SVG — extract each track as a separate SVG file
    if (perTrack && (format === "svg" || format === "both")) {
      const trackSVGs = await page.evaluate(() => {
        const b = window.browser;
        if (!b || !b.trackViews) return [];
        const results = [];
        for (const tv of b.trackViews) {
          const name = tv.track?.name || tv.track?.config?.name || "track";
          // Each trackView has a viewports array, each with a canvas
          const canvases = tv.viewports?.map(vp => vp.canvas) || [];
          // Get the track div's bounding box for clipping from the full SVG
          const div = tv.trackDiv;
          if (div) {
            results.push({
              name: name.replace(/[\/\\:*?"<>|]/g, "_").replace(/\s+/g, "_"),
              top: div.offsetTop,
              height: div.offsetHeight,
            });
          }
        }
        return results;
      });

      // Get the full SVG and split by track bounding boxes
      const fullSvg = await page.evaluate(() => window.browser?.toSVG?.() || "");
      if (fullSvg && trackSVGs.length > 0) {
        // Parse SVG dimensions
        const widthMatch = fullSvg.match(/width="(\d+)"/);
        const svgWidth = widthMatch ? parseInt(widthMatch[1]) : 1400;

        for (let i = 0; i < trackSVGs.length; i++) {
          const t = trackSVGs[i];
          if (t.height <= 0) continue;
          // Create a cropped SVG using viewBox
          const cropped = fullSvg
            .replace(/viewBox="[^"]*"/, `viewBox="0 ${t.top} ${svgWidth} ${t.height}"`)
            .replace(/height="[^"]*"/, `height="${t.height}"`);
          const trackPath = path.join(SCREENSHOT_DIR, `${baseName}_${i + 1}_${t.name}.svg`);
          fs.writeFileSync(trackPath, cropped);
          console.log(`  Track ${i + 1}: ${trackPath} (${t.name}, ${t.height}px)`);
        }
      }
    }

    // PNG — raster screenshot from Puppeteer
    if (format === "png" || format === "both") {
      const pngPath = path.join(SCREENSHOT_DIR, `${baseName}.png`);
      await page.screenshot({ path: pngPath, fullPage: true });
      console.log(`PNG saved: ${pngPath} (${(fs.statSync(pngPath).size / 1024).toFixed(0)}KB)`);
    }

    // Print DOM summary
    const summary = await page.evaluate(() => {
      const b = window.browser;
      const tracks = b?.trackViews?.length || 0;
      const alignments = [];
      for (const tv of (b?.trackViews || [])) {
        const at = tv.track?.alignmentTrack;
        if (at) alignments.push(tv.track.name || tv.track.config?.name || "unnamed");
      }
      return {
        dataset: document.getElementById("dataset")?.value,
        reference: b?.genome?.id,
        locus: b?.referenceFrameList?.[0]?.getLocusString?.(),
        tracks,
        alignmentTracks: alignments,
      };
    });
    console.log(`\nCapture summary:`);
    console.log(`  Dataset:    ${summary.dataset}`);
    console.log(`  Reference:  ${summary.reference}`);
    console.log(`  Locus:      ${summary.locus}`);
    console.log(`  Tracks:     ${summary.alignmentTracks.join(", ")}`);

  } finally {
    await browser.close();
  }
}

main().catch(e => {
  console.error("Error:", e.message);
  process.exit(1);
});
