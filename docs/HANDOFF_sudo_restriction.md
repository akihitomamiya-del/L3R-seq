# Handoff — Restricting `vscode` sudo in the claude-code devcontainer

**Status:** Fix **committed** on branch `fix/restrict-vscode-sudo` (base
`57ca874`), **not yet active** (activates on the next *local* devcontainer
rebuild — no image rebuild/push needed; see §3.5). Scoped to the `claude-code`
devcontainer only.

**Base commit:** `57ca874` (`main`). The three functional changes below were
committed to branch `fix/restrict-vscode-sudo` (this doc committed alongside
them).

**Author of investigation/fix:** Claude (Opus 4.8), 2026-06-25.

---

## 0. How to review this (pick your context)

**If you are INSIDE the running container** — you can see live state. Until a
rebuild happens you will still observe the *old* (broken) state, which is itself
the evidence. Run the probes in §2.1 and §5.1.

**If you are OUTSIDE (reviewing the repo / a branch / a PR)** — you cannot run
runtime probes. Review the diff (§3), the logic, and the static checks in §5.2.
Everything needed to judge correctness is embedded in this document.

---

## 1. The problem

The `claude-code` devcontainer ships a network firewall (`init-firewall.sh`,
default-deny egress, allowlist = GitHub/npm/Anthropic) so that Claude Code can
be run with `--dangerously-skip-permissions` relatively safely. The firewall's
integrity depends on the container's agent **not** being able to flush it.

The intended model (copied from upstream `anthropics/claude-code`) is
**firewall-only sudo**: the non-root user may run the firewall script as root and
nothing else. In reality the `vscode` user has **full passwordless sudo**
(`NOPASSWD:ALL`), so any code running as `vscode` (the agent, an npm postinstall
script, a parser RCE on untrusted input) can run `sudo iptables -F` and defeat
the firewall entirely. The egress sandbox is therefore **bypassable**.

---

## 2. Investigation findings

### 2.1 Current runtime state (the smoking gun)

`sudo -n -l` as `vscode` returns **two** grants — the blanket one wins:

```
User vscode may run the following commands:
    (root) NOPASSWD: ALL                                                  <-- full root
    (root) NOPASSWD: /usr/local/bin/init-firewall.sh, .../start-firewall.sh
```

They come from two files in `/etc/sudoers.d/` (sudo unions all files there):

| File | Contents | mtime | Origin |
|---|---|---|---|
| `/etc/sudoers.d/vscode` | `vscode ALL=(root) NOPASSWD:ALL` | **2025-10-16** | base image layer (NOT any repo file) |
| `/etc/sudoers.d/vscode-firewall` | restricted to the 2 firewall scripts | build time | `claude-code/Dockerfile` |

The `2025-10-16` mtime predates the container build — proof it is inherited from
an image layer, not written by this repo.

### 2.2 Root cause

The base-image chain is:

```
.devcontainer/claude-code/Dockerfile:7   FROM ghcr.io/akihitomamiya-del/l3rseq:latest
.devcontainer/build/Dockerfile:1         FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04
```

Microsoft's `devcontainers/base` image (via its `common-utils` layer) creates the
`vscode` user **with `/etc/sudoers.d/vscode` = `vscode ALL=(root) NOPASSWD:ALL`**.
This repo never removes that file. The repo's own restricted `vscode-firewall`
entry is an *additional* file, so it grants the firewall scripts but does **not**
revoke the blanket grant. Net effect: full sudo.

### 2.3 History — it never worked (no regression)

- `da7b540` (v1.0.3, first devcontainer) — already `FROM mcr…/base`, `USER vscode`.
  Blanket-sudo `vscode` present from day one.
- **`9c5c76c` (2026-03-27)** — first & only commit to add restricted sudo
  (`/etc/sudoers.d/vscode-firewall`). Shadowed from the moment it landed.
- `e5cbe18` (2026-03-27) — extended the restricted entry to two firewall scripts.
- Pickaxe across all history: no `ALL=(ALL)`, no `common-utils`, no `node` user,
  no commit ever removed the blanket grant.

