# IGV Viewer API Reference

The L3Rseq viewer server exposes a JSON API for programmatic access to pipeline
output. The server runs on port 8080 by default (override with `IGV_PORT`).

Base URL: `http://localhost:8080`

---

## GET /healthz

Health check endpoint.

**Response** (200):
```json
{
  "status": "ok",
  "uptime": 123.456
}
```

**Example**:
```bash
curl http://localhost:8080/healthz
```

---

## GET /api/datasets

List all discovered pipeline output datasets. Scans for directories containing
`07_map/` or `09_correct/` subdirectories. Internal test outputs are hidden.

**Query params**: none

**Response** (200):
```json
{
  "references": [
    {
      "id": "test_gene",
      "name": "test_gene",
      "fastaURL": "/ref/test_gene.fasta",
      "indexURL": "/ref/test_gene.fasta.fai"
    }
  ],
  "datasets": ["demo", "blast", "splice"],
  "datasetInfo": [
    {
      "name": "demo",
      "description": "Demo dataset for testing"
    }
  ]
}
```

Fields:
- `references` -- FASTA references used by discovered datasets (filtered to only those whose sequences match BAM headers).
- `datasets` -- sorted list of dataset names. Featured datasets (demo, blast, splice, SLAM) appear first.
- `datasetInfo` -- name and optional description (from `description.txt` in the dataset directory) for each dataset.

**Example**:
```bash
curl http://localhost:8080/api/datasets
```

---

## GET /api/tracks

Load BAM tracks for a specific dataset. Discovers `.sort.bam` files under
`07_map/` and `09_correct/` subdirectories, filtering out empty BAMs via BAI
index inspection.

**Query params**:
| Param  | Required | Description             |
|--------|----------|-------------------------|
| `name` | yes      | Dataset name from `/api/datasets` |

**Response** (200):
```json
{
  "tracks": [
    {
      "name": "barcode01/RPI_1 -- mapping (step 07)",
      "url": "/data/tests/output/demo/07_map/barcode01/RPI_1/barcode01_RPI_1_primary.sort.bam",
      "indexURL": "/data/tests/output/demo/07_map/barcode01/RPI_1/barcode01_RPI_1_primary.sort.bam.bai",
      "format": "bam",
      "type": "alignment",
      "color": "#b0b0b0",
      "height": 250,
      "displayMode": "SQUISHED",
      "showSoftClips": true
    }
  ],
  "refName": "test_gene",
  "description": "Demo dataset"
}
```

Fields:
- `tracks` -- array of IGV.js-compatible track objects. Each has `name`, `url`, `indexURL`, `format`, `type`, `color`, `height`, `displayMode`, `showSoftClips`. Hidden tracks include `hidden: true`.
- `refName` -- reference sequence name from the first BAM header (`@SQ SN:` field).
- `description` -- dataset description if `description.txt` exists.

**Error responses**: 400 (missing `name`), 404 (dataset or BAMs not found).

**Example**:
```bash
curl 'http://localhost:8080/api/tracks?name=demo'
```

---

## GET /api/pileup

Text-based pileup view for CLI or programmatic inspection. Uses samtools to
generate a formatted alignment view of a genomic region.

**Query params**:
| Param    | Required | Default | Description                        |
|----------|----------|---------|------------------------------------|
| `name`   | yes      |         | Dataset name                       |
| `region` | no       | `""`    | Genomic region (e.g., `ref:100-200`) |
| `width`  | no       | `120`   | Column width for formatting        |

**Response** (200): `text/plain` -- formatted pileup text.

**Error responses**: 400 (missing `name`), 404 (dataset not found), 500 (samtools error).

**Example**:
```bash
curl 'http://localhost:8080/api/pileup?name=demo&region=test_gene:100-200&width=80'
```

---

## GET /api/umi-stats

UMI bin size statistics from step 04 output. Reads TSV files from
`04_umi/{barcode}/{rpi}/read_binning/` directories.

**Query params**:
| Param  | Required | Description  |
|--------|----------|--------------|
| `name` | yes      | Dataset name |

**Response** (200):
```json
{
  "dataset": "demo",
  "samples": [
    {
      "id": "barcode01/RPI_1",
      "barcode": "barcode01",
      "rpi": "RPI_1",
      "stats": {
        "total_reads": 100,
        "total_bins": 20,
        "kept_bins": 15
      },
      "size_dist": {
        "1": 5,
        "2": 3,
        "3": 8,
        "5": 4
      }
    }
  ]
}
```

Fields:
- `dataset` -- echoed dataset name.
- `samples[].id` -- `barcode/rpi` identifier.
- `samples[].stats` -- key-value metrics from `umi_cluster_stats.tsv` (numeric values auto-parsed).
- `samples[].size_dist` -- cluster size distribution from `umi_cluster_size_dist.tsv` (cluster_size -> count).

