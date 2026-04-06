// Dataset and reference discovery.
const fs = require("fs");
const path = require("path");
const { readdirSafe, isDirSafe } = require("./helpers");
const bam = require("./bam");

/**
 * @typedef {Object.<string, string>} DatasetMap - Maps dataset label to absolute directory path
 * @typedef {Object} ReferenceInfo
 * @property {string} id - Reference name (filename stem)
 * @property {string} name - Display name
 * @property {string} fastaURL - Servable URL for the FASTA
 * @property {string} indexURL - Servable URL for the FAI
 * @typedef {Object} LoadedDataset
 * @property {import('./bam').TrackInfo[]} tracks - Discovered BAM tracks
 * @property {string|null} refName - Reference sequence name from first BAM
 */

let WORKSPACE, SCAN_DIR, DATA_DIR;

function init(config) {
  WORKSPACE = config.WORKSPACE;
  SCAN_DIR = config.SCAN_DIR;
  DATA_DIR = config.DATA_DIR;
}

// Dataset description from description.txt in the dataset directory.
function datasetDescription(name, absDir) {
  if (absDir) {
    const descFile = path.join(absDir, "description.txt");
    try { return fs.readFileSync(descFile, "utf8").trim(); } catch {}
  }
  return null;
}

// Discover dataset directories (fast — only checks for 07_map/ or 09_correct/).
/** @returns {DatasetMap} */
function discoverDatasets() {
  const results = {};
  function scanDir(dir, label, maxDepth) {
    if (maxDepth < 0) return;
    if (fs.existsSync(path.join(dir, "07_map")) || fs.existsSync(path.join(dir, "09_correct"))) {
      results[label] = dir;
    }
    for (const sub of readdirSafe(dir)) {
      if (sub.startsWith(".") || sub === "node_modules") continue;
      const subFull = path.join(dir, sub);
      if (!isDirSafe(subFull)) continue;
      scanDir(subFull, label ? label + "/" + sub : sub, maxDepth - 1);
    }
  }
  const startLabel = SCAN_DIR === WORKSPACE ? "" : path.relative(WORKSPACE, SCAN_DIR);
  scanDir(SCAN_DIR, startLabel, 3);
  if (DATA_DIR && fs.existsSync(DATA_DIR) && path.resolve(DATA_DIR) !== path.resolve(SCAN_DIR)) {
    scanDir(DATA_DIR, path.basename(DATA_DIR) || "output", 3);
  }
  return results;
}

// Discover available reference FASTA files.
/** @returns {ReferenceInfo[]} */
function discoverReferences() {
  const refDir = path.join(WORKSPACE, "resources/references");
  const refs = [];
  for (const f of readdirSafe(refDir)) {
    if (!f.endsWith(".fasta") && !f.endsWith(".fa")) continue;
    const fai = path.join(refDir, f + ".fai");
    if (!fs.existsSync(fai)) continue;
    const name = f.replace(/\.(fasta|fa)$/, "");
    refs.push({ id: name, name, fastaURL: `/ref/${f}`, indexURL: `/ref/${f}.fai` });
  }
  return refs;
}

// Load tracks for a single dataset (reads BAM headers — called on demand only).
/** @returns {LoadedDataset|null} */
function loadDataset(outdir) {
  const tracks = bam.discoverTracks(outdir);
  if (tracks.length === 0) return null;
  const refName = bam.bamReferenceName(bam.resolveTrackPath(tracks[0].url));
  return { tracks, refName };
}

module.exports = { init, datasetDescription, discoverDatasets, discoverReferences, loadDataset };
