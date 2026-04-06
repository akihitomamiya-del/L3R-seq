// Pipeline output data parsing: UMI stats, gene counts, coverage.
const fs = require("fs");
const path = require("path");
const { readdirSafe, isDirSafe, naturalCompare } = require("./helpers");

/**
 * @typedef {Object} UmiSample
 * @property {string} id - "barcode/rpi"
 * @property {string} barcode - Barcode name
 * @property {string} rpi - RPI name
 * @property {Object} stats - Metric name → value map
 * @property {Object} size_dist - Cluster size → count map
 *
 * @typedef {Object} UmiStatsResult
 * @property {UmiSample[]} samples
 *
 * @typedef {Object} GeneCountRow
 * @property {string} gene
 * @property {string} sample
 * @property {number} total_count
 * @property {string} splice_pattern
 * @property {number} pattern_count
 *
 * @typedef {Object} IsoformRow
 * @property {string} barcode
 * @property {string} gene
 * @property {string} splice_pattern
 * @property {number} pooled_count
 * @property {number} n_samples
 * @property {string} samples_with_pattern
 * @property {string} pct_of_gene
 *
 * @typedef {Object} NormalizedRow
 * @property {string} gene
 * @property {string} sample
 * @property {string} level
 * @property {string} splice_pattern
 * @property {number} count
 * @property {string} hk_gene
 * @property {number} hk_count
 * @property {number|null} ratio
 *
 * @typedef {Object} GeneInfo
 * @property {string} chr
 * @property {number} start
 * @property {number} end
 *
 * @typedef {Object} GeneCountsResult
 * @property {boolean} hasData
 * @property {string[]} genes
 * @property {string[]} samples
 * @property {GeneCountRow[]} counts
 * @property {IsoformRow[]} isoforms
 * @property {NormalizedRow[]} normalized
 * @property {Object.<string, GeneInfo>} geneInfo
 */

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

/** @returns {UmiStatsResult} */
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
      for (const row of parseTsv(path.join(rbDir, "umi_cluster_stats.tsv"))) {
        const v = row.value;
        sample.stats[row.metric] = isNaN(Number(v)) ? v : Number(v);
      }
      for (const row of parseTsv(path.join(rbDir, "umi_cluster_size_dist.tsv"))) {
        sample.size_dist[row.cluster_size] = Number(row.count);
      }
      result.samples.push(sample);
    }
  }
  return result;
}

/** @returns {GeneCountsResult} */
function discoverGeneCounts(outdir) {
  const countDir = path.join(outdir, "11_count");
  const result = { hasData: false, genes: [], samples: [], counts: [], isoforms: [], normalized: [] };

  if (!isDirSafe(countDir)) return result;

  const allFile = path.join(countDir, "gene_counts_all.tsv");
  const allRows = parseTsv(allFile);
  if (allRows.length === 0) return result;

  result.hasData = true;
  result.counts = allRows.map(r => ({
    gene: r.gene, sample: r.sample,
    total_count: Number(r.total_count),
    splice_pattern: r.splice_pattern,
    pattern_count: Number(r.pattern_count),
  }));

  result.genes = [...new Set(allRows.map(r => r.gene))].sort();
  result.samples = [...new Set(allRows.map(r => r.sample))].sort(naturalCompare);

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

  const isoFile = path.join(countDir, "isoform_discovery.tsv");
  result.isoforms = parseTsv(isoFile).map(r => ({
    barcode: r.barcode || "", gene: r.gene,
    splice_pattern: r.splice_pattern,
    pooled_count: Number(r.pooled_count),
    n_samples: Number(r.n_samples),
    samples_with_pattern: r.samples_with_pattern,
    pct_of_gene: r.pct_of_gene,
  }));

  const normFile = path.join(countDir, "gene_counts_normalized.tsv");
  result.normalized = parseTsv(normFile).map(r => ({
    gene: r.gene, sample: r.sample, level: r.level,
    splice_pattern: r.splice_pattern,
    count: Number(r.count),
    hk_gene: r.hk_gene, hk_count: Number(r.hk_count),
    ratio: r.ratio === "NA" ? null : Number(r.ratio),
  }));

  return result;
}

function readCoverageFile(filePath) {
  try {
    const lines = fs.readFileSync(filePath, "utf8").trim().split("\n");
    const positions = [], depths = [];
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

module.exports = { parseTsv, discoverUmiStats, discoverGeneCounts, readCoverageFile };