**Conclusion: "never effectively established," not "broke."** There is no
regression commit; the restriction has been cosmetic since the firewall was
introduced, because the base image always out-granted it.

### 2.4 Upstream reference (`anthropics/claude-code`, what we were copying)

Read at commit `0bd9543` (2026-06-24):

- `remoteUser: node`
- `FROM node:20` — a plain Node image; the `node` user has **no sudo by default**.
- `RUN echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" >
  /etc/sudoers.d/node-firewall && chmod 0440 ...`
- Firewall via `postStartCommand: "sudo /usr/local/bin/init-firewall.sh"`.

The load-bearing half is the **plain base image with no pre-granted sudo**. This
repo adopted the restricted-sudoers *pattern* but onto Microsoft's `vscode` user,
which already carries blanket sudo — so the pattern had no teeth.

---

## 3. The fix (claude-code config only)

Three changes. Principle: drop the inherited blanket grant, and keep the two
runtime `sudo` needs working through a **narrow allowlist of fixed scripts**.

### 3.1 New file — `.devcontainer/claude-code/fix-runs-perms.sh`

The `/runs` Docker volume mounts root-owned; `vscode` can't write to it until
chowned once at creation. Previously done with `sudo chown -R vscode:vscode /runs`
— which only worked *because* of blanket sudo. Re-homed into a wrapper that
hardcodes `/runs`, so the sudo grant for it is **not** an escalation primitive
(unlike whitelisting bare `sudo chown`, which could chown arbitrary root files):

```bash
#!/bin/bash
# Hand the vscode user ownership of the /runs volume (mounts root-owned).
set -euo pipefail
RUNS_DIR="/runs"
mkdir -p "$RUNS_DIR"
chown -R vscode:vscode "$RUNS_DIR"
```

### 3.2 `.devcontainer/claude-code/Dockerfile`

```diff
-# Firewall scripts + passwordless sudo
-COPY .../init-firewall.sh .../start-firewall.sh .../firewall-warning.sh /usr/local/bin/
-RUN chmod +x .../init-firewall.sh .../start-firewall.sh .../firewall-warning.sh && \
-    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/start-firewall.sh" > /etc/sudoers.d/vscode-firewall && \
+# Privileged helper scripts + RESTRICTED sudo. (full rationale in comment)
+COPY .../init-firewall.sh .../start-firewall.sh .../firewall-warning.sh .../fix-runs-perms.sh /usr/local/bin/
+RUN chmod +x .../init-firewall.sh .../start-firewall.sh .../firewall-warning.sh .../fix-runs-perms.sh && \
+    rm -f /etc/sudoers.d/vscode && \
+    echo "vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/start-firewall.sh, /usr/local/bin/fix-runs-perms.sh" > /etc/sudoers.d/vscode-firewall && \
     chmod 0440 /etc/sudoers.d/vscode-firewall
```

This RUN executes while the Dockerfile is `USER root` (set at line 12, switched to
`USER vscode` at line 67), so `rm` and the sudoers write are permitted.

### 3.3 `.devcontainer/claude-code/devcontainer.json`

```diff
-  "postCreateCommand": "... && sudo chown -R vscode:vscode /runs && mkdir -p /runs/.tmp && ...",
+  "postCreateCommand": "... && sudo /usr/local/bin/fix-runs-perms.sh && mkdir -p /runs/.tmp && ...",
```

The firewall `postStartCommand` (`sudo /usr/local/bin/start-firewall.sh`) is
unchanged and still permitted by the restricted entry.

### 3.4 Why these are the only changes needed

`git grep -w sudo` shows the claude-code container's only runtime `sudo` uses are
(a) the `/runs` chown [re-homed] and (b) the firewall start [still allowed].
Everything else returned by the grep is a different config (`build/`, root
`devcontainer.json`), a CI runner (`.github/workflows/test.yml`), or printed hint
strings (`firewall-warning.sh:15`, `tests/run_tests.sh:173`) — not executed sudo.

