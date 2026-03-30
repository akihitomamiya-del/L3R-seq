// Minimal HTTP server with CORS + byte-range support for IGV.js BAM viewing.
// Serves the viewer UI, reference files, and pipeline output data.
// Includes an /api/tracks endpoint that auto-discovers BAM files.
const http = require("http");
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// Ignore SIGHUP so the server survives when the parent shell (e.g.
// devcontainer postStartCommand) exits.  Node terminates on SIGHUP by
// default; this one-liner prevents that.
process.on("SIGHUP", () => {});

const PORT = process.env.IGV_PORT || 8080;
const WORKSPACE = process.env.IGV_WORKSPACE || "/workspace";
const SCAN_DIR = process.env.IGV_SCAN_DIR || WORKSPACE;  // --dir narrows discovery
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
  try { return fs.readdirSync(dir); } catch { return []; }
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
    const buf = Buffer.alloc(65536);
    const n = fs.readSync(fd, buf, 0, 65536, 0);
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
  const steps = [
    { dir: "01_raw_bin", label: "raw bin reads", color: "#e8d5b7" },
    { dir: "02_consensus", label: "consensus", color: "#5dade2" },
    { dir: "07_map", label: "mapping (step 07)", color: "#b0b0b0" },
    { dir: "09_correct", label: "corrected (step 09)", color: "#f5e6ca" },
    { dir: "09_correct", file: "chimeric_rightclip.sort.bam", label: "chimeric (removed)", color: "#e74c3c" },
  ];

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
        // If step specifies a single file, only look for that; otherwise *.sort.bam
        // Exclude chimeric BAM from the default scan (it has its own entry)
        const candidates = step.file
          ? [step.file]
          : readdirSafe(scanDir).filter(f => f.endsWith(".sort.bam") && !f.startsWith("chimeric_"));
        for (const f of candidates) {
          const bamPath = path.join(scanDir, f);
          if (!fs.existsSync(bamPath)) continue;
          const baiPath = bamPath + ".bai";
          if (!fs.existsSync(baiPath)) continue;
          const urlBam = trackUrl(bamPath);
          const urlBai = trackUrl(baiPath);
          if (!urlBam || !urlBai) continue;
          tracks.push({
            name: `${bc}/${rpi} — ${step.label}`,
            url: urlBam,
            indexURL: urlBai,
            format: "bam", type: "alignment",
            color: step.color, height: 250,
            displayMode: "SQUISHED",
            showSoftClips: true,
          });
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

  // 3. Wrap any sequence lines longer than 80 chars (IGV.js byte-range
  //    math works best with uniform short lines)
  const lines = data.toString().split("\n");
  let rewrapped = false;
  const out = [];
  for (const line of lines) {
    if (line.startsWith(">") || line.length <= 80) {
      out.push(line);
    } else {
      for (let i = 0; i < line.length; i += 80) {
        out.push(line.slice(i, i + 80));
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
// Text-based pileup view (for CLI / Claude Code feedback)
// Uses samtools to read BAMs and generates a formatted text representation.
// ---------------------------------------------------------------------------
const { execSync } = require("child_process");

// Find samtools in conda environments (not in default PATH for Node.js)
function findSamtools() {
  const candidates = [
    "/opt/miniforge/envs/NanoporeMap/bin/samtools",
    "/opt/miniforge/envs/longread_umi/bin/samtools",
    "/opt/miniforge/envs/LoFreq/bin/samtools",
  ];
  for (const p of candidates) { if (fs.existsSync(p)) return p; }
  try { return execSync("which samtools 2>/dev/null", { encoding: "utf8" }).trim(); } catch { return "samtools"; }
}
const SAMTOOLS = findSamtools();


function generatePileup(outdir, region, width, callback) {
  try {
    const tracks = discoverTracks(outdir);
    if (tracks.length === 0) return callback("No tracks found");

    // Find the reference for this dataset
    const firstBamPath = resolveTrackPath(tracks[0].url);
    const refName = bamReferenceName(firstBamPath);

    // Find matching reference FASTA
    const refDir = path.join(WORKSPACE, "resources/references");
    let refPath = null;
    for (const f of readdirSafe(refDir)) {
      if ((f.endsWith(".fasta") || f.endsWith(".fa")) && f.replace(/\.(fasta|fa)$/, "") === refName) {
        refPath = path.join(refDir, f);
        break;
      }
    }

    // Determine region: if not specified, auto-detect from first BAM
    let viewRegion = region;
    if (!viewRegion && refName) {
      try {
        const idxstats = execSync(`${SAMTOOLS} idxstats "${firstBamPath}" 2>/dev/null`, { encoding: "utf8" });
        const line = idxstats.split("\n").find(l => l.startsWith(refName));
        if (line) {
          const refLen = parseInt(line.split("\t")[1], 10);
          viewRegion = `${refName}:1-${Math.min(refLen, width * 3)}`;
        }
      } catch {}
    }

    const lines = [];
    lines.push(`Dataset: ${path.basename(outdir)}`);
    lines.push(`Reference: ${refName || "unknown"}`);
    lines.push(`Region: ${viewRegion || "full"}`);
    lines.push("");

    // Per-track: read count, coverage summary, SAM tag stats, sample reads
    for (const track of tracks) {
      const bamPath = resolveTrackPath(track.url);
      if (!fs.existsSync(bamPath)) continue;

      const label = track.name.split(" — ")[1] || track.name;
      let readCount = 0;
      try { readCount = parseInt(execSync(`${SAMTOOLS} view -c "${bamPath}" 2>/dev/null`, { encoding: "utf8" }).trim(), 10); } catch {}

      lines.push(`── ${label} (${readCount} reads) ──`);

      if (readCount === 0) { lines.push("  (empty)"); lines.push(""); continue; }

      // SAM tag summary: EC, SC, NC, SJ distributions
      try {
        const tagOutput = execSync(
          `${SAMTOOLS} view "${bamPath}" 2>/dev/null | head -200 | awk -F'\\t' '` +
          `{ for(i=12;i<=NF;i++) {` +
          `  if($i~/^EC:i:/) { split($i,a,":"); ec+=a[3]; ecn++ }` +
          `  if($i~/^SC:i:/) { split($i,a,":"); sc+=a[3]; scn++ }` +
          `  if($i~/^NC:i:/) { split($i,a,":"); nc+=a[3]; ncn++ }` +
          `  if($i~/^SJ:Z:S/) sj_s++; if($i~/^SJ:Z:R/) sj_r++; if($i~/^SJ:Z:-/) sj_u++` +
          `  if($i~/^TL:i:1/) tl++` +
          `} }` +
          `END {` +
          `  if(ecn) printf "  EC: total=%d mean=%.1f\\n", ec, ec/ecn;` +
          `  if(scn) printf "  SC: total=%d mean=%.1f\\n", sc, sc/scn;` +
          `  if(ncn) printf "  NC: total=%d mean=%.1f\\n", nc, nc/ncn;` +
          `  if(sj_s+sj_r+sj_u) printf "  SJ: S=%d R=%d -=%d\\n", sj_s+0, sj_r+0, sj_u+0;` +
          `  if(tl) printf "  TL: %d translocations\\n", tl;` +
          `}'`,
          { encoding: "utf8" }
        );
        if (tagOutput.trim()) lines.push(tagOutput.trimEnd());
      } catch {}

      // CIGAR summary: soft-clip distribution
      try {
        const cigarOutput = execSync(
          `${SAMTOOLS} view "${bamPath}" 2>/dev/null | head -200 | awk -F'\\t' '` +
          `{ c=$6; ` +
          `  if(match(c,/^[0-9]+S/)) left_s++;` +
          `  if(match(c,/[0-9]+S$/)) { s=substr(c,RSTART); gsub(/S/,"",s); if(s+0>5) right_s++; tot_clip+=s+0 }` +
          `  n++` +
          `}` +
          `END { printf "  CIGARs: %d reads, %d with right-clip >5bp", n, right_s+0;` +
          `  if(right_s) printf " (avg %dbp)", tot_clip/right_s;` +
          `  printf "\\n" }'`,
          { encoding: "utf8" }
        );
        if (cigarOutput.trim()) lines.push(cigarOutput.trimEnd());
      } catch {}

      // Show sample reads with key tags
      try {
        const sampleOutput = execSync(
          `${SAMTOOLS} view "${bamPath}" ${viewRegion || ""} 2>/dev/null | head -8 | awk -F'\\t' '` +
          `{ name=$1; pos=$4; cigar=$6; tags="";` +
          `  for(i=12;i<=NF;i++) {` +
          `    if($i~/^(EC|SC|NC|SJ|TL|3E):/) tags=tags " " $i` +
          `  }` +
          `  printf "  %-30s pos=%-5s cigar=%-20s%s\\n", substr(name,1,30), pos, cigar, tags` +
          `}'`,
          { encoding: "utf8" }
        );
        if (sampleOutput.trim()) {
          lines.push("  Sample reads:");
          lines.push(sampleOutput.trimEnd());
        }
      } catch {}

      // Depth profile (text sparkline) if region specified
      if (viewRegion && refPath) {
        try {
          const depthOutput = execSync(
            `${SAMTOOLS} depth -r "${viewRegion}" "${bamPath}" 2>/dev/null | awk '` +
            `BEGIN { max=0 } { d[NR]=$3; pos[NR]=$2; if($3>max) max=$3; n=NR }` +
            `END {` +
            `  if(n==0) exit;` +
            `  step = int(n/${width}) + 1; if(step<1) step=1;` +
            `  chars = " ▁▂▃▄▅▆▇█";` +
            `  printf "  Coverage (%dx max): ", max;` +
            `  for(i=1; i<=n; i+=step) {` +
            `    lvl = int(d[i] / max * 8); if(lvl>8) lvl=8;` +
            `    printf "%s", substr(chars, lvl+1, 1)` +
            `  }` +
            `  printf "\\n  Region: %s:%d-%d\\n", $1, pos[1], pos[n]` +
            `}'`,
            { encoding: "utf8" }
          );
          if (depthOutput.trim()) lines.push(depthOutput.trimEnd());
        } catch {}
      }

      lines.push("");
    }

    callback(null, lines.join("\n"));
  } catch (e) {
    callback(e.message);
  }
}

// ---------------------------------------------------------------------------
// File path resolution
// ---------------------------------------------------------------------------
function resolvePath(urlPath) {
  if (urlPath === "/" || urlPath === "/index.html") {
    return path.join(WORKSPACE, "igv_viewer/index.html");
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

  // API: list available datasets (fast — no BAM reading)
  if (urlPath === "/api/datasets") {
    const datasets = discoverDatasets();
    // Sort and filter datasets: show featured datasets first, then the rest.
    // Featured datasets (demo, blast, splice, SLAM) appear in this fixed order;
    // other discovered datasets (runs/REP2, etc.) follow alphabetically.
    // Internal test outputs (pipeline_AG, pipeline_CT, pipeline_TC) are hidden.
    const order = ["demo", "blast", "splice", "SLAM"];
    const hidden = ["pipeline_AG", "pipeline_CT", "pipeline_TC", "blast_test", "slam_test", "splice_test", "demo_test",
                     "full_preprocess", "neg_test", "discover_splice"];
    const names = Object.keys(datasets)
      .filter(n => !hidden.some(h => n.includes(h)))
      .sort((a, b) => {
        const aKey = order.findIndex(k => a.includes(k));
        const bKey = order.findIndex(k => b.includes(k));
        const aIdx = aKey >= 0 ? aKey : order.length;
        const bIdx = bKey >= 0 ? bKey : order.length;
        return aIdx !== bIdx ? aIdx - bIdx : a.localeCompare(b);
      });
    const dsInfo = names.map(n => ({ name: n, description: datasetDescription(n, datasets[n]) }));
    const data = { references: discoverReferences(), datasets: names, datasetInfo: dsInfo };
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
      const tags = execSync(`${SAMTOOLS} view "${correctedBam}" 2>/dev/null | head -5 | tr '\\t' '\\n' | grep -oP '^[A-Z]{2}(?=:)' | sort -u`, { encoding: "utf8" }).trim().split("\n");
      if (tags.includes("EC")) state.sorting_tips.push("Sort by EC tag: groups reads by editing count");
      if (tags.includes("SC")) state.sorting_tips.push("Sort by SC tag: separates SLAM labeling gradient (0→high)");
      if (tags.includes("SJ")) state.sorting_tips.push("Sort by SJ tag: groups spliced (S) vs retained (R) vs unspanned (-)");
      if (tags.includes("TL")) state.sorting_tips.push("Sort by TL tag: separates translocations (TL:i:1) from normal");
      if (tags.includes("NC")) state.sorting_tips.push("Sort by NC tag: groups by noise level");
    } catch {}

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

    generatePileup(dir, region, width, (err, text) => {
      if (err) { res.writeHead(500); res.end("Error: " + err); return; }
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end(text);
    });
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

  res.writeHead(200, { "Content-Type": mime, "Content-Length": stat.size, "Accept-Ranges": "bytes" });
  fs.createReadStream(filePath).pipe(res);
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
