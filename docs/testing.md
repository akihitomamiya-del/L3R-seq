[README](../README.md) | [Advanced](advanced.md) | **Testing** | [Development](development.md) | [Requirements](requirements.md)

---

# Testing

## Synthetic test suite

```bash
bash tests/run_tests.sh                    # full suite (156 checks, ~45s)
bash tests/run_tests.sh --skip-preprocess  # steps 04-10 only (~30s)
bash tests/run_tests.sh --quick            # smoke test (~15s)
bash tests/run_tests.sh --no-viewer        # skip IGV viewer after tests
```

All tests use synthetic data with a 1.5kbp `test_gene` reference — no external data needed. Each sample has a distinct editing pattern (CT, AG, CT+AG, TC+SLAM) to test single and dual-pattern counting.

| Test | Steps | What it checks |
|---|---|---|
| Test 1 | 01-03 | Concat, trim, demux — read counts per barcode/RPI |
| Test 1b | filter | Optional filter step removes non-mapping reads |
| Test 1c | — | Error handling: missing --ref, bad --rpi-fasta, UMIC-seq without --probe |
| Test 2 | 04-10 | Full CT pipeline: UMI bins, consensus identity (>=99%), mapping, EC/NC tags, CSV |
| Test 2b | 08-10 | Dual-pattern `--pattern CT,AG`: EC counts increase for AG-containing samples |
| Test 3 | 09-10 | SLAM-seq: exact EC=96, SC=590, NC=101 on 40 synthetic reads |
| Test 4 | 09-10 | Splicing: SJ/SI/IR tags, splice pattern counts, intron discovery |
| Test 5 | 09-10 | BLAST: walk correction CIGARs, ChrM translocation, cDNA chimera filtering |
| Test 6 | — | IGV viewer API: datasets, tracks, pileup output, IGV.js patches |
| Test 7 | — | Plot generation: analysis conda env, plot_umi_bins.py |
| Test 8 | regions, count | Gene counting: regions from coordinates/BED, molecule counting, BED equivalence, housekeeping normalization |

## Docker image verification

**Run from the host machine only** (not inside a container):

```bash
bash tests/test_docker_image.sh                    # build + test
bash tests/test_docker_image.sh --skip-build       # test existing image
bash tests/test_docker_image.sh --image ghcr.io/akihitomamiya-del/l3rseq:latest
```

These require Docker on the host. They build/pull the image and run the test suite inside a fresh container.

## Shell function unit tests

Standalone tests for CIGAR parsing, splice checking, and BLAST helper functions:

```bash
bash tests/test_shell_functions.sh
```

## Regenerating test data

Generators in `tests/generators/` produce all synthetic data:

```bash
python3 tests/generators/generate_synthetic_data.py    # main pipeline data
python3 tests/generators/generate_blast_test_data.py   # BLAST + walk correction
python3 tests/generators/generate_slam_test_data.py    # SLAM-seq fixtures
python3 tests/generators/generate_splice_test_data.py  # splice fixtures
python3 tests/generators/generate_demo_data.py tests/output/demo  # IGV demo
```

---

[README](../README.md) | [Advanced](advanced.md) | **Testing** | [Development](development.md) | [Requirements](requirements.md)
