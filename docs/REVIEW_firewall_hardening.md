# Review Guide — Firewall hardening follow-up (`claude-code` devcontainer)

**What this covers:** the *second* commit on branch `fix/restrict-vscode-sudo`,
which hardens the firewall **scripts** after the first commit (`e1a28f1`)
restricted `vscode`'s sudo. The first commit is reviewed by
[`HANDOFF_sudo_restriction.md`](HANDOFF_sudo_restriction.md) §4; this guide is
for the follow-up.

**Author:** Claude (Opus 4.8), 2026-06-25. Verified by a post-rebuild runtime
audit + two independent adversarial reviews of the diff (all four findings
returned CLOSED, no new vulnerabilities).

**Scope:** `.devcontainer/claude-code/{Dockerfile,init-firewall.sh,start-firewall.sh,firewall-warning.sh}`
plus doc updates (`docs/auth.md`, `HANDOFF_sudo_restriction.md`). No base-image
rebuild/tag needed — all edits are in the locally-built `claude-code` layer
(activates on the next *Dev Containers: Rebuild Container*).

---

## 1. What changed and why

The post-rebuild audit confirmed the sudo restriction is active, then found the
*allowed scripts themselves* carried residual weaknesses — pre-existing, but now
**load-bearing** because they are the only root entrypoints `vscode` can reach.

| # | Sev | Finding | Fix | Files |
|---|-----|---------|-----|-------|
| 1 | HIGH | `init-firewall.sh` is an **on-demand fail-open**: it resets policies to ACCEPT + flushes *before* rebuilding the allowlist, re-DROPs only at the end, with no rollback. An abort (failed fetch/resolve, or a raced 2nd run hitting the non-idempotent `ipset create`) left egress **open** — and `vscode` could trigger it via the allowlisted `sudo init-firewall.sh`. | (a) **Dropped `init-firewall.sh` from the sudoers allowlist** (now only `start-firewall.sh` + `fix-runs-perms.sh`); it's still run *internally as root* by `start-firewall.sh`, so startup is unaffected. (b) Added an **`EXIT` trap** that forces default-DROP unless the script reaches `_FW_COMPLETED=1` after verification. | `init-firewall.sh`, `Dockerfile` |
| 2 | MED | **`/tmp` symlink TOCTOU**: `start-firewall.sh` wrote `/tmp/firewall-{status,init.log}` and `chmod`'d as root. `/tmp` is world-writable+sticky, so a malicious `postCreate` npm script (runs as `vscode` *before* the postStart firewall) could pre-plant symlinks → root arbitrary-write / arbitrary-chmod + forge the banner. | Moved state to **`/run/firewall/`** (root-owned `0755`, not world-writable — `vscode` cannot pre-plant there). | `start-firewall.sh`, `firewall-warning.sh`, `auth.md` |
| 3 | LOW | Image script copies were **`0775` (group-writable)**. Not exploitable today (`vscode` ∉ `root` group) but a needless latent foot-gun. | Dockerfile **`chmod 0755`** (was `chmod +x`). | `Dockerfile` |
| 4 | LOW | Scripts call tools by bare name, relying on the sudoers **`secure_path`** Default. | Added explicit **`export PATH`** (mirrors `secure_path` exactly, incl. `/snap/bin`). | `init-firewall.sh`, `start-firewall.sh` |

**Behavioral change to know:** the firewall now fails **closed**. Previously a
failed init left egress *open* (with a warning banner); now `init-firewall.sh`'s
trap leaves default-DROP, and `start-firewall.sh`/the banner say "egress is
BLOCKED (fail-closed)". DNS/SSH/loopback rules added before any abort survive, so
the box stays reachable for recovery (shell is via `docker exec`, not egress).

---

## 2. Static review (no rebuild required)

### 2.1 Read the diff
```bash
git -C /workspace log --oneline -2 fix/restrict-vscode-sudo   # find the follow-up hash
git -C /workspace show <follow-up-hash>                        # or:
git -C /workspace diff e1a28f1 -- .devcontainer/claude-code docs
```

Confirm in the diff:
- [ ] `Dockerfile` sudoers line names **exactly two** scripts (`start-firewall.sh`,
      `fix-runs-perms.sh`) — **no `init-firewall.sh`, no `NOPASSWD: ALL`, no wildcard**.
- [ ] `Dockerfile` uses **`chmod 0755`** (not `chmod +x`); `rm -f /etc/sudoers.d/vscode`
      and the sudoers write are still in a `RUN` under `USER root`.
- [ ] `init-firewall.sh`: trap `_fail_closed` is installed **before** the flush
      (near the top); the body's only success marker `_FW_COMPLETED=1` is the
      **last line**, after *both* reachability checks; the trap sets the three
      default policies to `DROP`.
- [ ] `start-firewall.sh`: `STATE_DIR=/run/firewall`; `mkdir -p` + `chmod 0755`
      run **before** the first `tee "$LOG"` and first `> "$STATUS_FILE"`.
- [ ] `firewall-warning.sh` reads `/run/firewall/status`; `auth.md` references
      `/run/firewall/...` (no `/tmp/firewall-*` left except the historical
      `CHANGELOG.md:173`).

### 2.2 Mechanical checks
```bash
cd /workspace/.devcontainer/claude-code
for s in *.sh; do bash -n "$s" && echo "ok: $s"; done            # syntax

# sudoers line parses:
printf 'vscode ALL=(root) NOPASSWD: /usr/local/bin/start-firewall.sh, /usr/local/bin/fix-runs-perms.sh\n' \
  > "${TMPDIR:-/tmp}/x" && visudo -cf "${TMPDIR:-/tmp}/x" && rm -f "${TMPDIR:-/tmp}/x"

grep -rn "/tmp/firewall" . && echo "STALE REFS" || echo "clean"   # expect clean
```

