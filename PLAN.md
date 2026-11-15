# dsh-web — implementation plan

## Goal

Deploy DeepSeek Harness `dsh web` on GitHub Actions with a Cloudflare named tunnel.
Public serving repo: `2061969365/dsh-web`. Private state repo: `2061969365/dsh-web-state`.
No R2/S3. State snapshots live as **private release assets** in the state repo; a tiny
`state` branch carries control files (`runtime/url.txt`, meta, lock, snapshot pointers).

## Paths on the runner

- `DSH_HOME=/home/runner/dsh-home`
- `DSH_WORKSPACE=/home/runner/dsh-work`
- `DSH_SCRATCH` = largest writable mount with >=20GB free and >=5% free inodes (`/mnt` if available, else `/home/runner`; fail unless `DSH_ALLOW_SMALL_SCRATCH=true`)
- `TMPDIR/TMP/TEMP=$DSH_SCRATCH/dsh-tmp`
- `STATE_CLONE=$DSH_SCRATCH/dsh-state`
- `RUN_DIR=$DSH_SCRATCH/run` (logs, url.txt, meta.json, staging)

## Files and ownership

- `dsh-actions/state.sh` + `dsh-actions/sync-excludes.txt` — state builder
- `dsh-actions/run.sh` — supervisor builder
- `.github/workflows/dsh-web.yml` + `.github/workflows/dsh-stop.yml` — workflow builder
- `README.md` + `dsh-actions/README.md` — docs builder
- `PLAN.md`, `.gitignore`, `.gitattributes`, integration, tests, git/GitHub setup — Lead

Do not edit files outside your write scope. Do not git commit/push; the Lead does.

## State backend: private release assets

`state` branch (single rolling commit, tiny):
```
runtime/url.txt       0600 current token URL
runtime/meta.json     run_id, version, host, timestamps, disk, state size, checkpoint stats
runtime/lock.json     run_id/host/started/heartbeat
runtime/state.json    current snapshot: asset names, sha256, bytes, parts
runtime/state.prev.json  previous snapshot pointer
.gitattributes        * -text ; *.zst binary
README.md
```

Release tag `dsh-state` (private): `home-<run_id>-<ts>.tar.zst.part-NN`,
`work-<run_id>-<ts>.tar.zst.part-NN`. Keep the latest **2** snapshots.

Budget: raw state soft **3GB**, hard **5GB**. Single asset hard limit is 2GiB, so split at
**1.9GB**. Checkpoint every **10 min**; if raw state >2GB use **20 min**. Final save always.
The git control branch stays <10MB.

Save: rsync live `$DSH_HOME`/`$DSH_WORKSPACE` to `$RUN_DIR/state/{home,work}` using the shared
exclude file; enforce budget; `gitleaks` scan; tar with zstd (`tar -C <dir> -cpf ... .`), split,
sha256; upload all parts; then atomically update `state.prev.json`/`state.json`; commit/push the
control branch with `--force-with-lease`; delete assets older than the previous snapshot.
Restore: clone `state`, check `isPrivate`, check lock, read `state.json`, download exact assets,
verify sha256, `cat parts | tar --zstd -xpf - -C <target>`, chmod/validate. Fall back to
`state.prev.json` if the current snapshot is unreadable; never start with an empty state when a
snapshot exists.

Exclude (shared `sync-excludes.txt`, rsync-style):
- home: `.credentials.yaml` (default; opt-in only), `spill/`, `cache/`, `logs/`,
  `storages/session_projcache*`, `storages/dsh-context/`, `attachments/v1/tmp/`,
  `profiles/*/node_modules`, `profiles/*/.plugin-manager`, `profiles/*/.dsh-market`,
  `compatibility.json`, `*.bak*`, `*.tmp`, `*.tmpdir`, `*.imported`, `session-purge-trash/`
- work: `.git`, `node_modules`, `.venv`, `venv`, `__pycache__`, `.pytest_cache`,
  `.mypy_cache`, `.ruff_cache`, `target`, `dist`, `build`, `.next`, `.cache`, `.pnpm-store`,
  `*.tmp`, `*.tmpdir`, `*.log`

Keep: sessions, attachments objects/files/file-objects, authoritative storages JSON,
profile patch/package/pnpm-lock, skills, AGENTS.md, `.anonymous-user-id`, work sources/lockfiles.

## state.sh contract

```
state.sh init                 # clone control, check private/lock, restore snapshot, chmod, validate, write lock
state.sh publish-url [url]    # default reads $RUN_DIR/url.txt; write runtime/url.txt 0600 + meta, commit/push
state.sh save [--final]       # stage/tar/split/upload/pointer/commit/cleanup; exit 2 on budget violation
state.sh should-stop          # exit 0 if DSH_STOP variable == GITHUB_RUN_ID or "all"
state.sh release-lock         # remove runtime/lock.json, commit/push
state.sh status               # print compact JSON
```
Env: `DSH_HOME`, `DSH_WORKSPACE`, `STATE_REPO`, `STATE_REPO_TOKEN`, `STATE_CLONE`, `RUN_DIR`,
`GITHUB_RUN_ID`, `GITHUB_REPOSITORY`, `STATE_BUDGET_MB` (5120), `STATE_WARN_MB` (3072),
`STATE_ASSET_PART_MB` (1900), `STATE_KEEP_SNAPSHOTS` (2), `STATE_MIN_FREE_MB` (5120).
Use `gh release` with `--repo "$STATE_REPO"` and `GH_TOKEN=$STATE_REPO_TOKEN`; git via
`GIT_ASKPASS` (never token in URL/argv), `umask 077`, no `set -x`, never print the URL/token.

