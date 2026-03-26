# Runs

Pipeline output directory. Each analysis run creates a subdirectory here.

Contents (not tracked by git):
- **`<experiment>/`** — pipeline output (01_concat/ through 10_csv/)
- **`reports/`** — analysis reports and comparisons
- **`figures/`** — UMI bin plots, IGV screenshots, posters

Example:
```bash
# Run the pipeline
bash examples/run_pipeline.sh    # outputs to runs/<experiment>/

# Generate bin analysis plots
python3 scripts/plot_umi_bins.py runs/<experiment>/ --quality --outdir runs/figures/

# View results
L3Rseq viewer                    # auto-discovers BAMs in runs/
```
