# Claude Code Authentication

Two auth methods work out of the box — pick whichever fits you.

1. **[Browser login](#method-1--browser-login-recommended)** — zero host-side
   setup, one-time `claude /login` inside the container. Recommended for most
   users.
2. **[Host-injected token](#method-2--host-injected-token-automation-codespaces)** —
   an OAuth token set as an env var on the host, injected into the container
   via `remoteEnv`. Good for automation, Codespaces, or a single token shared
   across many devcontainers.

At runtime, the Claude CLI picks in this order:

1. `$CLAUDE_CODE_OAUTH_TOKEN` if set → method 2
2. `~/.claude/.credentials.json` if present → method 1
3. Otherwise prompts for login

The two methods coexist — the env var simply wins when present, so power users
can keep the token method while new users onboard via the browser.

---

## Method 1 — Browser login (recommended)

Works with Claude Pro, Max, or an Anthropic API key. No host configuration.

### One-time setup

1. Open the devcontainer.
2. In a terminal:
   ```bash
   claude /login
   ```
3. Pick Claude Pro/Max (or Anthropic API key).
4. A URL is printed — open it in your browser, authorize, copy the code back
   and paste it into the terminal prompt.
5. Verify:
   ```bash
   claude -p "say pong"
   # → pong
   ```

### Persistence across rebuilds

Credentials are written to `~/.claude/.credentials.json` inside the container.
That directory is a named Docker volume
(`claude-code-config-${devcontainerId}`), where `${devcontainerId}` is a stable
hash of workspace path + config file. The volume is reused across:

- Container restarts (VS Code stop / start)
- Container rebuilds (same workspace + same devcontainer config)
- Host reboots

The volume is **not** reused if:

- You explicitly remove it (`docker volume rm claude-code-config-*`)
- You clone the repo to a different folder → different `devcontainerId` →
  new volume → re-login required once

### Switching accounts / re-login

```bash
claude /logout     # clears ~/.claude/.credentials.json
claude /login      # log in again (different account or fresh token)
```

---

## Method 2 — Host-injected token (automation, Codespaces)

Use this when you want auth to "just be there" without any interactive login —
good for fresh containers, CI-like workflows, or when sharing a single token
across many devcontainers.

### How it works

`.devcontainer/claude-code/devcontainer.json` declares:

```json
"remoteEnv": {
  "ANTHROPIC_API_KEY": "${localEnv:ANTHROPIC_API_KEY}",
  "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
}
```

`${localEnv:CLAUDE_CODE_OAUTH_TOKEN}` is re-evaluated every time VS Code
reconnects to the container, reading from the **host** environment at that
moment. No token is ever stored in the repo.

When this env var is present inside the container, the Claude CLI uses it and
ignores `~/.claude/.credentials.json`. If the host never sets the var, the
`remoteEnv` line is a no-op and method 1 takes over automatically.

**Why `remoteEnv` and not `containerEnv`?** `remoteEnv` is scoped to VS Code
remote sessions — the token is only visible to your interactive shells, not to
container-level processes (firewall script, IGV viewer, background tasks). It
is also not baked into container metadata (`docker inspect`). Practically, this
means token rotation only requires a VS Code restart, not a container rebuild.

### VS Code on macOS — setup chain

Three files form the chain from Mac → container:

**1. `~/.claude/env.sh`** — the only file you ever edit:
```bash
export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
```
Get the token by running `claude setup-token` on the Mac after logging in to
Claude once.

**2. `~/.zshenv`** — sources the token for every zsh session (including
VS Code):
```bash
[ -f ~/.claude/env.sh ] && source ~/.claude/env.sh
```
`~/.zshenv` is read for every zsh invocation (login, non-login, interactive,
non-interactive). VS Code spawns a non-interactive login shell (`zsh -l`) to
resolve env vars at startup — it reads `~/.zshenv` but NOT `~/.zshrc`. The
`[ -f ... ]` guard prevents errors if the file is missing.

**3. `.devcontainer/claude-code/devcontainer.json`** — already wires
`remoteEnv` as shown above; no edits needed.

### Required order after initial setup

VS Code reads `~/.zshenv` **only at launch**. After first writing the token:

1. **Quit VS Code completely** (Cmd+Q, not just close window).
2. **Reopen VS Code** — it reads the new `~/.zshenv` and has the token, then
   reconnects to the devcontainer. The new remote session gets
   `CLAUDE_CODE_OAUTH_TOKEN` injected via `remoteEnv`.

No rebuild required. Rebuild is also not needed for subsequent token changes —
just quit and reopen VS Code.

### GitHub Codespaces

Codespaces injects development environment secrets directly into the container
as environment variables — no `~/.zshenv` trick needed. Once the secret is
registered, `CLAUDE_CODE_OAUTH_TOKEN` is automatically available in any
Codespace for this repo.

**One-time setup — register the secret:**

1. Go to **github.com/settings/codespaces**
2. Under *Secrets*, click **New secret**
3. Name: `CLAUDE_CODE_OAUTH_TOKEN`
4. Value: your token (`sk-ant-oat01-...`)
5. Under *Repository access*, select this repo (or "All repositories")
6. Click **Add secret**

**Which devcontainer Codespaces uses:**

Codespaces defaults to the root `.devcontainer/devcontainer.json`, which uses
the pre-built ghcr image and does **not** include Claude Code CLI. You need to
select the `claude-code/` config instead.

1. On the repo page, click **Code → Codespaces tab**
2. Click the **⋯ kebab menu** (three dots, top-right of the Codespaces panel)
3. Select **"New with options..."**
4. On the options page, open the **Dev container configuration** dropdown
5. Select **"L3Rseq Pipeline (Claude Code Sandbox)"**
6. Choose machine type and click **Create codespace**

You repeat this selection each time you create a new Codespace. There is no
repo-wide "default config" setting in Codespaces — each codespace is configured
at creation.

### Token rotation

Rotate the token if it's accidentally exposed (commit, chat log, shared doc).

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
Both remain valid until the old one is explicitly revoked or expires.

---

## Quick verification

Works for either method:
```bash
claude -p "say pong"
# → pong
```

For method 2 specifically, also check injection:
```bash
echo $CLAUDE_CODE_OAUTH_TOKEN
# → sk-ant-oat01-...   (should print the token)
```

---

## Diagnosis tree if auth breaks

**Step 1: Which method are you on?**
```bash
echo $CLAUDE_CODE_OAUTH_TOKEN
```

- **Prints a token** → method 2 is active. Go to step 2.
- **Empty** → method 2 didn't inject (or you never set it up). Check if
  method 1 credentials exist:
  ```bash
  ls -la ~/.claude/.credentials.json
  ```
  - File present → method 1 is active. If `claude` still returns 401, the
    saved token has expired: `claude /logout && claude /login`.
  - File missing → no auth at all. Run `claude /login` (method 1), or fix
    method 2 (step 3 below).

**Step 2: Method 2 active but `claude` returns 401**

The injected token has been revoked server-side, or it's stale. Rotate it:
`claude setup-token` on the Mac → update `~/.claude/env.sh` → quit and reopen
VS Code.

**Step 3: Method 2 — env var is empty even though host has it set**

VS Code didn't have `CLAUDE_CODE_OAUTH_TOKEN` when it reconnected. From the Mac
terminal:
```bash
source ~/.zshenv && echo $CLAUDE_CODE_OAUTH_TOKEN
```
- Prints the token → quit VS Code (Cmd+Q), reopen. The new VS Code process
  re-reads `~/.zshenv`.
- Empty → check `~/.claude/env.sh` exists and has the correct content.

---

## Nuclear option — clear stale Docker credentials

If nothing else works, reset the config volume:

```bash
# On Mac — find and remove the volume (container must be stopped first):
docker volume ls | grep claude-code-config
docker volume rm <volume-name>
# Then rebuild the container. The volume is recreated fresh.
```

**Warning:** this wipes the browser-login credentials, so method 1 users will
need to run `claude /login` again. Method 2 users are unaffected — the env var
is restored from the host on next VS Code reconnect.

---

## Full checklist (after devcontainer config changes)

Run these in a **fresh VS Code terminal** after the rebuild completes. Use
this checklist after any change to `devcontainer.json`, `Dockerfile`, or the
firewall scripts. The quick verification above is enough for ordinary rebuilds.

**1. Auth works** (either method):
```bash
claude -p "say pong"
# → pong
```

**2. Method 2 only — token is injected via `remoteEnv`, not baked into the
container metadata:**
```bash
# From the Mac terminal:
docker inspect <container-id> | grep CLAUDE_CODE_OAUTH_TOKEN
# → no output   (empty = good; means the token isn't in containerEnv)
```
If this prints the token, the devcontainer.json change didn't take — check
that `CLAUDE_CODE_OAUTH_TOKEN` is under `remoteEnv` (not `containerEnv`) and
rebuild once more.

**3. Firewall initialized successfully:**
```bash
cat /run/firewall/status
# → ok
```
If `failed`: init-firewall.sh failed *closed*, so egress is BLOCKED (not open) —
the network may not work until you retry. A red banner also appears at the top
of every new shell. Retry: `sudo /usr/local/bin/start-firewall.sh` and read
`/run/firewall/init.log`.

**4. Firewall warning banner is wired up** (only visible when the firewall
fails). The status file `/run/firewall/status` is root-owned under `/run`, and
the restricted sudo no longer permits `sudo tee`, so the unprivileged `vscode`
user can neither forge nor suppress it — a misbehaving agent cannot silence its
own firewall-failure banner. The banner appears automatically in every new
shell whenever a real init failure writes `failed`:
```
#   ⚠  WARNING: Network firewall failed to initialize.
#      Egress is BLOCKED (firewall failed closed) — network may not work.
#      Retry: sudo /usr/local/bin/start-firewall.sh
```
To exercise it deliberately you must write the status as root, e.g. from the
host: `docker exec -u 0 <ctr> sh -c 'echo failed > /run/firewall/status'`.

**5. `postCreateCommand` uses `&&` throughout** (no silent failures between
steps):
```bash
grep postCreateCommand /workspace/.devcontainer/claude-code/devcontainer.json
# → should contain no `;`, only `&&` between the three steps
```

**6. `ANTHROPIC_API_KEY` regression check** (it already used `remoteEnv`
before the OAuth token move — make sure nothing broke it):
```bash
echo $ANTHROPIC_API_KEY
# → should print the API key if ANTHROPIC_API_KEY is set on the Mac
```

---

## Key files

| File | Method | Purpose | Edit when |
|---|---|---|---|
| `~/.claude/.credentials.json` (in container) | 1 | Browser login credentials | Written by `claude /login`; never hand-edit |
| `~/.claude/env.sh` (host Mac) | 2 | Token — single source of truth | Token expires or rotates |
| `~/.zshenv` (host Mac) | 2 | Sources env.sh for VS Code + all shells | Never |
| `.devcontainer/claude-code/devcontainer.json` | both | `remoteEnv` wiring + base devcontainer config | devcontainer changes |
| `.devcontainer/claude-code/Dockerfile` | — | Docker image build | Adding tools |
| `.devcontainer/devcontainer.json` (root) | — | Codespaces default — no Claude Code CLI | Avoid |