## run.sh contract

Called after `state.sh init`. Starts cloudflared + dsh, parses the `dsh web:` URL, masks it,
writes `RUN_DIR/url.txt`, calls `state.sh publish-url`, then loops:
- every 10s: `state.sh should-stop` and process liveness
- every 30s: `df` free MB + inodes on `/` and `$DSH_SCRATCH`; below 5GB/3% => stop
- every checkpoint: `state.sh save`; `du` temp; if >8GB or free <6GB, prune
  `$TMPDIR/dsh-subprocess-*` files older than 60 min
- at 330 min: stop
Stop: SIGTERM dsh, wait up to 120s, SIGKILL, clean `$TMPDIR` DSH scratch (never
`$DSH_HOME/spill`), `state.sh save --final`, `state.sh release-lock`, summary.
No `taskkill /F`. No token/URL in stdout, `GITHUB_STEP_SUMMARY`, or artifacts.

dsh command (run in `$DSH_WORKSPACE`):
```
env -u STATE_REPO_TOKEN -u CF_TUNNEL_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  dsh web --host 127.0.0.1 --port 3080 --no-open \
  --public-url "https://$DSH_PUBLIC_HOST/" --trusted-host "$DSH_PUBLIC_HOST"
```
stdout/stderr -> `$RUN_DIR/dsh-web.log` (0600). Cloudflared:
`TUNNEL_TOKEN=... cloudflared tunnel --no-autoupdate --protocol http2 --grace-period 5s run`
(flags before `run`), log 0600. The named tunnel route is configured in the Cloudflare
dashboard (`DSH_PUBLIC_HOST -> http://127.0.0.1:3080`), not local config.yml.

Auto-restart only on normal deadline exit, `auto_restart` + `restarts_left>0`; never on STOP,
low disk, or crash. Use `gh workflow run` with `GITHUB_TOKEN` (actions: write). The start
workflow uses `concurrency: {group: dsh-web, cancel-in-progress: false}`.

## Workflows

`dsh-web.yml`: workflow_dispatch inputs auto_restart/restarts_left/max_runtime_minutes/
checkpoint_minutes; `runs-on: ubuntu-24.04`; `timeout-minutes: 355`; `permissions:
contents: read, actions: write`; Node 24 + npm cache; choose scratch; install dsh pin,
pinned cloudflared (SHA-256 verified), pinned gitleaks; `state.sh init` (10 min);
`run.sh` (345 min); summary.

`dsh-stop.yml`: workflow_dispatch; `permissions: actions: write, contents: read`; find the
in-progress dsh-web run; with `STATE_REPO_TOKEN` set `DSH_STOP` to its run id; wait up to 540s;
fallback `gh run cancel`; clear the variable. The supervisor polls it every 10s and exits
gracefully.

## Env / secrets / variables

Secrets: `STATE_REPO_TOKEN` (fine-grained PAT: state repo Contents + Variables read/write,
90 days), `CF_TUNNEL_TOKEN`, optional `DEEPSEEK_API_KEY`, optional `DSH_NOTIFY_WEBHOOK`.
Variables: `STATE_REPO=2061969365/dsh-web-state`, `DSH_PUBLIC_HOST`, `DSH_VERSION=0.2.2-rc.1`,
`STATE_BUDGET_MB=5120`, `STATE_WARN_MB=3072`, `STATE_ASSET_PART_MB=1900`,
`STATE_KEEP_SNAPSHOTS=2`, `DSH_MIN_FREE_MB=5120`, `DSH_TEMP_WARN_MB=8192`,
`DSH_MAX_RUNTIME_MIN=330`, `DSH_CHECKPOINT_MIN=10`, `CLOUDFLARED_VERSION`, `GITLEAKS_VERSION`.

Default credentials are **not** persisted. Model key via `DEEPSEEK_API_KEY`; cookie secret is
recreated each run, so reopen the private URL after a restart. The state repo must stay private;
assert it. State URL is only in the private control branch (public summary links to it, never
prints it).

## Temp / disk (audit-driven)

- workspace-changes scratch: `$TMPDIR/dsh-workspace-changes-*`, per session, removed on
  dispose; clean at start/stop; never prune a live session dir. Optional disable in the profile.
- subprocess: `$TMPDIR/dsh-subprocess-*`, 64MiB/stream, retained; age-clean under disk pressure.
- spill: default root under `$TMPDIR`, **not persisted**; old locators 404 after restart.
- office-to-pdf/HMR self-clean; SSH `/tmp/dsh-ssh-*` clean at start.
- clean `.tmp`/`.tmpdir`/`.staging-*` older than 60 min at start; leave `.bak`.
- DSH has no free-space guard; sample both `/` and `$DSH_SCRATCH`; sandbox also writes `/tmp`.

## Acceptance

- `bash -n` on both scripts; YAML parses; no `set -x`; no token/URL printed; no writes outside
  write scope.
- `state.sh` first run (no snapshot) works; save/restore round-trip; lock; stop variable;
  previous fallback; budget exit 2; 1.9GB split; keep 2 snapshots.
- `run.sh` starts/stops dsh + cloudflared; URL parse/mask; checkpoint; disk guard; SIGTERM;
  final save; summary; auto-restart only on deadline.
- `dsh-web.yml` and `dsh-stop.yml` reference the same env/interface; ubuntu-24.04; 355/345;
  secrets/vars names consistent with docs.