### 3.5 No new base image required — local rebuild only

These edits live in `.devcontainer/claude-code/Dockerfile`, which is built
**locally** by the Dev Containers extension (`FROM ghcr.io/.../l3rseq:latest`)
on every *Rebuild Container*. `rm -f /etc/sudoers.d/vscode` is a Docker layer
whiteout: it hides the base image's file in the final container **regardless of
what the base ships**, so no base rebuild/republish is needed to activate this
fix. Contrast §5, which *does* require a tagged release because it edits the
**published** `build/Dockerfile`. The `CLAUDE.md` rule "Dockerfile changes
require a tagged release" is scoped to that base Dockerfile (package installs
needing registries the firewall blocks at runtime) — not to this local layer.

**Caveat (the one way the whiteout can be undone):** a devcontainer *feature*
runs as a layer **after** the Dockerfile build, so a user-provisioning feature
could re-create `/etc/sudoers.d/vscode` after the `rm`. The only feature in
`claude-code/devcontainer.json` is `github-cli`, which does not touch
`/etc/sudoers.d/`. The feature that creates the blanket grant is `common-utils`,
which is **not** used here. The §4.1 `sudo -n true` probe (must be denied) is
what catches a regression if a future feature reintroduces it.

---

## 4. Verification

### 4.1 Inside the container, AFTER `Dev Containers: Rebuild Container`

```bash
sudo -n -l            # MUST list only the 3 scripts — no "(root) NOPASSWD: ALL"
ls /etc/sudoers.d/    # 'vscode' file GONE; only 'vscode-firewall' (+ README)
sudo -n true          # MUST be denied  -> blanket sudo removed
sudo iptables -F      # MUST be denied  -> firewall now tamper-resistant
ls -ld /runs          # vscode-owned    -> fix-runs-perms.sh ran in postCreate
sudo /usr/local/bin/start-firewall.sh   # MUST still succeed (firewall re-applies)
```

Expected: the firewall (`postStartCommand`) and `/runs` ownership both still work;
arbitrary `sudo` is denied. NOTE: the agent itself loses ad-hoc sudo after this —
that is the intended effect.

### 4.2 Outside the container (static review)

- Confirm `.devcontainer/claude-code/Dockerfile` contains `rm -f /etc/sudoers.d/vscode`
  in a `RUN` that executes under `USER root`.
- Confirm the sudoers allowlist names exactly the 3 scripts and `chmod 0440`.
- Confirm `fix-runs-perms.sh` only ever touches `/runs` (no argument passthrough).
- Validate the sudoers line: `printf '<line>\n' > /tmp/x && visudo -cf /tmp/x`
  (already done → "parsed OK").
- Confirm `postCreateCommand` no longer contains `sudo chown` and instead calls
  the wrapper.

---

## 5. Remaining rollout (NOT done — optional, needs a republished base image)

The `build/Dockerfile` (the published `l3rseq` base) and the root
`devcontainer.json` (plain Codespaces) **still inherit blanket sudo**. Neither
runs a firewall, so this is pure defense-in-depth, not a hole.

⚠️ **Dependency gotcha:** if you add `rm -f /etc/sudoers.d/vscode` to
`build/Dockerfile`, then the root/default **and** `build` configs lose sudo too,
and their `postCreateCommand` `sudo chown -R vscode:vscode /runs` will **break**.
A base-image rollout must therefore *also* re-home those two chowns (ship
`fix-runs-perms.sh` in the base + a sudoers entry, or fix `/runs` ownership
another way) in the same release. Do not naively `rm` in the base image alone.

### 5.1 How to publish a new ghcr image (the rollout mechanism)

