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

// 15s TTL caches — discoverDatasets and discoverReferences walk the
// filesystem and are called by every /api/* endpoint. At ~2.5s per scan
// across tests/output (thousands of files), a short cache turns repeated
// hits into sub-millisecond lookups. Staleness ceiling is 15s, which is
// acceptable: new pipeline runs take minutes, and the viewer is restarted
// on `L3Rseq viewer --dir` anyway.
const CACHE_TTL_MS = 15000;
let _datasetsCache = null;
let _referencesCache = null;

function init(config) {
  WORKSPACE = config.WORKSPACE;
  SCAN_DIR = config.SCAN_DIR;
  DATA_DIR = config.DATA_DIR;
  _datasetsCache = null;
  _referencesCache = null;
}

// Dataset description from description.txt in the dataset directory.
function datasetDescription(name, absDir) {
  if (absDir) {
    const descFile = path.join(absDir, "description.txt");
    try { return fs.readFileSync(descFile, "utf8").trim(); } catch {}
  }
  return null;
}

function _scanDatasets() {
  const results = {};
  function scanDir(dir, label, maxDepth) {
    if (maxDepth < 0) return;
    if (fs.existsSync(path.join(dir, "07_map")) || fs.existsSync(path.join(dir, "09_correct"))) {
      results[label] = dir;
    }
    // withFileTypes avoids a separate stat() per entry (~2× speedup on
    // large tests/output trees).
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
    catch { return; }
    entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    for (const ent of entries) {
      if (!ent.isDirectory()) continue;
      const sub = ent.name;
      if (sub.startsWith(".") || sub === "node_modules") continue;
      scanDir(path.join(dir, sub), label ? label + "/" + sub : sub, maxDepth - 1);
    }
  }
  const startLabel = SCAN_DIR === WORKSPACE ? "" : path.relative(WORKSPACE, SCAN_DIR);
  scanDir(SCAN_DIR, startLabel, 3);
  if (DATA_DIR && fs.existsSync(DATA_DIR) && path.resolve(DATA_DIR) !== path.resolve(SCAN_DIR)) {
    scanDir(DATA_DIR, path.basename(DATA_DIR) || "output", 3);
  }
  return results;
}

// Discover dataset directories (only checks for 07_map/ or 09_correct/).
/** @returns {DatasetMap} */
function discoverDatasets() {
  const now = Date.now();
  if (_datasetsCache && _datasetsCache.expiresAt > now) return _datasetsCache.value;
  const value = _scanDatasets();
  _datasetsCache = { value, expiresAt: now + CACHE_TTL_MS };
  return value;
}

function _scanReferences() {
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

// Discover available reference FASTA files.
/** @returns {ReferenceInfo[]} */
function discoverReferences() {
  const now = Date.now();
  if (_referencesCache && _referencesCache.expiresAt > now) return _referencesCache.value;
  const value = _scanReferences();
  _referencesCache = { value, expiresAt: now + CACHE_TTL_MS };
  return value;
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
