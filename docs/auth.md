# Claude Code Authentication

## How it works

`CLAUDE_CODE_OAUTH_TOKEN` is injected into each VS Code remote session (terminals
and tasks) via `remoteEnv` in `.devcontainer/claude-code/devcontainer.json`:

```json
"remoteEnv": {
  "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
  "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
}
```

`${localEnv:CLAUDE_CODE_OAUTH_TOKEN}` is re-evaluated every time VS Code connects
to the container and reads from the **host** environment at that moment. No
token is ever stored in the repo.

**Why `remoteEnv` and not `containerEnv`?** `remoteEnv` is scoped to VS Code
remote sessions — the token is only visible to your interactive shells, not to
container-level processes (firewall script, IGV viewer, background tasks). It is
also not baked into container metadata (`docker inspect`). Practically, this
means token rotation only requires a VS Code restart, not a container rebuild.

---

## VS Code (Mac dev setup)

Three files form the chain from Mac → container:

**1. `~/.claude/env.sh`** — the only file you ever edit:
```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
```

**2. `~/.zshenv`** — sources the token for every zsh session (including VS Code):
```bash
[ -f ~/.claude/env.sh ] && source ~/.claude/env.sh
```
`~/.zshenv` is read for every zsh invocation (login, non-login, interactive,
non-interactive). VS Code spawns a non-interactive login shell (`zsh -l`) to
resolve env vars at startup — it reads `~/.zshenv` but NOT `~/.zshrc`. The
`[ -f ... ]` guard prevents errors if the file is missing.

**3. `.devcontainer/claude-code/devcontainer.json`** — passes the token in via
`containerEnv` as shown above.

### Required order after initial setup

VS Code reads `~/.zshenv` **only at launch**. After first writing the token:

1. **Quit VS Code completely** (Cmd+Q, not just close window)
2. **Reopen VS Code** — it reads the new `~/.zshenv` and has the token, then
   reconnects to the devcontainer. The new remote session gets
   `CLAUDE_CODE_OAUTH_TOKEN` injected via `remoteEnv`.

No rebuild is required. Rebuild is also not needed for subsequent token
changes — just quit and reopen VS Code.

---

## GitHub Codespaces

GitHub Codespaces injects development environment secrets directly into the
container as environment variables — no special `containerEnv` wiring needed.
Once the secret is registered, `CLAUDE_CODE_OAUTH_TOKEN` is automatically
available in any Codespace for this repo.

### One-time setup — register the secret

1. Go to **github.com/settings/codespaces**
2. Under *Secrets*, click **New secret**
3. Name: `CLAUDE_CODE_OAUTH_TOKEN`
4. Value: your token (`sk-ant-oat01-...`)
5. Under *Repository access*, select this repo (or "All repositories")
6. Click **Add secret**

### Which devcontainer Codespaces uses

Codespaces defaults to the root `.devcontainer/devcontainer.json`, which uses
the pre-built ghcr image and does **not** include Claude Code CLI. You need
to select the `claude-code/` config instead.

**Option A — Select the config when creating the Codespace (no admin needed):**

1. On the repo page, click **Code → Codespaces tab**
2. Click the **⋯ kebab menu** (three dots, top-right of the Codespaces panel)
3. Select **"New with options..."**
4. On the options page, open the **Dev container configuration** dropdown
5. Select **"L3Rseq Pipeline (Claude Code Sandbox)"**
6. Choose machine type and click **Create codespace**

You repeat this selection each time you create a new Codespace. There is no
repo-wide "default config" setting in Codespaces — each codespace is configured
at creation.

**Option B — Add Claude Code to the root config (more work, harder to maintain):**

The root `devcontainer.json` uses the pre-built ghcr image which lacks Claude
Code CLI. You'd need to add it as a devcontainer feature or an install step.
Option A is simpler.

### Verify it's working

In a fresh Codespace terminal:
```bash
echo $CLAUDE_CODE_OAUTH_TOKEN    # should print the token
claude -p "say pong"              # should print: pong
```

---

## After any rebuild — quick check

```bash
echo $CLAUDE_CODE_OAUTH_TOKEN    # should print the token
claude -p "say pong"              # should print: pong
```

---

## Full checklist (after devcontainer config changes)

Run these in a **fresh VS Code terminal** after the rebuild completes. Use
this checklist after any change to `devcontainer.json`, `Dockerfile`, or the
firewall scripts — the quick check above is enough for ordinary rebuilds.

**1. Token is injected via `remoteEnv`:**
```bash
echo $CLAUDE_CODE_OAUTH_TOKEN
# → sk-ant-oat01-...    (should print the token)
```
If empty: VS Code didn't have the token when it reconnected.
Fix: quit VS Code completely (Cmd+Q), reopen, test again. No rebuild needed.

