// Minimal HTTP server with CORS + byte-range support for IGV.js BAM viewing.
// Serves the viewer UI, reference files, and pipeline output data.
// Includes an /api/tracks endpoint that auto-discovers BAM files.
const http = require("http");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execSync } = require("child_process");
const { PIPELINE_STEPS, BGZF_BUFFER_SIZE, FASTA_WRAP_WIDTH } = require("./config");
const { generatePileup, SAMTOOLS } = require("./pileup");

// Ignore SIGHUP so the server survives when the parent shell (e.g.
// devcontainer postStartCommand) exits.  Node terminates on SIGHUP by
// default; this one-liner prevents that.
process.on("SIGHUP", () => {});

const PORT = process.env.IGV_PORT || 8080;
const WORKSPACE = process.env.IGV_WORKSPACE || "/workspace";
const SCAN_DIR = process.env.IGV_SCAN_DIR || WORKSPACE;  // --dir narrows discovery

// Dataset names to hide from the public /api/datasets listing.
// These are internal test outputs that clutter the dropdown.
// Override via L3RSEQ_HIDDEN_DATASETS env var (comma-separated).
const HIDDEN_DATASETS = (process.env.L3RSEQ_HIDDEN_DATASETS ||
  "pipeline_AG,pipeline_CT,pipeline_TC,blast_test,slam_test,splice_test,demo_test,full_preprocess,neg_test,discover_splice"
).split(",").map(s => s.trim()).filter(Boolean);
const DATA_DIR = process.env.IGV_DATA_DIR || "";          // external data mount (e.g. /data/output)

const MIME = {
  ".html": "text/html", ".js": "application/javascript",
  ".css": "text/css", ".json": "application/json",
  ".fasta": "text/plain", ".fa": "text/plain", ".fai": "text/plain",
  ".bam": "application/octet-stream", ".bai": "application/octet-stream",
  ".sam": "text/plain", ".bed": "text/plain", ".gff3": "text/plain",
  ".vcf": "text/plain", ".csv": "text/csv", ".txt": "text/plain",
};

const ROUTES = {
  "/igv/": path.join(WORKSPACE, "igv_viewer/node_modules/igv/dist/"),
  "/chartjs/": path.join(WORKSPACE, "igv_viewer/node_modules/chart.js/dist/"),
  "/js/": path.join(WORKSPACE, "igv_viewer/js/"),
  "/css/": path.join(WORKSPACE, "igv_viewer/css/"),
  "/ref/": path.join(WORKSPACE, "resources/references/"),
  "/data/": WORKSPACE + "/",
};
// Serve files from external data mount (bind-mounted /data/output)
if (DATA_DIR && fs.existsSync(DATA_DIR)) {
  ROUTES["/extdata/"] = DATA_DIR + "/";
}

// ---------------------------------------------------------------------------
// Safe filesystem helpers
// ---------------------------------------------------------------------------
function readdirSafe(dir) {
  try { return fs.readdirSync(dir).sort(naturalCompare); } catch (e) { console.warn("[warn] readdir " + dir + ": " + e.message); return []; }
}

// Natural sort: "RPI_2" before "RPI_10", "barcode3" before "barcode12"
function naturalCompare(a, b) {
  const re = /(\d+)/g;
  const pa = a.split(re), pb = b.split(re);
  for (let i = 0; i < Math.min(pa.length, pb.length); i++) {
    if (pa[i] !== pb[i]) {
      const na = Number(pa[i]), nb = Number(pb[i]);
      if (!isNaN(na) && !isNaN(nb)) return na - nb;
      return pa[i] < pb[i] ? -1 : 1;
    }
  }
  return pa.length - pb.length;
}