### 2.3 Unit-test the fail-closed trap (safe — stubs `iptables`, never touches the live firewall)
This is the most important logic to verify. It proves the trap is a no-op on
success and forces DROP on every failure path:
```bash
run_case() { # name, body
  out="$(bash -c '
    set -euo pipefail
    iptables(){ echo "    [stub iptables $*]"; }     # never touches real firewall
    _FW_COMPLETED=0
    _fail_closed(){ if [ "$_FW_COMPLETED" -ne 1 ]; then echo "    FAIL_CLOSED"; iptables -P OUTPUT DROP; else echo "    success-no-op"; fi; }
    trap _fail_closed EXIT
    '"$2"'
  ' 2>&1)"; echo "--- $1 (exit=$?)"; echo "$out"; }

run_case "SUCCESS reaches flag"  'echo build; _FW_COMPLETED=1'
run_case "explicit exit 1"       'echo build; exit 1; _FW_COMPLETED=1'
run_case "set -e failure"        'echo build; false; echo NOPE; _FW_COMPLETED=1'
```
**Expected:** case 1 → `success-no-op`, exit 0 (real ruleset preserved); cases 2
& 3 → `FAIL_CLOSED` + `iptables -P OUTPUT DROP`, non-zero exit, `NOPE` never
printed. (Reviewers also confirmed the real trap fires on SIGTERM, subshell exit,
and fall-through-with-flag-unset; only un-trappable SIGKILL skips it, and `vscode`
cannot signal a root process.)

---

## 3. Runtime verification (after `Dev Containers: Rebuild Container`)

> The current container was built from the **first** commit, so until you rebuild
> you'll still see `init-firewall.sh` in `sudo -l` and `0775` scripts — that's
> expected. Rebuild to test the follow-up. (Rebuilding tears down the live
> firewall state, so run these *after* you've finished reviewing.)

```bash
# --- sudo surface (the headline of the follow-up) ---
sudo -n -l                       # MUST list ONLY start-firewall.sh + fix-runs-perms.sh
sudo -n /usr/local/bin/init-firewall.sh   # MUST be DENIED  ← the key new probe
sudo -n true                     # denied (blanket sudo gone, unchanged)

# --- script perms ---
ls -l /usr/local/bin/*-firewall.sh /usr/local/bin/fix-runs-perms.sh
                                 # all 0755 root:root (no group-write 'rwxrwx')

# --- state moved off /tmp ---
ls -ld /run/firewall             # drwxr-xr-x root root
cat /run/firewall/status         # → ok
test -e /tmp/firewall-status && echo "UNEXPECTED: /tmp file present" || echo "good: no /tmp state"

# --- firewall still enforcing (the thing we protect) ---
curl --max-time 6 -sS -o /dev/null -w '%{http_code}\n' https://api.github.com   # reaches (200)
curl --max-time 6 -sS -o /dev/null -w '%{http_code}\n' https://example.com      # blocked (timeout / no route)
```

**Optional, advanced — confirm fail-CLOSED end-state (disruptive; flushes/rebuilds
the live firewall).** Only do this if you accept briefly perturbing egress; it
restores itself. From the **host** (so a broken firewall can't lock you out):
```bash
# Induce a required-domain resolution failure, then run the wrapper, then check policy.
docker exec -u 0 <ctr> sh -c '
  printf "0.0.0.0 registry.npmjs.org\n" >> /etc/hosts          # break a REQUIRED resolve
  /usr/local/bin/start-firewall.sh >/dev/null 2>&1 || true
  iptables -S | grep -E "^-P (INPUT|OUTPUT|FORWARD)"           # expect: ... DROP  (fail-CLOSED, not ACCEPT)
  cat /run/firewall/status                                     # → failed
  sed -i "/registry.npmjs.org/d" /etc/hosts                    # restore
  /usr/local/bin/start-firewall.sh >/dev/null 2>&1             # bring it back up
  cat /run/firewall/status'                                    # → ok
```
Pass criterion: after the induced failure the default policies are **DROP**, not
ACCEPT — i.e. egress failed closed.

---

## 4. What is intentionally NOT fixed (residual)

- **Transient open window during a *normal* in-progress rebuild.** `init-firewall.sh`
  must reach the network to *build* the allowlist, so it runs ACCEPT for the few
  seconds of a rebuild. The trap guarantees the **end** state is closed, but the
  in-flight window remains. Fully eliminating it needs an `iptables-restore`
  atomic swap (a larger rewrite) — out of scope here.
- **Self-DoS.** `vscode` can still spam `sudo start-firewall.sh` to keep egress
  flapping; each run ends closed and it grants the attacker nothing (it *is*
  `vscode`). Availability-only, accepted.
- **DNS exfiltration over allowed UDP 53**, capability abuse, container escape —
  unchanged, pre-existing, documented in `HANDOFF_sudo_restriction.md` §6.
- **Base/Codespaces configs** (`build/Dockerfile`, root `devcontainer.json`) still
  inherit blanket sudo (no firewall there); see HANDOFF §5.

---

## 5. Reviewer sign-off checklist

- [ ] Diff matches §1 (2-script allowlist, `chmod 0755`, trap, `/run` paths).
- [ ] §2.2 mechanical checks pass (`bash -n`, `visudo`, no `/tmp/firewall` refs).
- [ ] §2.3 trap unit-test shows no-op-on-success / DROP-on-failure.
- [ ] (after rebuild) §3: `sudo init-firewall.sh` **denied**; scripts `0755`;
      state under `/run/firewall`; firewall still enforcing.
- [ ] Accept the §4 residuals (or open follow-ups for atomic `iptables-restore`).