**2. Token is NOT baked into container metadata** (proves it's in `remoteEnv`,
not `containerEnv`):
```bash
# From the Mac terminal:
docker inspect <container-id> | grep CLAUDE_CODE_OAUTH_TOKEN
# → no output   (empty = good; means the token isn't in containerEnv)
```
If this prints the token, the devcontainer.json change didn't take — check
that `CLAUDE_CODE_OAUTH_TOKEN` is under `remoteEnv` (not `containerEnv`)
and rebuild once more.

**3. Claude Code authenticates:**
```bash
claude -p "say pong"
# → pong
```
If 401: see "Diagnosis tree if auth breaks" below.

**4. Firewall initialized successfully:**
```bash
cat /tmp/firewall-status
# → ok
```
If `failed`: the container is running without network restrictions. A red
banner should also appear at the top of every new shell. Retry:
`sudo /usr/local/bin/start-firewall.sh` and read `/tmp/firewall-init.log`.

**5. Firewall warning banner is wired up** (only visible when firewall fails —
you can simulate by writing `failed` to the status file):
```bash
# Simulate a firewall failure:
echo failed | sudo tee /tmp/firewall-status

# Open a NEW terminal — you should see a red banner:
#   ⚠  WARNING: Network firewall failed to initialize.
#      Container is running WITHOUT network restrictions.
#      ...

# Restore good state:
echo ok | sudo tee /tmp/firewall-status
```

**6. `postCreateCommand` uses `&&` throughout** (no silent failures between
steps):
```bash
grep postCreateCommand /workspace/.devcontainer/claude-code/devcontainer.json
# → should contain no `;`, only `&&` between the three steps
```

**7. `ANTHROPIC_API_KEY` regression check** (it already used `remoteEnv` before
the OAuth token move — make sure nothing broke it):
```bash
echo $ANTHROPIC_API_KEY
# → should print the API key if ANTHROPIC_API_KEY is set on the Mac
```

---

## Diagnosis tree if auth breaks

**Step 1: Is the token in the terminal?**
```bash
echo $CLAUDE_CODE_OAUTH_TOKEN
```

- **Prints the token → auth should work.** If `claude` still returns 401, a
  named Docker volume (`~/.claude`) may have stale credentials — see
  "Nuclear option" below.
- **Empty → `remoteEnv` expansion failed.** VS Code didn't have the token in
  its host environment when it reconnected. Fix: quit VS Code, reopen it.
  The new VS Code process will re-read `~/.zshenv` and inject the token into
  the next remote session. No rebuild needed.

**Step 2: Verify the Mac chain (run in a Mac terminal):**
```bash
source ~/.zshenv && echo $CLAUDE_CODE_OAUTH_TOKEN
```
If this prints the token, VS Code will have it after a restart.
If empty, check `~/.claude/env.sh` exists and has the correct content.

---

## Nuclear option — clear stale Docker credentials

If the token is present but `claude` still returns 401, the named Docker
volume `claude-code-config-*` may contain expired credentials.

```bash
# On Mac — find and remove the volume (container must be stopped first):
docker volume ls | grep claude-code-config
docker volume rm <volume-name>
# Then rebuild the container. The volume is recreated fresh.
```

---

## Does auth survive a Mac reboot?

**Yes — no action needed after a reboot.**

`remoteEnv` vars are re-evaluated each time VS Code connects to the container.
After a reboot, Docker Desktop restarts and VS Code reconnects to the existing
container — the reconnect re-reads `${localEnv:CLAUDE_CODE_OAUTH_TOKEN}` from
the Mac environment (restored from `~/.zshenv`) and injects the token into
the new remote session.

You only need to quit/reopen VS Code when the **token value changes**, so
that the new VS Code process picks up the new `~/.zshenv` value before it
reconnects.

---

## Token rotation

Rotate the token if it was accidentally exposed (commit, chat log, shared doc).

1. Generate a new token on the Mac:
   ```bash
   claude setup-token
   ```
2. Update the token file:
   ```bash
   echo 'export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-NEW-TOKEN"' > ~/.claude/env.sh
   ```
3. If using Codespaces: update the secret at github.com/settings/codespaces.
4. Quit VS Code → reopen. The next remote session picks up the new token via
   `remoteEnv`. No rebuild needed.
5. Verify: `echo $CLAUDE_CODE_OAUTH_TOKEN && claude -p "say pong"`

**Note:** Issuing a new token does NOT automatically invalidate the old one.
Both remain valid until the old one is explicitly revoked or expires. For local
exposure, switching to the new token is sufficient.

---

## When the token expires (~April 2027)

Same procedure as token rotation above. Nothing in the repo changes.

---

## Key files

| File | Purpose | Edit when |
|---|---|---|
| `~/.claude/env.sh` (Mac) | Token — single source of truth | Token expires or rotates |
| `~/.zshenv` (Mac) | Sources env.sh for VS Code + all shells | Never |
| `.devcontainer/claude-code/devcontainer.json` | Active devcontainer config | devcontainer changes |
| `.devcontainer/claude-code/Dockerfile` | Docker image build | Adding tools |
| `.devcontainer/devcontainer.json` | Codespaces default — no Claude Code | Avoid |