function isDirSafe(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function statSafe(p) {
  try { return fs.statSync(p); } catch { return null; }
}

// ---------------------------------------------------------------------------
// Read the first reference sequence name from a BAM header (BGZF compressed).
// Returns the @SQ SN value, or null on failure.
// ---------------------------------------------------------------------------
function bamReferenceName(bamPath) {
  try {
    const fd = fs.openSync(bamPath, "r");
    const buf = Buffer.alloc(BGZF_BUFFER_SIZE);
    const n = fs.readSync(fd, buf, 0, BGZF_BUFFER_SIZE, 0);
    fs.closeSync(fd);
    // BGZF: read BSIZE from first block header to get exact block length
    // Bytes 16-17 (LE) = BSIZE; block length = BSIZE + 1
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

// ---------------------------------------------------------------------------
// Auto-discover sorted BAM files inside a pipeline output directory.
// Looks for *.sort.bam files under 07_map/ and 09_correct/ subdirectories.
// ---------------------------------------------------------------------------
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

function discoverTracks(outdir) {
  const tracks = [];
  const steps = PIPELINE_STEPS;

  for (const step of steps) {
    const stepDir = path.join(outdir, step.dir);
    if (!fs.existsSync(stepDir)) continue;
    // Walk: stepDir / barcode / rpi / [subdir/] *.sort.bam
    for (const bc of readdirSafe(stepDir)) {
      const bcDir = path.join(stepDir, bc);
      if (!isDirSafe(bcDir)) continue;
      for (const rpi of readdirSafe(bcDir)) {
        const rpiDir = path.join(bcDir, rpi);
        if (!isDirSafe(rpiDir)) continue;
        const scanDir = step.subdir ? path.join(rpiDir, step.subdir) : rpiDir;
        if (!isDirSafe(scanDir)) continue;
        // If step specifies a file suffix, find matching files; otherwise *.sort.bam
        // Exclude chimeric BAM from the default scan (it has its own entry)
        const candidates = step.file
          ? readdirSafe(scanDir).filter(f => f.endsWith(step.file))
          : readdirSafe(scanDir).filter(f => f.endsWith(".sort.bam") && !f.includes("chimeric_"));
        for (const f of candidates) {
          const bamPath = path.join(scanDir, f);
          if (!fs.existsSync(bamPath)) continue;
          const baiPath = bamPath + ".bai";
          if (!fs.existsSync(baiPath)) continue;
          // Skip BAMs with no mapped reads: parse the BAI index to check.
          // BAI format: 4-byte magic "BAI\1", 4-byte n_ref, then per-ref
          // bin/chunk data.  An empty BAM's BAI has n_ref bins all with
          // zero chunks — the file is nearly all zeros after the header.
          // Quick heuristic: if the BAI file has no non-zero byte in the
          // bin data section (offset 8+), the BAM has no indexed reads.
          const bamStat = statSafe(bamPath);
          if (!bamStat || bamStat.size < 200) continue;  // minimal sanity
          try {
            const baiData = fs.readFileSync(baiPath);
            if (baiData.length >= 12) {
              // Check if any byte after the 8-byte header (magic+n_ref) is non-zero
              let hasData = false;
              for (let i = 8; i < baiData.length; i++) {
                if (baiData[i] !== 0) { hasData = true; break; }
              }
              if (!hasData) continue;  // empty BAI = no reads
            }
          } catch (e) { console.warn("[warn] BAI read: " + e.message); /* if we can't read BAI, skip this track */ continue; }
          const urlBam = trackUrl(bamPath);
          const urlBai = trackUrl(baiPath);
          if (!urlBam || !urlBai) continue;
          const track = {
            name: `${bc}/${rpi} — ${step.label}`,
            url: urlBam,
            indexURL: urlBai,
            format: "bam", type: "alignment",
            color: step.color, height: 250,
            displayMode: "SQUISHED",
            showSoftClips: true,
          };
          if (step.hidden) track.hidden = true;
          tracks.push(track);
        }
      }
    }
  }
  return tracks;
}

// Dataset descriptions: shown in the viewer info bar when a dataset is selected.
// The server reads a description.txt file from the dataset directory if present.
// To add a description to any run, create a description.txt file in the run's
// output directory (the one containing 07_map/ or 09_correct/).

function datasetDescription(name, absDir) {
  // 1. Check for description.txt in the dataset directory
  if (absDir) {
    const descFile = path.join(absDir, "description.txt");
    try {
      return fs.readFileSync(descFile, "utf8").trim();
    } catch {}
  }
  return null;
}

// Discover dataset directories (fast — only checks for 07_map/ or 09_correct/,
// does NOT read any BAM files). Returns { label: absPath } map.
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
  // Also scan external data mount if set
  if (DATA_DIR && fs.existsSync(DATA_DIR) && path.resolve(DATA_DIR) !== path.resolve(SCAN_DIR)) {
    scanDir(DATA_DIR, path.basename(DATA_DIR) || "output", 3);
  }
  return results;
}

// ---------------------------------------------------------------------------
// Discover UMI bin size statistics from step 04 output.
// Reads TSV files from read_binning/ under each barcode/RPI directory.
// ---------------------------------------------------------------------------
function parseTsv(filePath) {
  try {
    const lines = fs.readFileSync(filePath, "utf8").trim().split("\n");
    if (lines.length < 2) return [];
    const headers = lines[0].split("\t");
    return lines.slice(1).map(line => {
      const vals = line.split("\t");
      const row = {};
      headers.forEach((h, i) => row[h] = vals[i]);
      return row;
    });
  } catch { return []; }
}

function discoverUmiStats(outdir) {
  const umiDir = path.join(outdir, "04_umi");
  const result = { samples: [] };
  if (!isDirSafe(umiDir)) return result;

  for (const bc of readdirSafe(umiDir)) {
    const bcDir = path.join(umiDir, bc);
    if (!isDirSafe(bcDir)) continue;
    for (const rpi of readdirSafe(bcDir)) {
      const rpiDir = path.join(bcDir, rpi);
      if (!isDirSafe(rpiDir)) continue;
      const rbDir = path.join(rpiDir, "read_binning");
      if (!isDirSafe(rbDir)) continue;

      const sample = { id: bc + "/" + rpi, barcode: bc, rpi, stats: {}, size_dist: {} };

      // Parse umi_cluster_stats.tsv (stage, metric, value)
      for (const row of parseTsv(path.join(rbDir, "umi_cluster_stats.tsv"))) {
        const v = row.value;
        sample.stats[row.metric] = isNaN(Number(v)) ? v : Number(v);
      }

      // Parse umi_cluster_size_dist.tsv (cluster_size, count)
      for (const row of parseTsv(path.join(rbDir, "umi_cluster_size_dist.tsv"))) {
        sample.size_dist[row.cluster_size] = Number(row.count);
      }

      result.samples.push(sample);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Discover gene count data from step 11 output.
// ---------------------------------------------------------------------------
function discoverGeneCounts(outdir) {
  const countDir = path.join(outdir, "11_count");
  const result = { hasData: false, genes: [], samples: [], counts: [], isoforms: [], normalized: [] };

  if (!isDirSafe(countDir)) return result;

  // Parse gene_counts_all.tsv
  const allFile = path.join(countDir, "gene_counts_all.tsv");
  const allRows = parseTsv(allFile);
  if (allRows.length === 0) return result;

  result.hasData = true;
  result.counts = allRows.map(r => ({
    gene: r.gene,
    sample: r.sample,
    total_count: Number(r.total_count),
    splice_pattern: r.splice_pattern,
    pattern_count: Number(r.pattern_count),
  }));

  // Extract unique genes and samples
  result.genes = [...new Set(allRows.map(r => r.gene))].sort();
  result.samples = [...new Set(allRows.map(r => r.sample))].sort(naturalCompare);

  // Extract gene coordinates from the first per-sample count file
  result.geneInfo = {};
  const sampleFiles = readdirSafe(countDir).filter(f => f.endsWith("_gene_counts.tsv"));
  if (sampleFiles.length > 0) {
    for (const row of parseTsv(path.join(countDir, sampleFiles[0]))) {
      const gene = row["#gene"] || row.gene;
      if (gene && row.chr && !result.geneInfo[gene]) {
        result.geneInfo[gene] = { chr: row.chr, start: Number(row.start), end: Number(row.end) };
      }
    }
  }

  // Parse isoform_discovery.tsv
  const isoFile = path.join(countDir, "isoform_discovery.tsv");
  const isoRows = parseTsv(isoFile);
  result.isoforms = isoRows.map(r => ({
    barcode: r.barcode || "",
    gene: r.gene,
    splice_pattern: r.splice_pattern,
    pooled_count: Number(r.pooled_count),
    n_samples: Number(r.n_samples),
    samples_with_pattern: r.samples_with_pattern,
    pct_of_gene: r.pct_of_gene,
  }));

  // Parse gene_counts_normalized.tsv (if exists)
  const normFile = path.join(countDir, "gene_counts_normalized.tsv");
  const normRows = parseTsv(normFile);
  result.normalized = normRows.map(r => ({
    gene: r.gene,
    sample: r.sample,
    level: r.level,
    splice_pattern: r.splice_pattern,
    count: Number(r.count),
    hk_gene: r.hk_gene,
    hk_count: Number(r.hk_count),
    ratio: r.ratio === "NA" ? null : Number(r.ratio),
  }));

  return result;
}

// Read a coverage depth file and return positions + depths arrays.
function readCoverageFile(filePath) {
  try {
    const lines = fs.readFileSync(filePath, "utf8").trim().split("\n");
    const positions = [];
    const depths = [];
    for (const line of lines) {
      const parts = line.split("\t");
      if (parts.length >= 3) {
        positions.push(Number(parts[1]));
        depths.push(Number(parts[2]));
      }
    }
    return { positions, depths };
  } catch { return { positions: [], depths: [] }; }
}

// Resolve a track URL (e.g. /data/foo or /extdata/bar) to an absolute filesystem path.
function resolveTrackPath(url) {
  if (url.startsWith("/extdata/") && DATA_DIR) {
    return path.join(DATA_DIR, url.slice("/extdata/".length));
  }
  return path.join(WORKSPACE, url.replace(/^\/data\//, ""));
}

// Load tracks for a single dataset (reads BAM headers — called on demand only).
function loadDataset(outdir) {
  const tracks = discoverTracks(outdir);
  if (tracks.length === 0) return null;
  const refName = bamReferenceName(resolveTrackPath(tracks[0].url));
  return { tracks, refName };
}

// ---------------------------------------------------------------------------
// Sanitize a FASTA file: strip \r, ensure trailing newline, wrap long
// sequence lines to 80 chars, and regenerate the .fai index if stale.
// Called once at server startup for each reference file.
// ---------------------------------------------------------------------------
function sanitizeFasta(fastaPath) {
  // Skip large files (>10MB) — genome FASTAs from NCBI/Ensembl are already
  // correctly formatted. Sanitizing them is slow (synchronous 200MB+ read).
  const stat = statSafe(fastaPath);
  if (stat && stat.size > 10 * 1024 * 1024) return;

  let data;
  try { data = fs.readFileSync(fastaPath); } catch { return; }

  let dirty = false;

  // 1. Strip \r (Windows line endings)
  if (data.includes(0x0d)) {
    data = Buffer.from(data.toString("binary").replace(/\r/g, ""), "binary");
    dirty = true;
  }

  // 2. Ensure trailing newline
  if (data.length > 0 && data[data.length - 1] !== 0x0a) {
    data = Buffer.concat([data, Buffer.from("\n")]);
    dirty = true;
  }

  // 3. Wrap any sequence lines longer than FASTA_WRAP_WIDTH chars (IGV.js
  //    byte-range math works best with uniform short lines)
  const lines = data.toString().split("\n");
  let rewrapped = false;
  const out = [];
  for (const line of lines) {
    if (line.startsWith(">") || line.length <= FASTA_WRAP_WIDTH) {
      out.push(line);
    } else {
      for (let i = 0; i < line.length; i += FASTA_WRAP_WIDTH) {
        out.push(line.slice(i, i + FASTA_WRAP_WIDTH));
      }
      rewrapped = true;
    }
  }
  if (rewrapped) {
    data = Buffer.from(out.join("\n"));
    dirty = true;
  }

  if (dirty) {
    fs.writeFileSync(fastaPath, data);
    console.log(`  Fixed FASTA: ${path.basename(fastaPath)}`);
  }

  // 4. Regenerate .fai if missing or older than the FASTA
  const faiPath = fastaPath + ".fai";
  let needFai = !fs.existsSync(faiPath);
  if (!needFai) {
    const faStat = statSafe(fastaPath);
    const faiStat = statSafe(faiPath);
    if (faStat && faiStat && faStat.mtimeMs > faiStat.mtimeMs) needFai = true;
  }
  if (needFai || dirty) {
    // Build a simple .fai index (single-sequence FASTA typical for this pipeline)
    const text = data.toString();
    const faiLines = [];
    let seqName = null, seqLen = 0, offset = 0, lineBases = 0, lineWidth = 0;
    let firstSeqLine = true;
    for (const line of text.split("\n")) {
      if (line.startsWith(">")) {
        if (seqName) faiLines.push(`${seqName}\t${seqLen}\t${offset}\t${lineBases}\t${lineWidth}`);
        seqName = line.slice(1).split(/\s/)[0];
        seqLen = 0; firstSeqLine = true;
        offset = text.indexOf(line) + line.length + 1; // +1 for \n
      } else if (seqName && line.length > 0) {
        seqLen += line.length;
        if (firstSeqLine) { lineBases = line.length; lineWidth = line.length + 1; firstSeqLine = false; }
      }
    }
    if (seqName) faiLines.push(`${seqName}\t${seqLen}\t${offset}\t${lineBases}\t${lineWidth}`);
    fs.writeFileSync(faiPath, faiLines.join("\n") + "\n");
    console.log(`  Rebuilt FAI:  ${path.basename(faiPath)}`);
  }
}

// Discover available reference FASTA files
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

// ---------------------------------------------------------------------------
// File path resolution
// ---------------------------------------------------------------------------
function resolvePath(urlPath) {
  if (urlPath === "/" || urlPath === "/index.html") {
    return path.join(WORKSPACE, "igv_viewer/index.html");
  }
  if (urlPath === "/umi" || urlPath === "/umi.html") {
    return path.join(WORKSPACE, "igv_viewer/umi.html");
  }
  if (urlPath === "/genes" || urlPath === "/genes.html") {
    return path.join(WORKSPACE, "igv_viewer/genes.html");
  }
  for (const [prefix, base] of Object.entries(ROUTES)) {
    if (urlPath.startsWith(prefix)) {
      const rel = urlPath.slice(prefix.length);
      const resolved = path.resolve(base, rel);
      if (!resolved.startsWith(path.resolve(base))) return null;
      return resolved;
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Range");
  res.setHeader("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges");
  if (req.method === "OPTIONS") { res.writeHead(204); res.end(); return; }

  const urlPath = decodeURIComponent(req.url.split("?")[0]);

  // Health check endpoint
  if (urlPath === "/healthz") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ status: "ok", uptime: process.uptime() }));
    return;
  }

  // API: list available datasets (fast — no BAM reading)
  if (urlPath === "/api/datasets") {
    const datasets = discoverDatasets();
    // Sort and filter datasets: show featured datasets first, then the rest.
    // Featured datasets (demo, blast, splice, SLAM) appear in this fixed order;
    // other discovered datasets (runs/REP2, etc.) follow alphabetically.
    // Internal test outputs (pipeline_AG, pipeline_CT, pipeline_TC) are hidden.
    const order = ["demo", "blast", "splice", "SLAM"];
    const names = Object.keys(datasets)
      .filter(n => !HIDDEN_DATASETS.some(h => n.includes(h)))
      .sort((a, b) => {
        const aKey = order.findIndex(k => a.includes(k));
        const bKey = order.findIndex(k => b.includes(k));
        const aIdx = aKey >= 0 ? aKey : order.length;
        const bIdx = bKey >= 0 ? bKey : order.length;
        return aIdx !== bIdx ? aIdx - bIdx : a.localeCompare(b);
      });
    const dsInfo = names.map(n => ({ name: n, description: datasetDescription(n, datasets[n]) }));
    // Filter references to only those used by discovered datasets (fast: reads
    // one BAM header per dataset). Prevents large genome refs from cluttering
    // the dropdown when viewing test data that uses a small synthetic reference.
    const allRefs = discoverReferences();
    const usedRefNames = new Set();
    for (const n of names) {
      const tracks = discoverTracks(datasets[n]);
      if (tracks.length > 0) {
        const rn = bamReferenceName(resolveTrackPath(tracks[0].url));
        if (rn) usedRefNames.add(rn);
      }
    }
    // Match references by checking if ANY sequence name in the FASTA's .fai
    // matches a BAM reference name.  The old check compared the filename stem
    // (r.id) which fails for multi-sequence references (e.g. MpTak_v7.1.fa
    // contains chr1, chr2, ... but r.id is "MpTak_v7.1").
    const refs = usedRefNames.size > 0
      ? allRefs.filter(r => {
          if (usedRefNames.has(r.id)) return true;  // exact filename match (single-seq)
          // Check .fai for sequence names
          try {
            const faiPath = path.join(WORKSPACE, r.indexURL.replace(/^\/ref\//, "resources/references/"));
            const faiLines = fs.readFileSync(faiPath, "utf8").trim().split("\n");
            return faiLines.some(l => usedRefNames.has(l.split("\t")[0]));
          } catch (e) { console.warn("[warn] dataset check: " + e.message); return false; }
        })
      : allRefs;
    const data = { references: refs, datasets: names, datasetInfo: dsInfo };
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: load tracks for a specific dataset (on demand)
  if (urlPath === "/api/tracks") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = loadDataset(dir);
    if (!data) { res.writeHead(404); res.end("No BAM files found"); return; }
    data.description = datasetDescription(name, dir);
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: viewer state summary — what the browser would show for each dataset,
  // including which buttons/features are relevant (for Claude Code testing).
  if (urlPath === "/api/viewer-state") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const ds = loadDataset(dir);
    if (!ds) { res.writeHead(404); res.end("No BAM files found"); return; }

    // Analyze tracks to determine which viewer features are relevant
    const state = {
      dataset: name,
      reference: ds.refName,
      tracks: ds.tracks.length,
      features: {
        has_step07_and_09: ds.tracks.some(t => t.name.includes("step 07")) && ds.tracks.some(t => t.name.includes("step 09")),
        has_chimeric_track: ds.tracks.some(t => t.name.includes("chimeric")),
        has_raw_bin: ds.tracks.some(t => t.name.includes("raw bin")),
        has_consensus: ds.tracks.some(t => t.name.includes("consensus")),
      },
      buttons: {
        display_mode: "Always available (SQUISHED/EXPANDED)",
        show_all_reads: "Always available (disables downsampling)",
        show_soft_clips: "Always available (on by default)",
        show_mismatches: "Always available (on by default)",
      },
      sorting_tips: [],
    };

    // Check SAM tags in corrected track to suggest sorting
    try {
      const correctedTrack = ds.tracks.find(t => t.name.includes("corrected") || t.name.includes("step 09")) || ds.tracks[0];
      const correctedBam = path.join(WORKSPACE, correctedTrack.url.replace(/^\/data\//, ""));
      const tags = execSync(`${SAMTOOLS} view "${correctedBam}" 2>/dev/null | head -5 | tr '\\t' '\\n' | grep -oP '^[A-Z]{2}(?=:)' | sort -u`, { encoding: "utf8", timeout: 10000 }).trim().split("\n");
      if (tags.includes("EC")) state.sorting_tips.push("Sort by EC tag: groups reads by editing count");
      if (tags.includes("SC")) state.sorting_tips.push("Sort by SC tag: separates SLAM labeling gradient (0→high)");
      if (tags.includes("SJ")) state.sorting_tips.push("Sort by SJ tag: groups spliced (S) vs retained (R) vs unspanned (-)");
      if (tags.includes("TL")) state.sorting_tips.push("Sort by TL tag: separates translocations (TL:i:1) from normal");
      if (tags.includes("NC")) state.sorting_tips.push("Sort by NC tag: groups by noise level");
    } catch (e) { console.warn("[warn] tag discovery: " + e.message); }

    const json = JSON.stringify(state, null, 2);
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(json);
    return;
  }

  // API: text-based pileup view for CLI / Claude Code feedback.
  // Usage: /api/pileup?name=<dataset>&region=<ref:start-end>&width=<cols>
  // Returns plain-text alignment view using samtools + custom formatting.
  if (urlPath === "/api/pileup") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    const region = params.get("region") || "";
    const width = parseInt(params.get("width") || "120", 10);
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }

    const pileupDeps = { discoverTracks, resolveTrackPath, bamReferenceName, readdirSafe, WORKSPACE };
    generatePileup(dir, region, width, (err, text) => {
      if (err) { res.writeHead(500); res.end("Error: " + err); return; }
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(text);
    }, pileupDeps);
    return;
  }

  // API: UMI bin size statistics for cross-sample comparison.
  // Reads TSV files from step 04 output (read_binning/).
  if (urlPath === "/api/umi-stats") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = discoverUmiStats(dir);
    data.dataset = name;
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: gene count data from step 11 output.
  if (urlPath === "/api/gene-counts") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = discoverGeneCounts(dir);
    data.dataset = name;
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: per-base coverage for a specific gene and sample.
  if (urlPath === "/api/gene-coverage") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    const gene = params.get("gene");
    const sample = params.get("sample");
    if (!name || !gene || !sample) {
      res.writeHead(400); res.end("Missing ?name=, ?gene=, or ?sample= parameter"); return;
    }
    const datasets = discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    // sample format: "barcode/rpi" → coverage file: barcode_rpi_gene.depth.tsv
    const sampleParts = sample.split("/");
    const covFileName = sampleParts.join("_") + "_" + gene + ".depth.tsv";
    const covPath = path.join(dir, "11_count", "coverage", covFileName);
    const data = readCoverageFile(covPath);
    data.gene = gene;
    data.sample = sample;
    const json = JSON.stringify(data);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  const filePath = resolvePath(urlPath);
  if (!filePath) { res.writeHead(404); res.end("Not found"); return; }
  const stat = statSafe(filePath);
  if (!stat) { res.writeHead(404); res.end("Not found"); return; }

  const ext = path.extname(filePath);
  const mime = MIME[ext] || "application/octet-stream";

  // Byte-range support (required for BAM)
  const rangeHeader = req.headers.range;
  if (rangeHeader) {
    const match = rangeHeader.match(/bytes=(\d+)-(\d*)/);
    if (match) {
      const start = parseInt(match[1], 10);
      const end = match[2] ? Math.min(parseInt(match[2], 10), stat.size - 1) : stat.size - 1;
      if (end < 0 || start > end) { res.writeHead(416); res.end(); return; }
      res.writeHead(206, {
        "Content-Type": mime,
        "Content-Range": `bytes ${start}-${end}/${stat.size}`,
        "Content-Length": end - start + 1,
        "Accept-Ranges": "bytes",
      });
      fs.createReadStream(filePath, { start, end }).pipe(res);
      return;
    }
  }

  const headers = { "Content-Type": mime, "Accept-Ranges": "bytes" };
  // Prevent browser caching of HTML pages so edits take effect on refresh
  if (ext === ".html") headers["Cache-Control"] = "no-cache, no-store, must-revalidate";
  // Cache immutable library bundles (igv.js, chart.js) for 1 day
  else if (urlPath.startsWith("/igv/") || urlPath.startsWith("/chartjs/"))
    headers["Cache-Control"] = "public, max-age=86400";

  // Gzip compressible content (text, JS, CSS, JSON, FASTA) — big win over port forwarding
  const compressible = /^(text\/|application\/javascript|application\/json)/.test(mime);
  const acceptGzip = (req.headers["accept-encoding"] || "").includes("gzip");
  if (compressible && acceptGzip) {
    headers["Content-Encoding"] = "gzip";
    delete headers["Content-Length"];
    res.writeHead(200, headers);
    fs.createReadStream(filePath).pipe(zlib.createGzip()).pipe(res);
  } else {
    headers["Content-Length"] = stat.size;
    res.writeHead(200, headers);
    fs.createReadStream(filePath).pipe(res);
  }
});

// Sanitize all reference FASTA files before starting
const refDir = path.join(WORKSPACE, "resources/references");
console.log("Checking reference FASTA files...");
for (const f of readdirSafe(refDir)) {
  if (f.endsWith(".fasta") || f.endsWith(".fa")) {
    sanitizeFasta(path.join(refDir, f));
  }
}

server.listen(PORT, () => {
  console.log(`IGV.js server running at http://localhost:${PORT}`);
  console.log("Open this URL in your browser (port will be auto-forwarded in Codespaces/VS Code)");
});

function shutdown(signal) {
  console.log(`${signal} received, shutting down...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