**Error responses**: 400 (missing `name`), 404 (dataset not found).

**Example**:
```bash
curl 'http://localhost:8080/api/umi-stats?name=demo'
```

---

## GET /api/gene-counts

Gene-level read counts from step 11 output. Parses `gene_counts_all.tsv`,
per-sample count files, `isoform_discovery.tsv`, and `gene_counts_normalized.tsv`.

**Query params**:
| Param  | Required | Description  |
|--------|----------|--------------|
| `name` | yes      | Dataset name |

**Response** (200):
```json
{
  "dataset": "demo",
  "hasData": true,
  "genes": ["geneA", "geneB"],
  "samples": ["barcode01/RPI_1", "barcode01/RPI_2"],
  "counts": [
    {
      "gene": "geneA",
      "sample": "barcode01/RPI_1",
      "total_count": 42,
      "splice_pattern": "unspliced",
      "pattern_count": 42
    }
  ],
  "geneInfo": {
    "geneA": { "chr": "chr1", "start": 100, "end": 500 }
  },
  "isoforms": [
    {
      "barcode": "barcode01",
      "gene": "geneA",
      "splice_pattern": "unspliced",
      "pooled_count": 84,
      "n_samples": 2,
      "samples_with_pattern": "RPI_1,RPI_2",
      "pct_of_gene": "100.0"
    }
  ],
  "normalized": [
    {
      "gene": "geneA",
      "sample": "barcode01/RPI_1",
      "level": "gene",
      "splice_pattern": "unspliced",
      "count": 42,
      "hk_gene": "hkGene",
      "hk_count": 10,
      "ratio": 4.2
    }
  ]
}
```

Fields:
- `hasData` -- false if no `11_count/` directory or empty `gene_counts_all.tsv`.
- `genes`, `samples` -- sorted unique lists.
- `counts` -- per-gene, per-sample, per-splice-pattern counts.
- `geneInfo` -- genomic coordinates from per-sample count files (`chr`, `start`, `end`).
- `isoforms` -- pooled isoform discovery data (per barcode).
- `normalized` -- housekeeping-normalized ratios (empty if no normalization was run). `ratio` is `null` when the value is `NA`.

**Error responses**: 400 (missing `name`), 404 (dataset not found).

**Example**:
```bash
curl 'http://localhost:8080/api/gene-counts?name=demo'
```

---

## GET /api/gene-coverage

Per-base coverage depth for a specific gene and sample. Reads from
`11_count/coverage/{barcode}_{rpi}_{gene}.depth.tsv`.

**Query params**:
| Param    | Required | Description                           |
|----------|----------|---------------------------------------|
| `name`   | yes      | Dataset name                          |
| `gene`   | yes      | Gene name                             |
| `sample` | yes      | Sample ID in `barcode/rpi` format     |

**Response** (200):
```json
{
  "gene": "geneA",
  "sample": "barcode01/RPI_1",
  "positions": [1, 2, 3, 4, 5],
  "depths": [10, 12, 15, 14, 11]
}
```

Fields:
- `positions` -- 1-based genomic positions (column 2 of the depth TSV).
- `depths` -- read depth at each position (column 3 of the depth TSV).

**Error responses**: 400 (missing any required param), 404 (dataset not found).

**Example**:
```bash
curl 'http://localhost:8080/api/gene-coverage?name=demo&gene=geneA&sample=barcode01/RPI_1'
```

---

## GET /api/viewer-state

Viewer state summary for a dataset. Reports which viewer features and buttons
are relevant based on the available tracks and SAM tags. Primarily used for
automated testing.

**Query params**:
| Param  | Required | Description  |
|--------|----------|--------------|
| `name` | yes      | Dataset name |

**Response** (200):
```json
{
  "dataset": "demo",
  "reference": "test_gene",
  "tracks": 4,
  "features": {
    "has_step07_and_09": true,
    "has_chimeric_track": false,
    "has_raw_bin": false,
    "has_consensus": false
  },
  "buttons": {
    "display_mode": "Always available (SQUISHED/EXPANDED)",
    "show_all_reads": "Always available (disables downsampling)",
    "show_soft_clips": "Always available (on by default)",
    "show_mismatches": "Always available (on by default)"
  },
  "sorting_tips": [
    "Sort by EC tag: groups reads by editing count",
    "Sort by SJ tag: groups spliced (S) vs retained (R) vs unspanned (-)"
  ]
}
```

Fields:
- `features` -- boolean flags for which pipeline steps produced tracks.
- `buttons` -- descriptions of always-available viewer controls.
- `sorting_tips` -- suggested sort-by-tag options based on SAM tags found in the corrected BAM (EC, SC, SJ, TL, NC).

**Error responses**: 400 (missing `name`), 404 (dataset or BAMs not found).

**Example**:
```bash
curl 'http://localhost:8080/api/viewer-state?name=demo'
```