Publishing is **CI-driven by version tags** (`.github/workflows/docker-publish.yml`,
trigger `push: tags: ['v*']`). It builds `linux/amd64` + `linux/arm64` from
`.devcontainer/build/Dockerfile`, pushes by digest, merges a multi-arch manifest
tagged `:<tag>` **and** `:latest`, then runs the quick test suite against it. Uses
the automatic `GITHUB_TOKEN` (`packages: write`) — no manual PAT needed.

Latest tag at time of writing: `v1.2.1` → next would be **`v1.2.2`** (patch; a
Dockerfile change).

```bash
# 0. (recommended) test the Dockerfile change locally first via the `build`
#    devcontainer config — reopen in the .devcontainer/build/ container, or:
#    docker build -f .devcontainer/build/Dockerfile -t l3rseq:test .

# 1. edit .devcontainer/build/Dockerfile (+ re-home its chown per §5 gotcha),
#    commit on a branch, merge to main.
git add .devcontainer/build/Dockerfile .devcontainer/build/devcontainer.json
git commit -m "..."

# 2. tag and push the tag — THIS is what triggers the publish workflow
git fetch --tags
git tag v1.2.2
git push origin v1.2.2

# 3. watch CI (~20 min, builds both arches):
gh run watch    # or: gh run list --workflow=docker-publish.yml

# 4. once green, :latest and :v1.2.2 point at the new image. Rebuild the
#    devcontainer to pull it (Dev Containers: Rebuild Container, or
#    `docker pull ghcr.io/akihitomamiya-del/l3rseq:latest`).
```

Manual/host fallback (only if not using CI — e.g. private testing). Must run on a
host with Docker; the devcontainer has no docker-in-docker and the firewall blocks
most registries:

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u akihitomamiya-del --password-stdin
docker buildx build --platform linux/amd64,linux/arm64 \
  -f .devcontainer/build/Dockerfile \
  -t ghcr.io/akihitomamiya-del/l3rseq:v1.2.2 \
  -t ghcr.io/akihitomamiya-del/l3rseq:latest --push .
```

---

## 6. Threat model — what the fix buys, and what it does not

**Gains:** the firewall stops being theater (egress allowlist actually holds —
matters most under auto-approve/YOLO mode or untrusted inputs/deps); non-root
blast-radius confinement; behavior matches the documented sandbox design; aligns
with upstream.

**Costs:** loses ad-hoc `sudo` convenience (notably fixing perms on root-owned
mounts); requires the `/runs` chown re-homing; harder to hand-debug the firewall;
a scoped chown grant is a mild escalation primitive if made too broad (hence the
hardcoded-`/runs` wrapper).

**Does NOT change:** project files and `/runs` are already `vscode`-owned and the
agent *is* `vscode`, so this does nothing to stop a rogue agent from
reading/corrupting your data. It protects network egress, system integrity, and
persistence — not your working files. And it is risk-reduction, not airtight: DNS
exfiltration over the allowed UDP 53, capability abuse, and container escape
remain out of scope.

---

## 7. References

- Live evidence: `sudo -n -l`, `/etc/sudoers.d/{vscode,vscode-firewall}` (§2.1).
- Repo: `.devcontainer/claude-code/{Dockerfile,devcontainer.json,fix-runs-perms.sh,
  init-firewall.sh,start-firewall.sh,firewall-warning.sh}`,
  `.devcontainer/build/Dockerfile`, `.devcontainer/devcontainer.json`,
  `.github/workflows/docker-publish.yml`.
- History commits: `da7b540`, `9c5c76c`, `e5cbe18`.
- Upstream: `github.com/anthropics/claude-code` `.devcontainer/` @ `0bd9543`.
- Memory note: `~/.claude/.../memory/vscode-sudo-not-restricted.md`.

## 8. Open decisions for the reviewer

1. ~~Commit these three changes to `fix/restrict-vscode-sudo`~~ **done** — now
   rebuild locally (*Dev Containers: Rebuild Container*) to activate, then run
   the §4.1 probes.
2. Do the §5 base-image rollout (`v1.2.2`) for defense-in-depth on the other two
   configs, accepting the chown re-homing work? Or leave them (no firewall there)?
