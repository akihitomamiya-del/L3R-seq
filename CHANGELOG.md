# Changelog

All notable changes are documented here.

## [1.0.9] - 2026-03-27

### Fixed
- 09_tail_correct.sh: variant caller used original CIGAR instead of walk-corrected CIGAR, under-counting EC for reads where minimap2 soft-clipped at or before editing sites
- 09_tail_correct.sh: matched_length (mL tag) used original alignment length instead of walk-corrected length

## [1.0.8] - 2026-03-27

### Fixed
- 09_tail_correct.sh: `set +e` leaked to caller, disabling error checking for subsequent pipeline steps
- 09c_walk_correction.sh: substring grep on variant positions caused false positive matches (e.g. position 606 matching 1606CT)
- L3Rseq: help text showed wrong default for `--method` (said umic-seq, actually longread-umi)
- UMIC-seq_fastq_v2.py: `similarity_histogram()` used wrong variable (`output_name` instead of parameter `outname`)
- UMIC-seq_fastq_v2.py: `ax1.set_xlabel()` was trapped inside a comment and never executed
- IGV viewer: `/extdata/` BAM paths resolved incorrectly in `generatePileup`
- IGV viewer: HTTP byte-range end not clamped to file size, producing incorrect headers

### Changed
- Dockerfile: replaced `git clone` with `curl+tar` for UMIC-seq (BuildKit compatibility)
- Dockerfile: purge arm64 build tools (cmake, g++, zlib1g-dev) after racon build to reduce image size
- Dockerfile: clean up `/tmp/UMIC-seq_fastq_v2.py` after install
- Dockerfile + devcontainer: removed `2>/dev/null` from `npm install` so errors are visible
- Dockerfile + devcontainer: IGV server logs to `/tmp/igv-server.log` instead of `/dev/null`
- Removed duplicate Node.js devcontainer feature (Dockerfile already installs it)

## [1.0.6] - 2026-03-27

### Changed
- CI: native arm64 GitHub Actions runner replaces QEMU emulation (~12 min vs ~30 min)
- CI: bumped all GitHub Actions to Node.js 24-compatible versions
- Added Docker Desktop requirement and Apple Silicon cross-reference to README Requirements section
- Added version field to CITATION.cff

## [1.0.5] - 2026-03-27

### Fixed
- macOS / Apple Silicon compatibility across the entire codebase
- Replaced ~40 `grep -P` (Perl regex) calls with portable `grep -E` + `sed`
- Replaced GNU-specific `sed -i`, `readlink -f`, `find -printf`, `split -d` with portable alternatives
- Replaced `zcat` with `gzip -dc` (macOS `zcat` expects `.Z` format)
- Replaced `lscpu`/`free`/`nproc`/`stat -c` with cross-platform alternatives in test scripts
- Added `curl` fallback for `wget` in `setup_blast_db.sh`
- Fixed `longread_umi.sh` symlink resolution (portable loop replacing `readlink -f`)

### Changed
- CI workflow now builds multi-arch Docker images (linux/amd64 + linux/arm64)
- Dockerfile: racon built from source on arm64 with safe `-march=armv8-a` flags (bioconda binary uses SIMD instructions unsupported by Docker Desktop virtualisation)
- Dockerfile: LoFreq install falls back to pip if bioconda arm64 build unavailable
- README: added Apple Silicon section with build instructions and performance notes

## [1.0.3] - 2026-03-26

### Changed
- Removed usearch support — vsearch is now the only clustering engine
- Removed `--engine` flag (vsearch always used)
- Moved `UMIC-seq_fastq_v2.py` from `.devcontainer/` to `UMIC-seq_L3Rseq/`
- Replaced `RPI_Barcode_20nt_Synth_Test.fasta` with full `RPI_Barcode_20nt.fasta` (36 RPIs)
- Consolidated `L3Rseq_current_state.md` and `testing_guide.md` into README
- Reorganized repo: `Ref_Docs/` → `dev/` (roadmap), `examples/` (template script), `runs/` (output)

### Added
- IGV viewer: track selector (toggle tracks on/off), group-by dropdown (SJ, EC, SC, NC, TL, strand)
- IGV viewer: position-independent TAG sort (works correctly within groups)
- `scripts/plot_umi_bins.py` — UMI bin analysis plots (single sample or method comparison)
- `examples/run_pipeline.sh` — copy-and-edit template for running the pipeline
- `runs/README.md` — user output directory with figures/ and reports/
- Real-data analysis guide in README (step-by-step for new users)
- Docker image verification in README

### Fixed
- IGV viewer: sort by SAM tag now works on all reads in all groups (not just reads at viewport center)
- Both Dockerfiles updated for moved UMIC-seq script path

## [1.0.1] - 2026-03-25

### Fixed
- GHCR username in docker-publish workflow (`akihito-mamiya-del` -> `akihitomamiya-del`)
- `--input` flag now works correctly with `--start-at` (previously ignored; required manual symlinks)
- README clone URL pointed to nonexistent `L3Rseq.git` instead of `L3R-seq.git`
- `L3Rseq --version` now prints 1.0.1 (was stuck at 1.0.0)
- IGV viewer: reference auto-detection now works when serving BAMs from Docker data mounts (`/extdata/` route)
- IGV viewer: dataset label no longer empty when `IGV_DATA_DIR` root contains pipeline output

### Changed
- Test suite no longer creates manual symlinks; relies on the `--start-at` fix in L3Rseq
- Moved test data generators to `tests/generators/`
- Removed dead quality report function, fixed stale Dockerfile comments
- README: added Docker usage example for the IGV viewer

## [1.0.0] - 2026-03-25

### Added
- 10-step pipeline as subcommands of `L3Rseq` dispatcher
- UMI methods: longread-umi (default, vsearch) and UMIC-seq (`--method umic-seq`)
- RNA editing quantification (`--pattern CT`, configurable for AG, etc.)
- CIGAR-walk 3' tail correction (step 09, split into 09a-09e subscripts)
- BLAST filtering for chimeric artifact detection and translocation flagging
- Secondary count-only pattern (`--count-pattern TC` for SLAM-seq)
- Splicing support (`--introns` flag or `discover-introns` subcommand)
- Per-read noise count (NC tag) separating biological editing from residual errors
- Quality report per sample (Q scores, indel breakdown, noise types, splicing efficiency)
- CSV export with 20-24 columns depending on features used
- IGV.js alignment viewer with sort-by-tag and color-by-tag controls (46 Puppeteer tests)
- Synthetic test suite (109 checks, fully self-contained)
- Docker distribution via GHCR (`ghcr.io/akihitomamiya-del/l3rseq:latest`)
- `l3rseq-docker` convenience wrapper with bind-mount data I/O
- `docker-compose.yml` with `.env.example` (EDIT_ME guards)
- GitHub Actions workflow for Docker image publish on version tags
- GitHub Codespaces support with pre-configured devcontainer
