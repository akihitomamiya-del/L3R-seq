# Fast Storage Plan — Move Pipeline Data Off /workspace (9P)

Drafted: 2026-04-24. Follow-up to `pipeline_speed_investigation.md`,
which established that `/workspace` on 9P is the dominant cause of the
~10-20× pipeline slowdown in this devcontainer.

## TL;DR

**Source code stays on `/workspace`**; **pipeline data moves to a
Docker named volume at `/runs`.**

Goal: keep Windows-side IDE / Explorer / git tooling working against
`/workspace`, while pipeline intermediates and outputs land on native
ext4 where small-file creates don't pay 80-600× metadata penalties.

Expected gain: step 04 drops from ~22 min → ~1-2 min end-to-end.

## Design decision — surgical, not whole-workspace

| | Stays on /workspace (9P) | Moves to /runs (ext4 volume) |
|---|---|---|
| Source code (`scripts/`, `src/`, `L3Rseq` dispatcher) | ✓ | |
| Docs, configs, git metadata | ✓ | |
| Reference FASTAs, GFFs (large but read-only sequentially) | ✓ | |
| Raw input fastqs (inputs) | ✓ | |
| Pipeline intermediates (01_concat, 02_trim, 04_umi/bins/*, …) | | ✓ |
| Pipeline outputs (BAMs, TSVs, gene counts) | | ✓ |
| Final analysis artifacts you want to keep forever | copy back | generated here |

**Why not move the whole workspace off 9P?** You'd lose Windows-native
editing and `git` from Windows Explorer. The pipeline pain is
concentrated in ~20k small-file creates per step 04 run — the source
code itself is ~2 MB of .py / .sh files that don't meaningfully benefit
from being off 9P. Surgical is the better tradeoff.

## Storage options considered

| | Path | Persists across… | Windows-visible | Verdict |
|---|---|---|---|---|
| **A. Docker named volume** | `/runs` (in container) | container rebuilds, host reboots | via `docker cp` | **Chosen.** |
| B. Overlay (`/home/vscode`, `/tmp`) | `/home/vscode/runs` | restarts but NOT rebuilds | no | Too fragile for multi-day runs |
| C. WSL2 ext4 bind | `\\wsl$\Ubuntu\...` | everything | yes | More setup; requires separate WSL2 distro configured |
| D. Host-path bind to Windows NTFS | same as /workspace | same | yes | Defeats the purpose |

**A (Docker named volume)** survives rebuilds, is easy to snapshot and
destroy, and is the conventional Docker pattern for persistent data.

Volume name proposal: **`l3rseq-runs`**. Mount point: **`/runs`**
(short, clean, unambiguous — not nested under `/workspace`).

## Implementation phases

### Phase 0 — Prove it first, no config change

Before touching devcontainer config (which requires a rebuild), verify
the speedup on a one-off run by writing outputs to an overlay path:

```bash
mkdir -p /home/vscode/runs
cp -r /workspace/runs/LibCheck_takehira_test/03_demux /home/vscode/runs/phase0_test/
# re-run step 04 only, against the fast-FS output dir
time bash -c 'L3Rseq run --input /home/vscode/runs/phase0_test \
    --outdir /home/vscode/runs/phase0_test \
    --method longread-umi --threads 64 \
    --ref resources/references/MpTak_v7.1.fa --no-target-fwd \
    --start-at 4 --stop-at 4'
```

**Success criterion:** step 04 completes in ≤150 s (the prior Linux
baseline was 76 s; ≤150 s confirms we're within 2× of native). If it
takes >300 s, something other than 9P is also contributing and we
investigate *before* committing to a devcontainer change.

Cost: ~5-10 min of compute, zero config risk.

### Phase 1 — Add the Docker volume to devcontainer

Edit **all three** devcontainer configs (per CLAUDE.md they must stay
in sync):

- `.devcontainer/devcontainer.json`
- `.devcontainer/claude-code/devcontainer.json`
- `.devcontainer/build/devcontainer.json`

Add (or extend existing `mounts` array):

```json
"mounts": [
    "source=l3rseq-runs,target=/runs,type=volume"
]
```

Rebuild the container (`Dev Containers: Rebuild Container`). Verify:

```bash
df -h /runs        # expect ext4 (or overlay/fuse.docker-volume)
mount | grep /runs
touch /runs/hello && ls -la /runs/hello && rm /runs/hello
```

Failure mode to catch: if a prior run put data in `/workspace/runs` and
it's now shadowed or lost, flag immediately. Phase 1 does NOT move
existing data — Phase 2 does.

### Phase 2 — Pivot `/workspace/runs` to `/runs`

Two sub-options, pick one:

**Phase 2a (symlink, zero code change) — recommended first:**

```bash
# Stage existing runs data into the volume if we want to keep it
rsync -av /workspace/runs/ /runs/

# Replace /workspace/runs with a symlink
mv /workspace/runs /workspace/runs.old
ln -s /runs /workspace/runs

# Verify
ls -la /workspace/runs   # should show symlink → /runs
ls /workspace/runs/LibCheck_takehira_test/  # should list the migrated run
```

Existing scripts that do `--outdir runs/foo` silently become fast.
`/workspace/runs.old` kept as a safety copy; delete once confident.

Add a note in `.gitignore` if not already present (gitignore is
already an `* + !allowlist` inverted pattern; symlinks won't be
tracked because they're not on the allowlist).

**Phase 2b (explicit env var, later):**

Add `L3RSEQ_OUTPUT_ROOT=/runs` to `remoteEnv` in each devcontainer
config. Update the `L3Rseq` dispatcher so a relative `--outdir`
resolves under `$L3RSEQ_OUTPUT_ROOT` instead of `$PWD`. Document in
`L3Rseq run --help`.

Benefit of 2b: users see where data lives. Cost: dispatcher change,
`--help` update, test changes. Skip unless 2a causes confusion.

### Phase 3 — Redirect TMPDIR

Some longread_umi scripts write scratch to `$TMPDIR` (most don't —
see `pipeline_speed_investigation.md` Appendix B). Catch the ones
that do by setting `TMPDIR` in the container environment.

Option A: add to each `devcontainer.json` remoteEnv:
```json
"remoteEnv": {
    "TMPDIR": "/runs/.tmp"
}
```

Option B: create `/etc/profile.d/99-l3rseq-tmpdir.sh` with
`export TMPDIR=/runs/.tmp` and `mkdir -p $TMPDIR`. Lower priority —
the big file-create wins come from moving `runs/` itself, TMPDIR is
a mop-up.

### Phase 4 — Merge the parallel step 04 branch (already exists)

Branch `speedup-step04-parallel` is ready. On native ext4, the env var
`UMI_PARALLEL_JOBS=8` should deliver the 4-8× we couldn't hit on 9P.
Merge timing:

- After Phase 1-2 done, re-benchmark serial vs parallel on `/runs`.
- If numbers match the investigation doc's prediction, merge.
- If not, investigate before merging — same rigor as Phase 0.

## What this deliberately does NOT fix

- **Inputs still on /workspace (9P).** The 3.7× sequential read penalty
  is negligible for our pipeline pattern (each input is read once by
  step 01). If a future pipeline scans inputs repeatedly, stage them
  onto `/runs` too. Revisit if actual read-heavy workloads appear.
- **Git performance.** `.git` in `/workspace` stays slow on 9P ops. Git
  is interactive, not batch — users don't care much about 30-200 ms
  latency per op. Not a pipeline concern.
- **IGV viewer output directory discovery.** The viewer currently scans
  `/workspace` for run dirs. After the pivot, it needs to look at
  `/runs` (via the `/workspace/runs` symlink this is transparent).
  Verify the viewer still finds runs under `/workspace/runs → /runs`
  after Phase 2a; if not, update viewer dataset discovery to include
  `/runs` as a root. (Low risk — the symlink should Just Work.)
- **CI.** GitHub Actions runs on Linux runners with ext4 — this whole
  problem doesn't exist there. No CI changes needed.

## Backup and durability story

Docker volumes get **no automatic backup**. Treat `/runs` as
"fast-but-not-precious" storage:

**Snapshot recipe** (doc this in the final PR):

```bash
docker run --rm \
    -v l3rseq-runs:/data \
    -v /workspace:/out \
    ubuntu tar czf /out/backups/runs-$(date +%F).tar.gz /data
```

**For analysis outputs you want to keep forever:** copy the final
summary TSVs, important BAMs, and plots to `/workspace/analyses/`
(slow to write, fast to find later, safe in git-ignored tree but
browsable from Windows). That's the "long-term cold storage" story.
`/runs` is the "hot working set".

**If the volume gets big** (we expect tens of GB): `du -sh
/runs/*`; delete old runs with `rm -rf /runs/<old_run>` or destroy
and recreate the volume with `docker volume rm l3rseq-runs &&
docker volume create l3rseq-runs`.

## Rollback story

Every phase is independently reversible:

| Phase | To roll back |
|---|---|
| 0 | Delete `/home/vscode/runs/phase0_test`; no config touched |
| 1 | Revert devcontainer.json changes, rebuild; volume stays (can `docker volume rm l3rseq-runs` anytime) |
| 2a | `rm /workspace/runs && mv /workspace/runs.old /workspace/runs` |
| 2b | Unset env var, revert dispatcher code |
| 3 | Remove TMPDIR env var |
| 4 | Revert the branch merge (parallel step 04 is already opt-in) |

## Decision points for the user

1. **Measurement first (Phase 0) or dive to Phase 1?** — recommend
   Phase 0, 10 min total.
2. **Mount path — `/runs` or `/data` or `/workspace-fast`?** —
   recommend `/runs` (short, clean, maps to existing mental model).
3. **Phase 2a (symlink) or 2b (env var)?** — recommend 2a first.
   Move to 2b only if we find the indirection confuses people.
4. **Include parallel step-04 merge in this work (Phase 4)?** —
   recommend keep separate. One change per PR.

## Cross-references

- `docs/pipeline_speed_investigation.md` — root cause analysis and
  benchmark numbers this plan is built on.
- `docs/PIPELINE_MODERNIZATION.md` — modernization arc is complete;
  this is a post-modernization perf-only change.
- `CLAUDE.md` — "Container environment" section will need updating
  after Phase 2 to document `/runs` as the output destination.
- Branch `speedup-step04-parallel` — referenced in Phase 4.
