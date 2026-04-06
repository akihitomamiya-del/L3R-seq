// BAM file operations: header reading, track discovery, URL mapping.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { PIPELINE_STEPS, BGZF_BUFFER_SIZE } = require("../config");
const { readdirSafe, isDirSafe, statSafe } = require("./helpers");

/**
 * @typedef {Object} TrackInfo
 * @property {string} name - Display name (e.g. "barcode01/RPI_1 — corrected")
 * @property {string} url - Servable URL path for the BAM file
 * @property {string} indexURL - Servable URL path for the BAI file
 * @property {string} format - Always "bam"
 * @property {string} type - Always "alignment"
 * @property {string} color - Hex color from pipeline step config
 * @property {number} height - Track height in pixels
 * @property {string} displayMode - IGV display mode (e.g. "SQUISHED")
 * @property {boolean} showSoftClips - Whether to show soft clips
 * @property {boolean} [hidden] - If true, track is hidden by default
 */

let WORKSPACE, DATA_DIR;

function init(config) {
  WORKSPACE = config.WORKSPACE;
  DATA_DIR = config.DATA_DIR;
}

// Read the first reference sequence name from a BAM header (BGZF compressed).
function bamReferenceName(bamPath) {
  try {
    const fd = fs.openSync(bamPath, "r");
    const buf = Buffer.alloc(BGZF_BUFFER_SIZE);
    fs.readSync(fd, buf, 0, BGZF_BUFFER_SIZE, 0);
    fs.closeSync(fd);
    const bsize = buf.readUInt16LE(16);
    const block = buf.slice(0, bsize + 1);
    const dec = zlib.inflateRawSync(block.slice(18, block.length - 8));
    if (dec.slice(0, 4).toString() !== "BAM\x01") return null;
    const hdrLen = dec.readUInt32LE(4);
    const hdr = dec.slice(8, 8 + hdrLen).toString();
    const m = hdr.match(/@SQ\tSN:(\S+)/);
    return m ? m[1] : null;
  } catch { return null; }
}

// Map absolute BAM path to a servable URL prefix (/data/ or /extdata/)
function trackUrl(absPath) {
  const wsPrefix = path.resolve(WORKSPACE) + "/";
  if (absPath.startsWith(wsPrefix)) {
    return "/data/" + path.relative(WORKSPACE, absPath);
  }
  if (DATA_DIR) {
    const dataPrefix = path.resolve(DATA_DIR) + "/";
    if (absPath.startsWith(dataPrefix)) {
      return "/extdata/" + path.relative(DATA_DIR, absPath);
    }
  }
  return null;
}

// Resolve a track URL (e.g. /data/foo or /extdata/bar) to an absolute filesystem path.
function resolveTrackPath(url) {
  if (url.startsWith("/extdata/") && DATA_DIR) {
    return path.join(DATA_DIR, url.slice("/extdata/".length));
  }
  return path.join(WORKSPACE, url.replace(/^\/data\//, ""));
}

// Auto-discover sorted BAM files inside a pipeline output directory.
function discoverTracks(outdir) {
  const tracks = [];
  for (const step of PIPELINE_STEPS) {
    const stepDir = path.join(outdir, step.dir);
    if (!fs.existsSync(stepDir)) continue;
    for (const bc of readdirSafe(stepDir)) {
      const bcDir = path.join(stepDir, bc);
      if (!isDirSafe(bcDir)) continue;
      for (const rpi of readdirSafe(bcDir)) {
        const rpiDir = path.join(bcDir, rpi);
        if (!isDirSafe(rpiDir)) continue;
        const scanDir = step.subdir ? path.join(rpiDir, step.subdir) : rpiDir;
        if (!isDirSafe(scanDir)) continue;
        const candidates = step.file
          ? readdirSafe(scanDir).filter(f => f.endsWith(step.file))
          : readdirSafe(scanDir).filter(f => f.endsWith(".sort.bam") && !f.includes("chimeric_"));
        for (const f of candidates) {
          const bamPath = path.join(scanDir, f);
          if (!fs.existsSync(bamPath)) continue;
          const baiPath = bamPath + ".bai";
          if (!fs.existsSync(baiPath)) continue;
          const bamStat = statSafe(bamPath);
          if (!bamStat || bamStat.size < 200) continue;
          try {
            const baiData = fs.readFileSync(baiPath);
            if (baiData.length >= 12) {
              let hasData = false;
              for (let i = 8; i < baiData.length; i++) {
                if (baiData[i] !== 0) { hasData = true; break; }
              }
              if (!hasData) continue;
            }
          } catch (e) { console.warn("[warn] BAI read: " + e.message); continue; }
          const urlBam = trackUrl(bamPath);
          const urlBai = trackUrl(baiPath);
          if (!urlBam || !urlBai) continue;
          const track = {
            name: `${bc}/${rpi} — ${step.label}`,
            url: urlBam, indexURL: urlBai,
            format: "bam", type: "alignment",
            color: step.color, height: 250,
            displayMode: "SQUISHED", showSoftClips: true,
          };
          if (step.hidden) track.hidden = true;
          tracks.push(track);
        }
      }
    }
  }
  return tracks;
}

module.exports = { init, bamReferenceName, trackUrl, resolveTrackPath, discoverTracks };
