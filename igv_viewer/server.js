// Minimal HTTP server with CORS + byte-range support for IGV.js BAM viewing.
// Serves the viewer UI, reference files, and pipeline output data.
// Domain logic lives in lib/ modules; this file is the HTTP adapter.
const http = require("http");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { execSync } = require("child_process");
const { generatePileup, SAMTOOLS } = require("./pileup");

const helpers = require("./lib/helpers");
const bam = require("./lib/bam");
const discovery = require("./lib/discovery");
const stats = require("./lib/pipeline-stats");
const fasta = require("./lib/fasta");

// Ignore SIGHUP so the server survives when the parent shell (e.g.
// devcontainer postStartCommand) exits.  Node terminates on SIGHUP by
// default; this one-liner prevents that.
process.on("SIGHUP", () => {});

const PORT = process.env.IGV_PORT || 8080;
const WORKSPACE = process.env.IGV_WORKSPACE || "/workspace";
const SCAN_DIR = process.env.IGV_SCAN_DIR || WORKSPACE;  // --dir narrows discovery

// Dataset names to hide from the public /api/datasets listing.
const HIDDEN_DATASETS = (process.env.L3RSEQ_HIDDEN_DATASETS ||
  "pipeline_AG,pipeline_CT,pipeline_TC,blast_test,slam_test,splice_test,demo_test,full_preprocess,neg_test,discover_splice"
).split(",").map(s => s.trim()).filter(Boolean);
const DATA_DIR = process.env.IGV_DATA_DIR || "";          // external data mount (e.g. /data/output)

// Initialize lib modules with environment config
bam.init({ WORKSPACE, DATA_DIR });
discovery.init({ WORKSPACE, SCAN_DIR, DATA_DIR });

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
if (DATA_DIR && fs.existsSync(DATA_DIR)) {
  ROUTES["/extdata/"] = DATA_DIR + "/";
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
    const datasets = discovery.discoverDatasets();
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
    const dsInfo = names.map(n => ({ name: n, description: discovery.datasetDescription(n, datasets[n]) }));
    const allRefs = discovery.discoverReferences();
    const usedRefNames = new Set();
    for (const n of names) {
      const tracks = bam.discoverTracks(datasets[n]);
      if (tracks.length > 0) {
        const rn = bam.bamReferenceName(bam.resolveTrackPath(tracks[0].url));
        if (rn) usedRefNames.add(rn);
      }
    }
    const refs = usedRefNames.size > 0
      ? allRefs.filter(r => {
          if (usedRefNames.has(r.id)) return true;
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
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = discovery.loadDataset(dir);
    if (!data) { res.writeHead(404); res.end("No BAM files found"); return; }
    data.description = discovery.datasetDescription(name, dir);
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: viewer state summary
  if (urlPath === "/api/viewer-state") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const ds = discovery.loadDataset(dir);
    if (!ds) { res.writeHead(404); res.end("No BAM files found"); return; }

    const state = {
      dataset: name, reference: ds.refName, tracks: ds.tracks.length,
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
    try {
      const correctedTrack = ds.tracks.find(t => t.name.includes("corrected") || t.name.includes("step 09")) || ds.tracks[0];
      const correctedBam = bam.resolveTrackPath(correctedTrack.url);
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

  // API: text-based pileup view
  if (urlPath === "/api/pileup") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    const region = params.get("region") || "";
    const width = parseInt(params.get("width") || "120", 10);
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const pileupDeps = {
      discoverTracks: bam.discoverTracks,
      resolveTrackPath: bam.resolveTrackPath,
      bamReferenceName: bam.bamReferenceName,
      readdirSafe: helpers.readdirSafe,
      WORKSPACE,
    };
    generatePileup(dir, region, width, (err, text) => {
      if (err) { res.writeHead(500); res.end("Error: " + err); return; }
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(text);
    }, pileupDeps);
    return;
  }

  // API: UMI bin size statistics
  if (urlPath === "/api/umi-stats") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = stats.discoverUmiStats(dir);
    data.dataset = name;
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: gene count data
  if (urlPath === "/api/gene-counts") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    if (!name) { res.writeHead(400); res.end("Missing ?name= parameter"); return; }
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const data = stats.discoverGeneCounts(dir);
    data.dataset = name;
    const json = JSON.stringify(data, null, 2);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // API: per-base coverage for a specific gene and sample
  if (urlPath === "/api/gene-coverage") {
    const params = new URL(req.url, `http://${req.headers.host}`).searchParams;
    const name = params.get("name");
    const gene = params.get("gene");
    const sample = params.get("sample");
    if (!name || !gene || !sample) {
      res.writeHead(400); res.end("Missing ?name=, ?gene=, or ?sample= parameter"); return;
    }
    const datasets = discovery.discoverDatasets();
    const dir = datasets[name];
    if (!dir) { res.writeHead(404); res.end("Dataset not found"); return; }
    const sampleParts = sample.split("/");
    const covFileName = sampleParts.join("_") + "_" + gene + ".depth.tsv";
    const covPath = path.join(dir, "11_count", "coverage", covFileName);
    const data = stats.readCoverageFile(covPath);
    data.gene = gene;
    data.sample = sample;
    const json = JSON.stringify(data);
    res.writeHead(200, { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(json) });
    res.end(json);
    return;
  }

  // ---------------------------------------------------------------------------
  // Static file serving
  // ---------------------------------------------------------------------------
  const filePath = resolvePath(urlPath);
  if (!filePath) { res.writeHead(404); res.end("Not found"); return; }
  const stat = helpers.statSafe(filePath);
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
  if (ext === ".html" || urlPath.startsWith("/js/") || urlPath.startsWith("/css/"))
    headers["Cache-Control"] = "no-cache, no-store, must-revalidate";
  else if (urlPath.startsWith("/igv/") || urlPath.startsWith("/chartjs/"))
    headers["Cache-Control"] = "public, max-age=86400";

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
for (const f of helpers.readdirSafe(refDir)) {
  if (f.endsWith(".fasta") || f.endsWith(".fa")) {
    fasta.sanitizeFasta(path.join(refDir, f));
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
