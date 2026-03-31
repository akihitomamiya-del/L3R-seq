// Text-based pileup view (for CLI / Claude Code feedback).
// Uses samtools to read BAMs and generates a formatted text representation.
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const SCRIPTS_DIR = path.join(__dirname, "scripts");

// Find samtools in conda environments (not in default PATH for Node.js)
function findSamtools() {
  const candidates = [
    "/opt/miniforge/envs/NanoporeMap/bin/samtools",
    "/opt/miniforge/envs/longread_umi/bin/samtools",
    "/opt/miniforge/envs/LoFreq/bin/samtools",
  ];
  for (const p of candidates) { if (fs.existsSync(p)) return p; }
  try { return execSync("which samtools 2>/dev/null", { encoding: "utf8" }).trim(); } catch {}
  console.error("WARNING: samtools not found in any conda environment or PATH.");
  console.error("  Pileup generation will not work. Install samtools or activate a conda env.");
  return "samtools";
}
const SAMTOOLS = findSamtools();

/**
 * Generate a text pileup summary for a dataset.
 * @param {string} outdir - Absolute path to dataset directory.
 * @param {string|null} region - Genomic region (e.g. "chr1:100-500"), or null for auto.
 * @param {number} width - Terminal width for sparkline.
 * @param {Function} callback - callback(err, text).
 * @param {Object} deps - Injected dependencies: { discoverTracks, resolveTrackPath, bamReferenceName, readdirSafe }.
 */
function generatePileup(outdir, region, width, callback, deps) {
  const { discoverTracks, resolveTrackPath, bamReferenceName, readdirSafe } = deps;
  try {
    const tracks = discoverTracks(outdir);
    if (tracks.length === 0) return callback("No tracks found");

    const firstBamPath = resolveTrackPath(tracks[0].url);
    const refName = bamReferenceName(firstBamPath);

    // Find matching reference FASTA
    const refDir = path.join(deps.WORKSPACE, "resources/references");
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
      } catch (e) { console.warn("[pileup] idxstats failed:", e.message); }
    }

    const lines = [];
    lines.push(`Dataset: ${path.basename(outdir)}`);
    lines.push(`Reference: ${refName || "unknown"}`);
    lines.push(`Region: ${viewRegion || "full"}`);
    lines.push("");

    for (const track of tracks) {
      const bamPath = resolveTrackPath(track.url);
      if (!fs.existsSync(bamPath)) continue;

      const label = track.name.split(" — ")[1] || track.name;
      let readCount = 0;
      try { readCount = parseInt(execSync(`${SAMTOOLS} view -c "${bamPath}" 2>/dev/null`, { encoding: "utf8" }).trim(), 10); } catch {}

      lines.push(`── ${label} (${readCount} reads) ──`);
      if (readCount === 0) { lines.push("  (empty)"); lines.push(""); continue; }

      // Tag summary
      try {
        const out = execSync(
          `${SAMTOOLS} view "${bamPath}" 2>/dev/null | head -200 | awk -f "${SCRIPTS_DIR}/tag_summary.awk"`,
          { encoding: "utf8" }
        );
        if (out.trim()) lines.push(out.trimEnd());
      } catch (e) { console.warn(`[pileup] tag_summary failed for ${label}:`, e.message); }

      // CIGAR summary
      try {
        const out = execSync(
          `${SAMTOOLS} view "${bamPath}" 2>/dev/null | head -200 | awk -f "${SCRIPTS_DIR}/cigar_summary.awk"`,
          { encoding: "utf8" }
        );
        if (out.trim()) lines.push(out.trimEnd());
      } catch (e) { console.warn(`[pileup] cigar_summary failed for ${label}:`, e.message); }

      // Sample reads
      try {
        const out = execSync(
          `${SAMTOOLS} view "${bamPath}" ${viewRegion || ""} 2>/dev/null | head -8 | awk -f "${SCRIPTS_DIR}/sample_reads.awk"`,
          { encoding: "utf8" }
        );
        if (out.trim()) {
          lines.push("  Sample reads:");
          lines.push(out.trimEnd());
        }
      } catch (e) { console.warn(`[pileup] sample_reads failed for ${label}:`, e.message); }

      // Depth sparkline
      if (viewRegion && refPath) {
        try {
          const out = execSync(
            `${SAMTOOLS} depth -r "${viewRegion}" "${bamPath}" 2>/dev/null | awk -v width=${width} -f "${SCRIPTS_DIR}/depth_sparkline.awk"`,
            { encoding: "utf8" }
          );
          if (out.trim()) lines.push(out.trimEnd());
        } catch (e) { console.warn(`[pileup] depth_sparkline failed for ${label}:`, e.message); }
      }

      lines.push("");
    }

    callback(null, lines.join("\n"));
  } catch (e) {
    console.error(`[pileup] Error for ${outdir}:`, e.message);
    callback(e.message);
  }
}

module.exports = { generatePileup, SAMTOOLS };
